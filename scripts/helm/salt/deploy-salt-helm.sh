#!/bin/bash
#
# deploy-salt-helm.sh - deploy the Salt master chart to OKD.
#
# The chart is developed in its own repo (SALT_CHART_PATH); this script supplies
# the cluster-specific values and goes through scripts/helm/helm-deploy.sh like
# every other Helm deployment here.
#
# Minions outside the cluster connect over raw TCP on 4505/4506. A Route cannot
# carry those - it terminates HTTP - and this cluster has no LoadBalancer
# controller, so the service is published as NodePort and minions point at a
# node address.
#
# Usage:
#   scripts/helm/salt/deploy-salt-helm.sh
#   scripts/helm/salt/deploy-salt-helm.sh --dry-run
#   scripts/helm/salt/deploy-salt-helm.sh --status
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

CHART="${SALT_CHART_PATH:?set SALT_CHART_PATH in config.env}"
NAMESPACE="${SALT_NAMESPACE:?set SALT_NAMESPACE in config.env}"
RELEASE="${SALT_RELEASE:?set SALT_RELEASE in config.env}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found in PATH"

if [[ "${1:-}" == "--status" ]]; then
  log "Master"
  oc get pods,svc -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null | sed 's/^/    /' || info "not deployed"
  log "Minion keys"
  oc exec -n "$NAMESPACE" "${RELEASE}-0" -- salt-key -L 2>/dev/null | sed 's/^/    /' || info "master not running"
  exit 0
fi

[[ -d "$CHART" ]] || die "chart not found at $CHART
    It lives in the salt-stack-helm repo; clone it or fix SALT_CHART_PATH."

DEPLOY_ARGS=(
  --chart "$CHART"
  --release "$RELEASE"
  --namespace "$NAMESPACE"
  --set "service.type=${SALT_SERVICE_TYPE:-NodePort}"
  --set "service.nodePorts.publish=${SALT_NODEPORT_PUBLISH:-30505}"
  --set "service.nodePorts.ret=${SALT_NODEPORT_RET:-30506}"
  --set "image.tag=${SALT_VERSION:-}"
)

# The UI is served by salt-api, so it needs the api on. The Route carries only
# the api - 4505/4506 are raw TCP and stay on the NodePort above.
if [[ "${SALT_API_ENABLED:-false}" == "true" ]]; then
  DEPLOY_ARGS+=(--set "api.enabled=true")
  [[ "${SALT_GUI_ENABLED:-false}" == "true" ]] && DEPLOY_ARGS+=(--set "saltgui.enabled=true")
  if [[ -n "${SALT_FQDN:-}" ]]; then
    DEPLOY_ARGS+=(--set "route.enabled=true" --set "route.host=${SALT_FQDN}")
  fi
  # Only wire up external_auth once the Secret exists: without the bind
  # password salt-api would start and refuse every login, which looks like a
  # credential problem rather than a missing Secret.
  if oc get secret "${SALT_LDAP_SECRET:-salt-ldap}" -n "$NAMESPACE" >/dev/null 2>&1; then
    DEPLOY_ARGS+=(
      --set "externalAuth.enabled=true"
      --set "externalAuth.existingSecret=${SALT_LDAP_SECRET:-salt-ldap}"
      --set-json "externalAuth.config={\"ldap\":{\"${SALT_LDAP_ADMINS_GROUP}%\":[\".*\",\"@runner\",\"@wheel\",\"@jobs\"]}}"
    )
    info "LDAP auth: group '${SALT_LDAP_ADMINS_GROUP}' (Salt matches the CN, not the DN)"
  else
    info "no ${SALT_LDAP_SECRET:-salt-ldap} Secret - the API will have no way to"
    info "authenticate anyone. Run scripts/helm/salt/configure-salt-ldap.sh first."
  fi
fi
[[ "${1:-}" == "--dry-run" ]] && DEPLOY_ARGS+=(--dry-run) || DEPLOY_ARGS+=(--wait)

"$REPO_ROOT/scripts/helm/helm-deploy.sh" "${DEPLOY_ARGS[@]}"
[[ "${1:-}" == "--dry-run" ]] && exit 0

# A StatefulSet will not replace a pod that never becomes Ready, so a values
# change on top of a crash-looping master silently does nothing. Say so rather
# than leaving it looking deployed.
if ! oc get pod "${RELEASE}-0" -n "$NAMESPACE" \
     -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
  info "the master pod is not Ready; if it is crash-looping, delete it so the"
  info "StatefulSet recreates it with the current template:"
  info "  oc delete pod ${RELEASE}-0 -n ${NAMESPACE}"
fi

log "Master reachable at"
info "in-cluster:  ${RELEASE}.${NAMESPACE}.svc.cluster.local:4505"
info "from a VM:   ${SALT_MASTER_ADDR:-<a node address>}:${SALT_NODEPORT_PUBLISH:-30505}"
if [[ "${SALT_GUI_ENABLED:-false}" == "true" && -n "${SALT_FQDN:-}" ]]; then
  # /app, not /: rest_cherrypy serves the API at the root and the UI at /app.
  info "web UI:      https://${SALT_FQDN}/app  (sign in with eauth type 'ldap')"
fi
info ""
info "Install a minion with: scripts/helm/salt/install-salt-minion.sh"
