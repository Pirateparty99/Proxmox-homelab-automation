#!/bin/bash
#
# configure-kasm-ldap.sh - point Kasm at AD for authentication.
#
# Kasm's chart can preseed this, but only into an EMPTY database and only where
# kasmConfig.generatePreseed can be enabled - which it cannot on OpenShift (see
# the comment on generatePreseed in the values template). So this writes the
# same rows the preseed would have written, straight into Kasm's database:
#
#   ldap_configs            one row - the directory connection
#   sso_to_group_mapping    two rows - which AD group grants which Kasm group
#
# AD groups map onto Kasm's own built-in groups, looked up by name rather than
# hardcoded, so privileges come from Kasm's definitions:
#
#   KASM_LDAP_USERS_GROUP_DN  -> All Users       (general)
#   KASM_LDAP_ADMINS_GROUP_DN -> Administrators  (admin)
#
# ldap_configs.service_account_password is NOT a plaintext column. It is a
# SQLAlchemy StringEncryptedType (AES/pkcs5), keyed by the installation_id - see
# the encrypt_sensitive_columns migration in the api image. Writing plaintext
# there yields a row Kasm cannot decrypt and a bind that always fails. So the
# password is encrypted by Kasm's own code, run inside the api container, and
# only the ciphertext is ever written.
#
# You are prompted for the bind password. It is tested before anything is
# written, and never echoed or stored on disk.
#
# Re-running updates the existing rows rather than duplicating them.
#
# Usage:
#   scripts/helm/kasm-workspaces/configure-kasm-ldap.sh
#   scripts/helm/kasm-workspaces/configure-kasm-ldap.sh --check   # test the bind only
#   scripts/helm/kasm-workspaces/configure-kasm-ldap.sh --show    # print current rows
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${KASM_NAMESPACE:-kasm-workspaces}"
RELEASE="${KASM_RELEASE:-kasm-workspaces}"
NAME="${KASM_LDAP_NAME:?set KASM_LDAP_NAME in config.env}"
URL="${KASM_LDAP_URL:?set AD_DC_HOST/AD_DC_PORT in config.env}"
BIND_DN="${AD_BIND_DN:?set AD_BIND_USER in config.env}"
BASE_DN="${AD_BASE_DN:?set AD_BASE_OU in config.env}"
USERS_DN="${KASM_LDAP_USERS_GROUP_DN:?set it in config.env}"
ADMINS_DN="${KASM_LDAP_ADMINS_GROUP_DN:?set it in config.env}"
EMAIL_ATTR="${KASM_LDAP_EMAIL_ATTRIBUTE:-userPrincipalName}"
# Kasm substitutes the login name into {} - a filter without that placeholder
# matches every user in the base and the login fails as ambiguous.
FILTER="${KASM_LDAP_SEARCH_FILTER:-(&(objectClass=user)($EMAIL_ATTR={}))}"

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  --show)  MODE=show ;;
  "")      ;;
  *)       echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Double any single quote, so a value containing one cannot break out of the
# SQL string it is pasted into.
q() { printf "%s" "${1//\'/\'\'}"; }

command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

pod_for() { oc get pod -n "$NAMESPACE" -l "app.kubernetes.io/component=$1" \
              -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}'; }
DB_POD=$(pod_for db);  [[ -n "$DB_POD"  ]] || die "no running database pod in namespace $NAMESPACE"
API_POD=$(pod_for api); [[ -n "$API_POD" ]] || die "no running api pod in namespace $NAMESPACE"

# Inside the db pod, postgres trusts local connections - no password needed.
# The container is named after the release; the pod carries a version suffix.
psql_do() { oc exec -n "$NAMESPACE" "$DB_POD" -c "${RELEASE}-db" -- \
              psql -U kasmapp -d kasm -t -A -F' | ' -c "$1" 2>/dev/null; }

# Encrypt (or decrypt) with Kasm's own key, using Kasm's own code, in the api
# container. Only the installation_id is needed - no database connection.
INSTALLATION_ID=""
kasm_crypt() {  # <encrypt|decrypt> <value>   value arrives via env, never argv
  [[ -n "$INSTALLATION_ID" ]] || INSTALLATION_ID=$(psql_do "select installation_id from installation" | head -1)
  [[ -n "$INSTALLATION_ID" ]] || die "could not read installation_id"
  KASM_CRYPT_OP="$1" KASM_CRYPT_VAL="$2" \
  oc exec -i -n "$NAMESPACE" "$API_POD" -c "${RELEASE}-api-default" \
    -- env INSTALLATION_ID="$INSTALLATION_ID" OP="$1" VAL="$2" python3 - <<'PY' 2>/dev/null
import sys, os
sys.path.insert(0, '/src/api_server')
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from data.model import get_key
from sqlalchemy_utils.types.encrypted.encrypted_type import AesEngine, StringEncryptedType
t = StringEncryptedType(sa.VARCHAR(255), get_key, AesEngine, 'pkcs5')
d = postgresql.dialect()
v = os.environ['VAL']
sys.stdout.write(t.bind_processor(d)(v) if os.environ['OP'] == 'encrypt'
                 else t.result_processor(d, None)(v))
PY
}

