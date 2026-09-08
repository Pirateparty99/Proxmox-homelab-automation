#!/usr/bin/env bash
#
# setup-ceph-csi.sh - wire an existing (Proxmox-managed) Ceph cluster into OKD/OpenShift
#                     as dynamic storage, via the upstream ceph-csi Helm charts.
#
# Produces two StorageClasses:
#   ceph-rbd  (RWO, block)   - default
#   ceph-fs   (RWX, shared)
#
# The Ceph cluster is EXTERNAL to Kubernetes: Rook is deliberately not used, and
# nothing here manages Ceph itself beyond creating one pool and two scoped users.
#
# Idempotent: safe to re-run. Existing pools/users/releases are reused, not recreated.
#
# Prerequisites on the host running this script:
#   - oc (logged in / KUBECONFIG set) with cluster-admin
#   - helm v3
#   - key-based ssh to a Proxmox node that can run `ceph`
#
# Usage:
#   KUBECONFIG=/root/okd/cluster/auth/kubeconfig ./setup-ceph-csi.sh
#   ./setup-ceph-csi.sh --dry-run      # show what would happen, change nothing
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
# Site values come from config.env via lib/config.sh; still overridable per-run.
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

CEPH_SSH="${CEPH_SSH:?set PVE_CEPH_HOST in config.env}"   # Proxmox node that runs `ceph`
CEPH_FS_NAME="${CEPH_FS_NAME:-cephfs}"      # existing CephFS to back RWX volumes
RBD_POOL="${RBD_POOL:-${CEPH_RBD_POOL:-okd-rbd}}"  # RBD pool created for OKD PVCs
CEPHFS_SUBVOL_GROUP="${CEPHFS_SUBVOL_GROUP:-csi}"  # subvolume group ceph-csi provisions into
POOL_SIZE="${POOL_SIZE:-${CEPH_POOL_SIZE:-2}}"     # 2-node cluster: size 2 / min_size 1
POOL_MIN_SIZE="${POOL_MIN_SIZE:-${CEPH_POOL_MIN_SIZE:-1}}"
POOL_PG_NUM="${POOL_PG_NUM:-32}"
# The two ceph-csi charts each create ConfigMaps with fixed default names
# (ceph-config, ceph-csi-config, ceph-csi-encryption-kms-config). Installed into a
# single namespace the second release cannot adopt the first release's objects, so
# each driver gets its own namespace. This is also upstream's documented layout.
NS_RBD="${NS_RBD:-ceph-csi-rbd}"
NS_CEPHFS="${NS_CEPHFS:-ceph-csi-cephfs}"
SC_RBD="${SC_RBD:-ceph-rbd}"
SC_CEPHFS="${SC_CEPHFS:-ceph-fs}"
SC_RBD_DEFAULT="${SC_RBD_DEFAULT:-true}"    # make ceph-rbd the cluster default SC
CHART_VERSION_RBD="${CHART_VERSION_RBD:-}"  # empty = latest
CHART_VERSION_CEPHFS="${CHART_VERSION_CEPHFS:-}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ---------------------------------------------------------------------- helpers
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }
ceph_cmd() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$CEPH_SSH" "$@"; }

# ------------------------------------------------------------------- preflight
log "Preflight"
for c in oc helm ssh; do command -v "$c" >/dev/null || die "$c not found in PATH"; done
oc whoami >/dev/null 2>&1 || die "oc is not authenticated (set KUBECONFIG or run 'oc login')"
info "oc user:      $(oc whoami)"
info "oc server:    $(oc whoami --show-server)"
ceph_cmd "ceph health" >/dev/null 2>&1 || die "cannot run 'ceph' via ssh on $CEPH_SSH"
info "ceph health:  $(ceph_cmd 'ceph health' 2>/dev/null)"
ceph_cmd "ceph fs ls --format json" 2>/dev/null | grep -q "\"name\":\"${CEPH_FS_NAME}\"" \
  || die "CephFS '${CEPH_FS_NAME}' not found - create it first (pveceph fs create)"
info "cephfs:       ${CEPH_FS_NAME} present"

# --------------------------------------------------------------- ceph: rbd pool
log "Ceph: RBD pool '${RBD_POOL}'"
if ceph_cmd "ceph osd pool ls" 2>/dev/null | grep -qx "$RBD_POOL"; then
  info "pool already exists - leaving as is"
