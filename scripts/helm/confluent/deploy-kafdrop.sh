#!/bin/bash
#
# deploy-kafdrop.sh - a read-only web UI for the Kafka cluster.
#
# Exists to answer "is Kafka actually up?" without exec'ing into a broker: it
# lists brokers, topics, partitions and consumer group lag in a browser.
#
# Plain manifests, not Helm - Kafdrop publishes no hosted chart, and this is a
# Deployment, a Service and a Route. deploy-kafka-cluster.sh runs it for you.
#
# Usage:
#   scripts/helm/confluent/deploy-kafdrop.sh
#   scripts/helm/confluent/deploy-kafdrop.sh --status
#   scripts/helm/confluent/deploy-kafdrop.sh --delete
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${CONFLUENT_NAMESPACE:?set CONFLUENT_NAMESPACE in config.env}"

MODE=apply
case "${1:-}" in
  --status) MODE=status ;;
  --delete) MODE=delete ;;
  "")       ;;
  *)        echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

render_templates --quiet
MANIFEST="$RENDER_DIR/confluent/kafdrop.yaml"
[[ -f "$MANIFEST" ]] || die "missing $MANIFEST - did bootstrap.py run?"

if [[ "$MODE" == status ]]; then
  log "Kafdrop"
  oc get deployment,svc,route -n "$NAMESPACE" -l app=kafdrop 2>/dev/null | sed 's/^/    /' || info "not deployed"
  HOST=$(oc get route kafdrop -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "$HOST" ]] && info "https://${HOST}"
  exit 0
fi

if [[ "$MODE" == delete ]]; then
  log "Removing Kafdrop"
  oc delete -f "$MANIFEST" --ignore-not-found 2>&1 | sed 's/^/    /'
  exit 0
fi

log "Applying"
oc apply -f "$MANIFEST" 2>&1 | sed 's/^/    /'

log "Waiting for Kafdrop"
if ! oc rollout status deployment/kafdrop -n "$NAMESPACE" --timeout=240s; then
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -10 | sed 's/^/    /'
  die "Kafdrop did not start"
fi

HOST=$(oc get route kafdrop -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
log "Ready"
info "https://${HOST}"
info "the broker list on that page is the check that Kafka is serving"
