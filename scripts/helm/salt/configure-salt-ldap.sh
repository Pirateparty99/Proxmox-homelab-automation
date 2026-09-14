#!/bin/bash
#
# configure-salt-ldap.sh - create the Secret salt-api authenticates against.
#
# SaltGUI does no authentication of its own: it sends the username, password
# and eauth type to salt-api, which binds to AD. That bind needs a service
# account, and its password does not belong in values.yaml - it goes in a
# Secret holding an ldap.conf, mounted into /etc/salt/master.d/.
#
# You are prompted for the bind password. It is tested before anything is
# written, and never echoed or stored on disk.
#
# Usage:
#   scripts/helm/salt/configure-salt-ldap.sh
#   scripts/helm/salt/configure-salt-ldap.sh --check    # test the bind only
#   scripts/helm/salt/configure-salt-ldap.sh --show     # what is configured
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${SALT_NAMESPACE:-salt}"
SECRET="${SALT_LDAP_SECRET:-salt-ldap}"
BIND_DN="${AD_BIND_DN:?set AD_BIND_USER in config.env}"
BASE_DN="${AD_BASE_DN:?set AD_BASE_OU in config.env}"
DC_HOST="${AD_DC_HOST:?set AD_DC_HOST in config.env}"
DC_PORT="${AD_DC_PORT:-636}"
ADMINS_DN="${SALT_LDAP_ADMINS_GROUP_DN:?set it in config.env}"

MODE=create
case "${1:-}" in
  "")      ;;
  --check) MODE=check ;;
  --show)  MODE=show ;;
  *)       echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

if [[ "$MODE" == show ]]; then
  log "Secret"
  if oc get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
    info "$SECRET exists; keys: $(oc get secret "$SECRET" -n "$NAMESPACE" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null)"
  else
    info "$SECRET does not exist"
  fi
  log "Who may drive Salt"
  info "$ADMINS_DN"
  exit 0
fi

log "Preflight"
info "server: ldaps://${DC_HOST}:${DC_PORT}"
info "bind:   $BIND_DN"
info "base:   $BASE_DN"
info "admins: $ADMINS_DN"

read -rsp "Password for ${BIND_DN}: " LDAP_PASSWORD
echo
[[ -n "$LDAP_PASSWORD" ]] || die "no password given"

if command -v ldapsearch >/dev/null; then
  log "Testing the bind"
  LDAPTLS_CACERT="${AD_CA_CERT_FILE:-}" ldapsearch -x -LLL -H "ldaps://${DC_HOST}:${DC_PORT}" \
      -D "$BIND_DN" -w "$LDAP_PASSWORD" -b "$BASE_DN" -s base dn >/dev/null 2>&1 \
    || { unset LDAP_PASSWORD; die "bind failed - password, DN or TLS trust is wrong"; }
  info "bind OK"
  # A group that does not exist means every login is refused, with nothing in
  # the logs to say why - so it is checked here rather than discovered later.
  if ! LDAPTLS_CACERT="${AD_CA_CERT_FILE:-}" ldapsearch -x -LLL -H "ldaps://${DC_HOST}:${DC_PORT}" \
       -D "$BIND_DN" -w "$LDAP_PASSWORD" -b "$ADMINS_DN" -s base dn >/dev/null 2>&1; then
    unset LDAP_PASSWORD
    die "the group ${ADMINS_DN} does not exist. Create it, or fix
    SALT_LDAP_ADMINS_GROUP_DN in config.env."
  fi
  info "admin group exists"
else
  info "ldapsearch not installed - not testing the bind"
fi

if [[ "$MODE" == check ]]; then
  unset LDAP_PASSWORD
  log "--check: nothing written"
  exit 0
fi

log "Writing the Secret"
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null

# activedirectory mode makes Salt resolve group membership through memberOf,
# which is how AD expresses it.
LDAP_CONF="auth.ldap.server: ${DC_HOST}
auth.ldap.port: ${DC_PORT}
auth.ldap.tls: True
auth.ldap.basedn: ${BASE_DN}
auth.ldap.binddn: ${BIND_DN}
auth.ldap.bindpw: ${LDAP_PASSWORD}
auth.ldap.accountattributename: sAMAccountName
auth.ldap.groupattribute: memberOf
auth.ldap.activedirectory: True
auth.ldap.persontype: person
"
unset LDAP_PASSWORD

oc create secret generic "$SECRET" -n "$NAMESPACE" \
  --from-file=ldap.conf=/dev/stdin --dry-run=client -o yaml <<< "$LDAP_CONF" \
  | oc apply -f - >/dev/null
unset LDAP_CONF
info "$SECRET written (mounted at /etc/salt/master.d/ldap.conf)"

log "Next"
info "scripts/helm/salt/deploy-salt-helm.sh   # picks the Secret up"
info "then sign in at https://${SALT_FQDN:-<salt route>} with an AD account"
info "in ${ADMINS_DN}, choosing 'ldap' as the type"
