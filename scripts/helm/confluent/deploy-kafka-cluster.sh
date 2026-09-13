#!/bin/bash
#
# deploy-kafka-cluster.sh - create the Kafka cluster CFK reconciles.
#
# These are Custom Resources, not a Helm chart: the CFK operator must already be
# running and its CRDs registered, or the apply is rejected. Run
# deploy-confluent-operator.sh first.
#
# Usage:
#   scripts/helm/confluent/deploy-kafka-cluster.sh
#   scripts/helm/confluent/deploy-kafka-cluster.sh --dry-run   # server-side validate
#   scripts/helm/confluent/deploy-kafka-cluster.sh --status
#   scripts/helm/confluent/deploy-kafka-cluster.sh --delete    # remove the CRs
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${CONFLUENT_NAMESPACE:?set CONFLUENT_NAMESPACE in config.env}"

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dryrun ;;
  --status)  MODE=status ;;
  --delete)  MODE=delete ;;
  "")        ;;
  *)         echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

if [[ "$MODE" == status ]]; then
  log "Cluster resources in ${NAMESPACE}"
  oc get kraftcontroller,kafka -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /' || info "none - CRDs missing or nothing applied"
  log "Pods"
  oc get pods -n "$NAMESPACE" -l "platform.confluent.io/type" --no-headers 2>/dev/null | sed 's/^/    /' \
    || oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | sed 's/^/    /'
  log "Storage"
  oc get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | sed 's/^/    /' || info "no PVCs"
  exit 0
fi

render_templates --quiet
MANIFEST="$RENDER_DIR/confluent/kafka-cluster.yaml"
[[ -f "$MANIFEST" ]] || die "missing $MANIFEST - did bootstrap.py run?"

if [[ "$MODE" == delete ]]; then
  log "Deleting the Kafka cluster"
  info "PVCs are deliberately left behind - deleting them destroys the log data"
  oc delete -f "$MANIFEST" --ignore-not-found 2>&1 | sed 's/^/    /'
  info "to remove the data too: oc delete pvc -n ${NAMESPACE} --all"
  exit 0
fi

log "Preflight"
# The CRDs only exist once the operator chart is installed, and a plain apply
# against a missing CRD fails with "no matches for kind", which reads like a
# typo rather than a missing operator.
for kind in kraftcontrollers kafkas; do
  oc get crd "${kind}.platform.confluent.io" >/dev/null 2>&1 \
    || die "CRD ${kind}.platform.confluent.io not registered - run deploy-confluent-operator.sh first"
done
info "Confluent CRDs registered"

OPERATOR=$(oc get pods -n "$NAMESPACE" -l "app=confluent-operator" \
             -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')
[[ -n "$OPERATOR" ]] || die "no running CFK operator in ${NAMESPACE} - run deploy-confluent-operator.sh first"
info "operator running: $OPERATOR"

SC="${KAFKA_STORAGE_CLASS}"
oc get storageclass "$SC" >/dev/null 2>&1 || die "StorageClass '$SC' not found - set KAFKA_STORAGE_CLASS in config.env"
info "storage class: $SC"

if [[ "$MODE" == dryrun ]]; then
  log "Server-side validation (nothing created)"
  oc apply -f "$MANIFEST" --dry-run=server 2>&1 | sed 's/^/    /'
  exit 0
fi

log "Applying"
oc apply -f "$MANIFEST" 2>&1 | sed 's/^/    /'

# The controllers must have quorum before brokers can register, so they are
# waited on first - otherwise the Kafka pods look stuck for reasons that have
# nothing to do with Kafka.
log "Waiting for the KRaft controller"
oc rollout status statefulset/"$KAFKA_KRAFT_NAME" -n "$NAMESPACE" --timeout=600s 2>&1 | sed 's/^/    /' || {
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /'
  die "KRaft controller did not become ready"
}

log "Waiting for Kafka"
oc rollout status statefulset/"$KAFKA_NAME" -n "$NAMESPACE" --timeout=600s 2>&1 | sed 's/^/    /' || {
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /'
  die "Kafka did not become ready"
}

log "Ready"
oc get kraftcontroller,kafka -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /'
cat <<EOF

    Bootstrap endpoint inside the cluster:
      ${KAFKA_NAME}.${NAMESPACE}.svc.cluster.local:9092

    Create a topic with a KafkaTopic CR, or from a broker pod:
      oc exec -n ${NAMESPACE} ${KAFKA_NAME}-0 -- kafka-topics \\
        --bootstrap-server localhost:9092 --create --topic demo
EOF
