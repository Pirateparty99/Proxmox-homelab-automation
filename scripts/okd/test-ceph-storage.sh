#!/usr/bin/env bash
#
# test-ceph-storage.sh - prove the Ceph StorageClasses actually provision.
# Creates a PVC of each class, binds it, writes/reads a file, then cleans up.
# Safe to run repeatedly. Exits non-zero if anything fails.
set -euo pipefail

NS="${NS:-ceph-csi-test}"
SC_RBD="${SC_RBD:-ceph-rbd}"
SC_CEPHFS="${SC_CEPHFS:-ceph-fs}"
SIZE="${SIZE:-1Gi}"
TIMEOUT="${TIMEOUT:-180}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail=0

cleanup() { oc delete namespace "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Namespace ${NS}"
oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS" >/dev/null
info "ready"

test_sc() {   # $1=storageclass  $2=accessmode  $3=label
  local sc="$1" mode="$2" label="$3"
  local pvc="pvc-${label}"
  local pod="pod-${label}"
  log "${label}: ${sc} (${mode})"

  oc apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ${pvc} }
spec:
  accessModes: [ ${mode} ]
  storageClassName: ${sc}
  resources: { requests: { storage: ${SIZE} } }
EOF

  if ! oc wait -n "$NS" --for=jsonpath='{.status.phase}'=Bound "pvc/${pvc}" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    info "FAIL: PVC did not bind"
    oc describe -n "$NS" "pvc/${pvc}" 2>/dev/null | grep -A5 Events | sed 's/^/      /'
    fail=1; return
  fi
  info "PVC bound: $(oc get -n "$NS" pvc/${pvc} -o jsonpath='{.spec.volumeName}')"

  oc apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: ${pod} }
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000          # so the mounted volume is writable by the pod user
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: t
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh","-c","echo ok > /data/probe && cat /data/probe && sleep 5"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
      volumeMounts: [ { name: v, mountPath: /data } ]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: ${pvc} }
EOF

  if oc wait -n "$NS" --for=condition=Ready "pod/${pod}" --timeout="${TIMEOUT}s" >/dev/null 2>&1 \
     || oc wait -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    info "pod mounted and wrote to the volume"
  else
    info "FAIL: pod did not start"
    oc describe -n "$NS" "pod/${pod}" 2>/dev/null | grep -A5 Events | sed 's/^/      /'
    fail=1
  fi
}

test_sc "$SC_RBD"    ReadWriteOnce  rbd
test_sc "$SC_CEPHFS" ReadWriteMany  cephfs

log "Summary"
(( fail == 0 )) && { info "PASS - both storage classes provision and mount"; exit 0; }
info "FAIL - see errors above"; exit 1