if [[ "$MODE" == show ]]; then
  log "ldap_configs"
  psql_do "select name, url, search_base, email_attribute, enabled from ldap_configs" | sed 's/^/    /'
  log "sso_to_group_mapping"
  psql_do "select g.name, m.sso_group_attributes from sso_to_group_mapping m join groups g on g.group_id = m.group_id" | sed 's/^/    /'
  log "bind password"
  CIPHER=$(psql_do "select service_account_password from ldap_configs where name = '$(q "$NAME")'" | head -1)
  if [[ -z "$CIPHER" ]]; then
    info "not set"
  elif [[ -n "$(kasm_crypt decrypt "$CIPHER")" ]]; then
    info "stored, and Kasm can decrypt it"
  else
    info "stored, but Kasm CANNOT decrypt it - re-run this script without --show"
  fi
  exit 0
fi

log "Preflight"
info "url:    $URL"
info "bind:   $BIND_DN"
info "base:   $BASE_DN"
info "users:  $USERS_DN"
info "admins: $ADMINS_DN"

read -rsp "Password for ${BIND_DN}: " LDAP_PASSWORD
echo
[[ -n "$LDAP_PASSWORD" ]] || die "no password given"

if command -v ldapsearch >/dev/null; then
  log "Testing the bind"
  LDAPTLS_CACERT="${AD_CA_CERT_FILE:-}" ldapsearch -x -LLL -H "$URL" -D "$BIND_DN" -w "$LDAP_PASSWORD" \
      -b "$BASE_DN" -s base dn >/dev/null 2>&1 \
    || { unset LDAP_PASSWORD; die "bind failed against $URL as $BIND_DN - password, DN or TLS trust is wrong"; }
  info "bind OK"
else
  info "ldapsearch not installed - not testing the bind"
fi

if [[ "$MODE" == check ]]; then
  unset LDAP_PASSWORD
  log "--check: nothing written"
  exit 0
fi

log "Encrypting the bind password with Kasm's key"
ENC=$(kasm_crypt encrypt "$LDAP_PASSWORD")
unset LDAP_PASSWORD
[[ -n "$ENC" ]] || die "encryption produced nothing"
info "ciphertext produced (${#ENC} chars)"

# Kasm's built-in groups, by name - their ids are per-deployment.
ALL_USERS=$(psql_do "select group_id from groups where name = 'All Users'" | head -1)
ADMINS=$(psql_do "select group_id from groups where name = 'Administrators'" | head -1)
[[ -n "$ALL_USERS" && -n "$ADMINS" ]] || die "could not find Kasm's built-in groups - has db-init completed?"

log "Writing the LDAP configuration"
LDAP_ID=$(psql_do "select ldap_id from ldap_configs where name = '$(q "$NAME")'" | head -1)
if [[ -n "$LDAP_ID" ]]; then
  psql_do "update ldap_configs set url='$(q "$URL")', search_base='$(q "$BASE_DN")',
             search_filter='$(q "$FILTER")', search_subtree=true, enabled=true,
             auto_create_app_user=true, connection_timeout=10,
             email_attribute='$(q "$EMAIL_ATTR")',
             group_membership_filter='(|(memberOf=$(q "$USERS_DN"))(memberOf=$(q "$ADMINS_DN")))',
             service_account_dn='$(q "$BIND_DN")', service_account_password='$(q "$ENC")'
           where ldap_id = '$LDAP_ID'" >/dev/null
  info "updated existing config \"$NAME\""
else
  LDAP_ID=$(psql_do "insert into ldap_configs
      (name, enabled, url, auto_create_app_user, email_attribute, search_base, search_filter,
       search_subtree, service_account_dn, service_account_password, connection_timeout,
       group_membership_filter)
    values ('$(q "$NAME")', true, '$(q "$URL")', true, '$(q "$EMAIL_ATTR")', '$(q "$BASE_DN")',
       '$(q "$FILTER")', true, '$(q "$BIND_DN")', '$(q "$ENC")', 10,
       '(|(memberOf=$(q "$USERS_DN"))(memberOf=$(q "$ADMINS_DN")))')
    returning ldap_id" | head -1)
  info "created config \"$NAME\""
fi
[[ -n "$LDAP_ID" ]] || die "no ldap_id came back"

log "Mapping AD groups onto Kasm groups"
map() {  # <kasm group id> <ad group dn> <label>
  local existing
  existing=$(psql_do "select sso_group_id from sso_to_group_mapping
                      where ldap_id='$LDAP_ID' and group_id='$1'" | head -1)
  if [[ -n "$existing" ]]; then
    psql_do "update sso_to_group_mapping set sso_group_attributes='$(q "$2")'
             where sso_group_id='$existing'" >/dev/null
  else
    psql_do "insert into sso_to_group_mapping (sso_group_id, ldap_id, group_id, sso_group_attributes, apply_to_all_users)
             values (uuid_generate_v4(), '$LDAP_ID', '$1', '$(q "$2")', false)" >/dev/null
  fi
  info "$3"
}
map "$ALL_USERS" "$USERS_DN"  "kasm-users  -> All Users"
map "$ADMINS"    "$ADMINS_DN" "kasm-admins -> Administrators"

# The api and manager read this at startup, so they have to be restarted before
# a login will use it.
log "Restarting the components that read it"
oc rollout restart deployment -n "$NAMESPACE" -l app.kubernetes.io/component=api >/dev/null 2>&1 || true
oc rollout restart deployment -n "$NAMESPACE" -l app.kubernetes.io/component=manager >/dev/null 2>&1 || true
info "api and manager restarting"

log "Current configuration"
"$0" --show
