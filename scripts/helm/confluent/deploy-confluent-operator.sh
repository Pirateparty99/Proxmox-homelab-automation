#!/bin/bash
#
# deploy-confluent-operator.sh - install Confluent for Kubernetes (CFK).
#
# CFK is the operator; it does not create a Kafka cluster by itself. Once it is
# running you create Confluent CRs (Kafka, KRaftController, SchemaRegistry,
# Connect...) in the same namespace and the operator reconciles them.
#
# The chart is taken from the local cache when scripts/helm/pull-charts.sh has
# populated it, and from packages.confluent.io otherwise.
#
# Usage:
#   scripts/helm/confluent/deploy-confluent-operator.sh
#   scripts/helm/confluent/deploy-confluent-operator.sh --dry-run   # render only
#   scripts/helm/confluent/deploy-confluent-operator.sh --status    # what is running
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${CONFLUENT_NAMESPACE:?set CONFLUENT_NAMESPACE in config.env}"
RELEASE="${CONFLUENT_RELEASE:?set CONFLUENT_RELEASE in config.env}"

MODE=install
case "${1:-}" in
  --dry-run) MODE=dryrun ;;
  --status)  MODE=status ;;
  "")        ;;
  *)         echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v helm >/dev/null || die "helm not found in PATH"
command -v oc >/dev/null || die "oc not found in PATH"

if [[ "$MODE" == status ]]; then
  log "Operator"
  oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null | sed 's/^/    /' || info "not installed"
  log "Confluent CRDs registered"
  oc get crd -o name 2>/dev/null | grep -c "platform.confluent.io" | sed 's/^/    /'
  log "Confluent resources in ${NAMESPACE}"
  oc get kafka,kraftcontroller,schemaregistry,connect -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /' \
    || info "none yet - the operator is installed but no cluster is defined"
  exit 0
fi

oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

render_templates --quiet
VALUES="$RENDER_DIR/helm/confluent/values.yaml"
[[ -f "$VALUES" ]] || die "missing $VALUES - did bootstrap.py run?"

read -ra CHART <<< "$(chart_args confluent-for-kubernetes)"
log "Chart"
info "${CHART[*]}"

if [[ "$MODE" == dryrun ]]; then
  log "Rendering only"
  helm template "$RELEASE" "${CHART[@]}" -n "$NAMESPACE" --values "$VALUES" \
    | grep -E "^kind:|^  name:" | paste - - | sed 's/^/    /'
  exit 0
fi

log "Namespace ${NAMESPACE}"
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null
info "ready"

log "Installing ${RELEASE}"
helm upgrade --install "$RELEASE" "${CHART[@]}" \
  --namespace "$NAMESPACE" \
  --values "$VALUES"

# The chart names the Deployment after .Values.name, not the release, so it is
# only called "confluent-operator" by coincidence of the default. Find it by the
# instance label instead, which helm always sets to the release.
log "Waiting for the operator to become available"
DEPLOY=$(oc get deployment -n "$NAMESPACE" \
           -l "app.kubernetes.io/instance=${RELEASE}" -o name 2>/dev/null | head -1)
[[ -n "$DEPLOY" ]] || die "helm reported success but no Deployment carries instance=${RELEASE}"
info "${DEPLOY#deployment.apps/}"
if ! oc rollout status "$DEPLOY" -n "$NAMESPACE" --timeout=300s; then
  info "rollout did not complete - recent events:"
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /'
  die "operator did not start"
fi

log "Installed"
oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" --no-headers 2>/dev/null | sed 's/^/    /'
info "$(oc get crd -o name 2>/dev/null | grep -c platform.confluent.io) Confluent CRDs registered"
cat <<EOF

    The operator is running but there is no Kafka cluster yet - CFK waits for
    Confluent CRs. To define one, create a KRaftController and a Kafka in
    ${NAMESPACE}; see https://docs.confluent.io/operator/current/co-deploy-cfk.html

    Status at any time:
      scripts/helm/confluent/deploy-confluent-operator.sh --status
EOF
