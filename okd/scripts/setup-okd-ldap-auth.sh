#!/usr/bin/env bash
#
# setup-okd-ldap-auth.sh - configure Active Directory (LDAP) authentication on OKD,
#                          sync AD groups into the cluster, and grant cluster-admin
#                          to an AD group.
#
# Idempotent: re-running updates in place rather than duplicating.
#
# Prerequisites:
#   - oc, cluster-admin (KUBECONFIG set or `oc login` done)
#   - The AD CA certificate in PEM form. AD signs LDAPS with an internal CA, so
#     without it TLS verification fails. Export it on the CA server with:
#         certutil -ca.cert ca.cer
#     then convert:  openssl x509 -inform der -in ca.cer -out ad-ca.crt
#   - The bind account password (never passed on the command line; see below).
#
# Usage:
#   export LDAP_BIND_PASSWORD='...'                 # or omit to be prompted
#   ./setup-okd-ldap-auth.sh          # CA path comes from config.env
#   ./setup-okd-ldap-auth.sh --dry-run
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
# Site values come from config.env via lib/config.sh; anything here can still be
# overridden per-run with an environment variable.
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

LDAP_HOST="${LDAP_HOST:-$AD_DC_HOST}"             # must match the DC cert SAN
LDAP_PORT="${LDAP_PORT:-$AD_DC_PORT}"
BASE_DN="${BASE_DN:-$AD_BASE_DN}"
GROUP_BASE_DN="${GROUP_BASE_DN:-$AD_GROUP_BASE_DN}"
BIND_DN="${BIND_DN:-$AD_BIND_DN}"
IDP_NAME="${IDP_NAME:-$OKD_IDP_NAME}"
CA_CONFIGMAP="${CA_CONFIGMAP:-ldap-ca}"
BIND_SECRET="${BIND_SECRET:-ldap-bind-password}"
CA_CERT_FILE="${CA_CERT_FILE:-$AD_CA_CERT_FILE}"

# AD group granted cluster-admin. Must match the OpenShift Group name produced by
# the sync below, which uses the AD group's cn (see groupNameAttributes).
ADMIN_AD_GROUP="${ADMIN_AD_GROUP:-$OKD_ADMIN_GROUP}"
ADMIN_ROLE="${ADMIN_ROLE:-$OKD_ADMIN_ROLE}"

# Read-only group. "cluster-reader" is OpenShift's cluster-wide read role: it can
# get/list/watch cluster-scoped resources (nodes, PVs, projects, CRDs) as well as
# namespaced ones, and it cannot read secrets. The upstream Kubernetes "view" role
# is narrower - namespaced resources only - so cluster-reader is the correct choice
# for "read the whole cluster". Neither grants any write verb.
VIEWER_AD_GROUP="${VIEWER_AD_GROUP:-$OKD_VIEWER_GROUP}"
VIEWER_ROLE="${VIEWER_ROLE:-$OKD_VIEWER_ROLE}"

# AD group -> cluster role. Drives the explicit sync and the bindings below.
GROUP_ROLES=(
  "${ADMIN_AD_GROUP}:${ADMIN_ROLE}"
  "${VIEWER_AD_GROUP}:${VIEWER_ROLE}"
)

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT

# ------------------------------------------------------------------- preflight
log "Preflight"
command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated"
info "oc user:   $(oc whoami)"
info "ldap host: ${LDAP_HOST}:${LDAP_PORT}"

if command -v openssl >/dev/null; then
  if echo | timeout 10 openssl s_client -connect "${LDAP_HOST}:${LDAP_PORT}" >/dev/null 2>&1; then
    info "ldaps:     reachable"
  else
    warn "cannot reach ${LDAP_HOST}:${LDAP_PORT} - check DNS and firewall"
  fi
fi

# ------------------------------------------------------------------ CA bundle
log "CA certificate (configmap '${CA_CONFIGMAP}')"
if oc get configmap "$CA_CONFIGMAP" -n openshift-config >/dev/null 2>&1; then
  info "already present - not replacing (delete it first to rotate)"
elif [[ -n "$CA_CERT_FILE" ]]; then
  [[ -f "$CA_CERT_FILE" ]] || die "CA_CERT_FILE '$CA_CERT_FILE' not found"
  grep -q "BEGIN CERTIFICATE" "$CA_CERT_FILE" \
    || die "'$CA_CERT_FILE' is not PEM. Convert: openssl x509 -inform der -in <file>.cer -out <file>.pem"
  run "oc create configmap ${CA_CONFIGMAP} --from-file=ca.crt='${CA_CERT_FILE}' -n openshift-config"
  info "created from ${CA_CERT_FILE}"
