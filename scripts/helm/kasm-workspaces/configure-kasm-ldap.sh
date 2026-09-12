#!/bin/bash
#
# configure-kasm-ldap.sh - create the Secret holding the AD bind password Kasm
#                          authenticates with.
#
# The LDAP settings themselves live in kasmConfig.config.ldapConfigs in the
# rendered values; only the bind password is here, so it never reaches values.yaml
# or git. The chart reads it through existingSecret/existingSecretKey.
#
# You are prompted for the password. It goes straight into the Secret - not read
# back, not echoed, not written to disk.
#
# IMPORTANT: the LDAP settings are applied by the db-init preseed, which only
# runs against an EMPTY database. On a deployment whose DB already exists this
# creates the Secret but changes nothing - configure LDAP in the Kasm admin UI
# instead, or recreate the DB PVC and redeploy.
#
# Usage:
#   scripts/helm/kasm-workspaces/configure-kasm-ldap.sh
#   scripts/helm/kasm-workspaces/configure-kasm-ldap.sh --check   # test the bind, change nothing
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${KASM_NAMESPACE:-kasm-workspaces}"
SECRET="${KASM_LDAP_SECRET:?set KASM_LDAP_SECRET in config.env}"
BIND_DN="${AD_BIND_DN:?set AD_BIND_USER/AD_BASE_DN in config.env}"
URL="${KASM_LDAP_URL:?set AD_DC_HOST/AD_DC_PORT in config.env}"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

log "Preflight"
command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE does not exist"
info "url:      $URL"
info "bind dn:  $BIND_DN"
info "group:    ${KASM_LDAP_GROUP_DN:-<unset>}"

read -rsp "Password for ${BIND_DN}: " LDAP_PASSWORD
echo

# Verify the bind before storing it, if ldapsearch is available - a wrong
# password here surfaces as a login failure inside Kasm much later otherwise.
if command -v ldapsearch >/dev/null; then
  log "Testing the bind"
  if LDAPTLS_CACERT="${AD_CA_CERT_FILE:-}" ldapsearch -x -LLL \
       -H "$URL" -D "$BIND_DN" -w "$LDAP_PASSWORD" \
       -b "${AD_BASE_DN}" -s base dn >/dev/null 2>&1; then
    info "bind OK"
  else
    unset LDAP_PASSWORD
    die "bind failed against $URL as $BIND_DN - password, DN or TLS trust is wrong"
  fi
else
  info "ldapsearch not installed - storing the password without testing it"
fi

if (( CHECK_ONLY )); then
  unset LDAP_PASSWORD
  log "--check: nothing written"
  exit 0
fi

log "Creating secret/$SECRET in $NAMESPACE"
oc create secret generic "$SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=password="$LDAP_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
unset LDAP_PASSWORD
info "stored (not echoed)"

log "Next"
cat <<EOF
    The LDAP settings are applied by the db-init preseed, which only runs on an
    empty database. If this deployment's DB already exists, either configure
    LDAP in the Kasm admin UI, or reset it:

      oc delete statefulset kasm-workspaces-db-1-19-0 -n $NAMESPACE --cascade=orphan
      oc delete pod kasm-workspaces-db-1-19-0-0 -n $NAMESPACE
      oc delete pvc kasm-workspaces-database-1-19-0-kasm-workspaces-db-1-19-0-0 -n $NAMESPACE
      scripts/helm/kasm-workspaces/deploy-kasm-helm.sh
EOF