else
  run "ceph_cmd \"ceph osd pool create ${RBD_POOL} ${POOL_PG_NUM} ${POOL_PG_NUM} replicated\""
  run "ceph_cmd \"ceph osd pool application enable ${RBD_POOL} rbd\""
  run "ceph_cmd \"rbd pool init ${RBD_POOL}\""
  info "created"
fi
# Enforce replication settings every run - cheap, and catches drift.
run "ceph_cmd \"ceph osd pool set ${RBD_POOL} size ${POOL_SIZE}\" >/dev/null"
run "ceph_cmd \"ceph osd pool set ${RBD_POOL} min_size ${POOL_MIN_SIZE}\" >/dev/null"
info "size=${POOL_SIZE} min_size=${POOL_MIN_SIZE}"

# ------------------------------------------------------------ ceph: csi clients
# Two least-privilege users rather than one shared account.
log "Ceph: CSI client users"
RBD_USER="okd-rbd"
FS_USER="okd-cephfs"
run "ceph_cmd \"ceph auth get-or-create client.${RBD_USER}\" >/dev/null"
run "ceph_cmd \"ceph auth caps client.${RBD_USER} \
    mon 'profile rbd' \
    osd 'profile rbd pool=${RBD_POOL}' \
    mgr 'profile rbd pool=${RBD_POOL}'\" >/dev/null"
# The cephfs provisioner creates subvolumes via the mgr volumes module, which
# touches BOTH the data and metadata pools. Omitting "tag cephfs metadata=..."
# yields "rpc error: rados: ret=-1, Operation not permitted" at provisioning time.
run "ceph_cmd \"ceph auth get-or-create client.${FS_USER}\" >/dev/null"
# get-or-create will not update an existing user's caps, so set them explicitly
# every run - this also repairs drift if the caps were previously too narrow.
run "ceph_cmd \"ceph auth caps client.${FS_USER} \
    mon 'allow r' \
    mgr 'allow rw' \
    osd 'allow rw tag cephfs metadata=${CEPH_FS_NAME}, allow rw tag cephfs data=${CEPH_FS_NAME}' \
    mds 'allow rw fsname=${CEPH_FS_NAME}'\" >/dev/null"
info "client.${RBD_USER} and client.${FS_USER} present"

# ------------------------------------------------- ceph: cephfs subvolume group
# ceph-csi provisions every RWX volume as a subvolume inside this group. It is NOT
# created automatically, and without it provisioning fails with:
#   rados: ret=-2, No such file or directory: "subvolume group 'csi' does not exist"
log "Ceph: CephFS subvolume group '${CEPHFS_SUBVOL_GROUP}'"
run "ceph_cmd \"ceph fs subvolumegroup create ${CEPH_FS_NAME} ${CEPHFS_SUBVOL_GROUP}\" >/dev/null"
info "present"

# ------------------------------------------------------- gather cluster details
log "Ceph: connection details"
if (( DRY_RUN )); then
  FSID="<fsid>"; MON_LIST="<mons>"; RBD_KEY="<key>"; FS_KEY="<key>"
else
  FSID=$(ceph_cmd "ceph fsid" | tr -d '[:space:]')
  # v1 (6789) endpoints - broadest client compatibility
  MON_LIST=$(ceph_cmd "ceph mon dump --format json" 2>/dev/null \
    | jq -r '[.mons[].public_addrs.addrvec[] | select(.type=="v1") | .addr] | join(",")')
  RBD_KEY=$(ceph_cmd "ceph auth get-key client.${RBD_USER}")
  FS_KEY=$(ceph_cmd "ceph auth get-key client.${FS_USER}")
  [[ -n "$FSID" && -n "$MON_LIST" ]] || die "could not determine fsid/monitors"
fi
info "fsid:     ${FSID}"
info "monitors: ${MON_LIST}"
MON_COUNT=$(awk -F, '{print NF}' <<<"$MON_LIST")
(( MON_COUNT >= 3 )) || info "NOTE: only ${MON_COUNT} monitor(s) - every PVC mount depends on it"

# ------------------------------------------------------------------- namespace
log "OKD: namespaces"
for ns in "$NS_RBD" "$NS_CEPHFS"; do
  run "oc get namespace ${ns} >/dev/null 2>&1 || oc create namespace ${ns}"
  info "${ns}"