elif (( DRY_RUN )); then
  warn "no '${CA_CONFIGMAP}' configmap and CA_CERT_FILE not set (continuing: dry-run)"
else
  die "no '${CA_CONFIGMAP}' configmap and CA_CERT_FILE not set.
    LDAPS uses your internal AD CA; without it TLS verification fails and no
    LDAP login will succeed. Export it, then re-run with CA_CERT_FILE=<pem>."
fi

# -------------------------------------------------------------- bind password
log "Bind password (secret '${BIND_SECRET}')"
if [[ -n "${LDAP_BIND_PASSWORD:-}" ]]; then
  # --from-literal keeps the value out of argv of any child process
  run "oc create secret generic ${BIND_SECRET} --from-literal=bindPassword=\"\$LDAP_BIND_PASSWORD\" -n openshift-config --dry-run=client -o yaml | oc apply -f -"
  info "created/updated from \$LDAP_BIND_PASSWORD"
elif oc get secret "$BIND_SECRET" -n openshift-config >/dev/null 2>&1; then
  info "already present - reusing (set LDAP_BIND_PASSWORD to rotate)"
elif (( DRY_RUN )); then
  info "[dry-run] would prompt for the bind password"
else
  read -rsp "    password for ${BIND_DN}: " pw; echo
  [[ -n "$pw" ]] || die "empty password"
  oc create secret generic "$BIND_SECRET" --from-literal=bindPassword="$pw" \
     -n openshift-config --dry-run=client -o yaml | oc apply -f - >/dev/null
  unset pw
  info "created"
fi

# ------------------------------------------------------------- identity provider
log "Identity provider '${IDP_NAME}'"
LDAP_URL="ldaps://${LDAP_HOST}:${LDAP_PORT}/${BASE_DN}?sAMAccountName?sub?(&(objectClass=user)(objectCategory=person))"
cat > "$WORKDIR/oauth.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
    - name: ${IDP_NAME}
      mappingMethod: claim
      type: LDAP
      ldap:
        url: "${LDAP_URL}"
        bindDN: "${BIND_DN}"
        bindPassword:
          name: ${BIND_SECRET}
        ca:
          name: ${CA_CONFIGMAP}
        insecure: false
        attributes:
          # AD uses sAMAccountName. 'uid' does not exist in AD, and using 'dn'
          # as the id produces full DNs as usernames.
          id:                [ sAMAccountName ]
          preferredUsername: [ sAMAccountName ]
          name:              [ displayName ]
          email:             [ mail ]
EOF
run "oc apply -f '$WORKDIR/oauth.yaml'"
info "applied (url: ${LDAP_URL})"

# ----------------------------------------------------------------- group sync
# The LDAP identity provider authenticates users but does NOT import groups.
# Group-based RBAC therefore needs an explicit sync.
log "AD group sync"
cat > "$WORKDIR/group-sync.yaml" <<EOF
kind: LDAPSyncConfig
apiVersion: v1
url: ldaps://${LDAP_HOST}:${LDAP_PORT}
bindDN: "${BIND_DN}"
bindPassword:
  file: "${WORKDIR}/bindpw"
ca: "${WORKDIR}/ca.pem"
insecure: false
augmentedActiveDirectory:
  groupsQuery:
    # No "filter" here on purpose: OpenShift rejects the config with
    #   groupsQuery.filter: cannot specify a filter when using "dn" as the UID attribute
    # because a dn-keyed group query is a base lookup, not a search. GROUP_BASE_DN
    # already scopes this to the Groups OU, so the objectClass filter was redundant.
    baseDN: "${GROUP_BASE_DN}"
    scope: sub
    derefAliases: never
    pageSize: 0
  groupUIDAttribute: dn
  # Name synced OpenShift Groups from cn, NOT sAMAccountName. In this domain they
  # diverge: CN=okd-admins has sAMAccountName "okd-adm" (AD does not update
  # sAMAccountName when a group is renamed). Using sAMAccountName here would
  # create a Group named "okd-adm" and the cluster-admin binding below would
  # silently never match.
  groupNameAttributes: [ cn ]
  usersQuery:
    baseDN: "${BASE_DN}"
    scope: sub
    derefAliases: never
    filter: (objectClass=user)
    pageSize: 0
  userNameAttributes: [ sAMAccountName ]
  groupMembershipAttributes: [ memberOf ]
