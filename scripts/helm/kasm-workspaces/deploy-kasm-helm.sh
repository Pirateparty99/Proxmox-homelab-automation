#!/bin/bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

export KUBECONFIG=${KUBECONFIG:-~/.kube/config}
NAMESPACE=kasm-workspaces
RELEASE_NAME=kasm-workspaces

render_templates --quiet
VALUES="$RENDER_DIR/helm/kasm-workspaces/values.yaml"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# A Job's spec.template is immutable, and this chart does not mark db-init as a
# helm hook - so helm tries to patch it in place and any values change that
# alters its pod template fails the entire upgrade:
#   Job.batch "kasm-workspaces-db-init" is invalid: spec.template: field is immutable
# Deleting it first lets helm recreate it. It is an idempotent init job: it
# checks whether the schema is already at head and exits if so.
kubectl delete job "${RELEASE_NAME}-db-init" -n "$NAMESPACE" --ignore-not-found

helm upgrade --install "${RELEASE_NAME}" oci://registry-1.docker.io/kasmweb/kasm-helm \
  --version "${KASM_CHART_VERSION}" -n "${NAMESPACE}" -f "${VALUES}"