done

# ceph-csi node plugins need privileged SCC on OpenShift (host mounts, rbd map)
log "OKD: SecurityContextConstraints"
for sa in ceph-csi-rbd-nodeplugin ceph-csi-rbd-provisioner; do
  run "oc adm policy add-scc-to-user privileged -z ${sa} -n ${NS_RBD} >/dev/null 2>&1 || true"
done
for sa in ceph-csi-cephfs-nodeplugin ceph-csi-cephfs-provisioner; do
  run "oc adm policy add-scc-to-user privileged -z ${sa} -n ${NS_CEPHFS} >/dev/null 2>&1 || true"
done
info "privileged SCC granted in both namespaces"

# ----------------------------------------------------------------- helm charts
log "OKD: helm repo"
run "helm repo add ceph-csi https://ceph.github.io/csi-charts >/dev/null 2>&1 || true"
run "helm repo update >/dev/null 2>&1"

log "OKD: ceph-csi-rbd -> StorageClass '${SC_RBD}'"
RBD_ARGS=(
  --namespace "$NS_RBD"
  --set "csiConfig[0].clusterID=${FSID}"
  --set "csiConfig[0].monitors[0]=${MON_LIST%%,*}"
  --set "secret.create=true" --set "secret.name=csi-rbd-secret"
  --set "secret.userID=${RBD_USER}" --set "secret.userKey=${RBD_KEY}"
  --set "storageClass.create=true" --set "storageClass.name=${SC_RBD}"
  --set "storageClass.clusterID=${FSID}" --set "storageClass.pool=${RBD_POOL}"
  --set "storageClass.isDefault=${SC_RBD_DEFAULT}"
  --set "storageClass.allowVolumeExpansion=true"
  --set "provisioner.replicaCount=1"
)
[[ -n "$CHART_VERSION_RBD" ]] && RBD_ARGS+=(--version "$CHART_VERSION_RBD")
run "helm upgrade --install ceph-csi-rbd ceph-csi/ceph-csi-rbd ${RBD_ARGS[*]} >/dev/null"
info "deployed"

log "OKD: ceph-csi-cephfs -> StorageClass '${SC_CEPHFS}'"
FS_ARGS=(
  --namespace "$NS_CEPHFS"
  --set "csiConfig[0].clusterID=${FSID}"
  --set "csiConfig[0].monitors[0]=${MON_LIST%%,*}"
  --set "secret.create=true" --set "secret.name=csi-cephfs-secret"
  # NOTE: the cephfs chart uses userID/userKey (not adminID/adminKey). Setting the
  # wrong keys silently leaves the chart's placeholder values in the Secret, and
  # provisioning then fails with "rados: ret=-2, No such file or directory".
  --set "secret.userID=${FS_USER}" --set "secret.userKey=${FS_KEY}"
  --set "storageClass.create=true" --set "storageClass.name=${SC_CEPHFS}"
  --set "storageClass.clusterID=${FSID}" --set "storageClass.fsName=${CEPH_FS_NAME}"
  --set "storageClass.allowVolumeExpansion=true"
  --set "provisioner.replicaCount=1"
)
[[ -n "$CHART_VERSION_CEPHFS" ]] && FS_ARGS+=(--version "$CHART_VERSION_CEPHFS")
run "helm upgrade --install ceph-csi-cephfs ceph-csi/ceph-csi-cephfs ${FS_ARGS[*]} >/dev/null"
info "deployed"

# ---------------------------------------------------------------------- verify
if (( DRY_RUN )); then log "Dry run complete - nothing was changed"; exit 0; fi

log "Waiting for CSI pods"
oc rollout status ds/ceph-csi-rbd-nodeplugin    -n "$NS_RBD"    --timeout=300s || true
oc rollout status ds/ceph-csi-cephfs-nodeplugin -n "$NS_CEPHFS" --timeout=300s || true

log "Result"
for ns in "$NS_RBD" "$NS_CEPHFS"; do
  echo "    [$ns]"
  oc get pods -n "$ns" --no-headers 2>/dev/null | awk '{printf "      %-44s %s %s\n", $1, $2, $3}'
done
echo
oc get storageclass | sed 's/^/    /'