EOF
if (( DRY_RUN )); then
  info "[dry-run] oc adm groups sync --sync-config=<config> --confirm"
else
  oc get secret "$BIND_SECRET" -n openshift-config -o jsonpath='{.data.bindPassword}' | base64 -d > "$WORKDIR/bindpw"
  oc get configmap "$CA_CONFIGMAP" -n openshift-config -o jsonpath='{.data.ca\.crt}' > "$WORKDIR/ca.pem"
  chmod 600 "$WORKDIR/bindpw"
  if oc adm groups sync --sync-config="$WORKDIR/group-sync.yaml" --confirm 2>"$WORKDIR/sync.err" | tail -5; then
    info "synced"
  else
    warn "group sync failed:"; sed 's/^/      /' "$WORKDIR/sync.err" | head -5
    warn "RBAC below is still applied; it takes effect once the group exists."
  fi

  # An augmentedActiveDirectory sync derives groups from each user's memberOf, so a
  # group with no members is invisible to the sweep above and is never created.
  # Every group targeted by RBAC below must exist regardless of membership, so sync
  # those explicitly by DN via a whitelist.
  for pair in "${GROUP_ROLES[@]}"; do
    g="${pair%%:*}"
    echo "CN=${g},${GROUP_BASE_DN}" > "$WORKDIR/wl.txt"
    if oc adm groups sync --sync-config="$WORKDIR/group-sync.yaml" \
         --whitelist="$WORKDIR/wl.txt" --confirm >/dev/null 2>"$WORKDIR/wl.err"; then
      info "group '${g}' synced explicitly"
    else
      warn "could not sync '${g}' by DN:"
      sed 's/^/      /' "$WORKDIR/wl.err" | head -3
      warn "check that CN=${g},${GROUP_BASE_DN} exists"
    fi
  done
fi

# ----------------------------------------------------------------------- RBAC
log "Cluster role bindings"
# Safe to apply before a group exists - a binding activates when the group appears.
for pair in "${GROUP_ROLES[@]}"; do
  g="${pair%%:*}"; r="${pair##*:}"
  run "oc adm policy add-cluster-role-to-group ${r} ${g}" >/dev/null
  info "${g} -> ${r}"
done

# --------------------------------------------------------------------- verify
if (( DRY_RUN )); then log "Dry run complete - nothing was changed"; exit 0; fi
log "Result"
info "identity providers:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}      {.name} ({.type}){"\n"}{end}'
for pair in "${GROUP_ROLES[@]}"; do
  g="${pair%%:*}"; r="${pair##*:}"
  info "bindings for ${g}:"
  oc get clusterrolebinding -o json \
    | jq -r --arg g "$g" '.items[] | select(.subjects[]?|select(.kind=="Group" and .name==$g)) | "      \(.metadata.name) -> \(.roleRef.name)"' 2>/dev/null \
    | sort -u
  members="$(oc get group "$g" -o jsonpath='{.users[*]}' 2>/dev/null || true)"
  if [[ -z "$members" ]]; then
    warn "AD group '${g}' has NO members, so nobody holds ${r} yet."
    warn "Add a user to it in AD, then re-run this script to re-sync."
  else
    info "${g} members: ${members}"
  fi
done

# A cluster-wide read role does not by itself make a user read-only: OpenShift ships
# a "self-provisioners" binding granting project creation to every authenticated
# user, and the creator becomes admin of the project they create.
if oc get clusterrolebinding self-provisioners >/dev/null 2>&1 \
   && [[ -n "$(oc get clusterrolebinding self-provisioners -o jsonpath='{.subjects}' 2>/dev/null)" ]]; then
  warn "'self-provisioners' still lets ALL authenticated users create projects and"
  warn "become admin within them, so '${VIEWER_AD_GROUP}' is not strictly read-only."
  warn "To close that (affects EVERY user, not just ${VIEWER_AD_GROUP}):"
  warn "  oc patch clusterrolebinding.rbac self-provisioners --type=merge -p '{\"subjects\":null}'"
fi

info "synced groups (first 10):"
oc get groups --no-headers 2>/dev/null | head -10 | awk '{printf "      %-24s %s\n", $1, $2}' || info "      (none yet)"
echo
info "NOTE: the authentication operator redeploys the OAuth pods after a change;"
info "      allow ~1 minute before testing a login."
