#!/bin/bash
#
# create-oc-token.sh - mint a long-lived service account credential for the
#                      cluster, so scripts do not depend on an `oc login`
#                      session that expires.
#
# `oc login` gives you an OAuth token that expires (24h for kubeadmin by
# default), which is why automation that worked yesterday fails today. This
# creates a ServiceAccount bound to cluster-admin, issues it a non-expiring
# token, and writes a kubeconfig using it to secrets/okd-kubeconfig.
# lib/config.sh points KUBECONFIG at that file, so every script just works.
#
# BOOTSTRAP: this needs an authenticated session to create the account, so run
# `oc login` once by hand first. After that, nothing else needs to.
#
# The generated kubeconfig verifies TLS properly: the API serves its own
# self-signed root (CN=kube-apiserver-lb-signer) in the chain, so that is
# embedded as the CA rather than setting insecure-skip-tls-verify, which is what
# `oc login` leaves behind.
#
# The token does not expire. It is cluster-admin. Treat secrets/okd-kubeconfig
# as equivalent to the cluster's root credential. To revoke:
#
#   oc delete ns <OKD_AUTOMATION_NS>
#   oc delete clusterrolebinding <OKD_AUTOMATION_SA>-cluster-admin
#
# Usage:
#   scripts/okd/create-oc-token.sh
#   scripts/okd/create-oc-token.sh --dry-run
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

NS="${OKD_AUTOMATION_NS:-homelab-automation}"
SA="${OKD_AUTOMATION_SA:-deployer}"
OUT="${OKD_KUBECONFIG_FILE:-$REPO_ROOT/secrets/okd-kubeconfig}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ------------------------------------------------------------------- preflight
log "Preflight"
command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 \
  || die "oc is not authenticated. Run 'oc login' once by hand - this script needs a session to create the account it then replaces."
SERVER=$(oc whoami --show-server)
info "logged in as $(oc whoami) on $SERVER"
oc auth can-i create clusterrolebinding >/dev/null 2>&1 \
  || die "this account cannot create a clusterrolebinding - log in as cluster-admin"

# ------------------------------------------------------------------- account
log "ServiceAccount $NS/$SA"
run "oc create namespace '$NS' --dry-run=client -o yaml | oc apply -f - >/dev/null"
run "oc create serviceaccount '$SA' -n '$NS' --dry-run=client -o yaml | oc apply -f - >/dev/null"
run "oc create clusterrolebinding '${SA}-cluster-admin' --clusterrole=cluster-admin --serviceaccount='${NS}:${SA}' --dry-run=client -o yaml | oc apply -f - >/dev/null"
info "bound to cluster-admin"

# --------------------------------------------------------------------- token
# `oc create token` issues a bounded token the API server may cap well below
# what automation wants. An explicitly created service-account-token Secret is
# still honoured in 4.19 and does not expire.
log "Token"
if (( DRY_RUN )); then
  info "[dry-run] create Secret ${SA}-token (type kubernetes.io/service-account-token)"
  info "[dry-run] write $OUT"
  exit 0
fi

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA}-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: ${SA}
type: kubernetes.io/service-account-token
EOF

# The token controller populates it asynchronously.
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN=$(oc get secret "${SA}-token" -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null || true)
  [[ -n "$TOKEN" ]] && break
  sleep 2
done
[[ -n "$TOKEN" ]] || die "the token Secret was not populated - does this cluster still honour service-account-token Secrets?"
TOKEN=$(printf '%s' "$TOKEN" | base64 -d)

# ----------------------------------------------------------------- kubeconfig
log "Writing $OUT"
HOSTPORT=${SERVER#https://}
CA=$(mktemp); trap 'rm -f "$CA"' EXIT
# The last certificate in the chain is the self-signed signer; embedding it lets
# the kubeconfig verify TLS instead of skipping it.
openssl s_client -connect "$HOSTPORT" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' \
  | awk '/BEGIN CERT/{n++} n==2' > "$CA"
[[ -s "$CA" ]] || die "could not extract the API server CA from $HOSTPORT"
curl -s --cacert "$CA" -o /dev/null --max-time 8 "$SERVER/healthz" \
  || die "the extracted CA does not verify $SERVER - refusing to write a kubeconfig that cannot check TLS"

mkdir -p "$(dirname "$OUT")"
install -m 600 /dev/null "$OUT"
KUBECONFIG="$OUT" oc config set-cluster okd --server="$SERVER" \
    --certificate-authority="$CA" --embed-certs=true >/dev/null
KUBECONFIG="$OUT" oc config set-credentials "$SA" --token="$TOKEN" >/dev/null
KUBECONFIG="$OUT" oc config set-context okd --cluster=okd --user="$SA" >/dev/null
KUBECONFIG="$OUT" oc config use-context okd >/dev/null

info "mode 600, token not echoed"
info "verified as: $(KUBECONFIG=$OUT oc whoami)"
info "lib/config.sh points KUBECONFIG here, so scripts/deploy-adcs.sh needs no login"
