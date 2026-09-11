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
# BOOTSTRAP: creating the account needs an authenticated session, so if there is
# no usable one this runs `oc login` for you. oc prompts for the password for
# OKD_LOGIN_USER; it is typed straight into oc, never stored or echoed. After
# this has run once, nothing needs to log in again.
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
SERVER="${OKD_API_URL:?set OKD_BASE_DOMAIN in config.env}"

# Extracted before authenticating, because it needs no credentials and both the
# login below and the kubeconfig at the end want it. The last certificate the
# API serves is its own self-signed signer (CN=kube-apiserver-lb-signer), so
# embedding it lets both verify TLS instead of skipping it.
CA=$(mktemp); trap 'rm -f "$CA"' EXIT
HOSTPORT=${SERVER#https://}
openssl s_client -connect "$HOSTPORT" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' \
  | awk '/BEGIN CERT/{n++} n==2' > "$CA"
[[ -s "$CA" ]] || die "could not extract the API server CA from $HOSTPORT - is $SERVER reachable?"
curl -s --cacert "$CA" -o /dev/null --max-time 8 "$SERVER/healthz" \
  || die "the extracted CA does not verify $SERVER"
info "API CA extracted and verified"

# --------------------------------------------------------------------- login
if oc whoami >/dev/null 2>&1; then
  info "already authenticated as $(oc whoami)"
elif (( DRY_RUN )); then
  info "[dry-run] oc login $SERVER -u $OKD_LOGIN_USER   (would prompt for the password)"
else
  log "Logging in as ${OKD_LOGIN_USER:?set OKD_LOGIN_USER in config.env}"
  info "oc will prompt for the password - it is not stored or echoed"
  oc login "$SERVER" -u "$OKD_LOGIN_USER" --certificate-authority="$CA"
fi

if (( ! DRY_RUN )); then
  oc auth can-i create clusterrolebinding >/dev/null 2>&1 \
    || die "$(oc whoami) cannot create a clusterrolebinding - log in as cluster-admin"
fi

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
