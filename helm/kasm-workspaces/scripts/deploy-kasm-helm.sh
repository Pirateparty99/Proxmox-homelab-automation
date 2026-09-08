#!/bin/bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

export KUBECONFIG=${KUBECONFIG:-~/.kube/config}
NAMESPACE=kasm-workspaces
RELEASE_NAME=kasm-workspaces

render_templates --quiet
VALUES="$RENDER_DIR/helm/kasm-workspaces/values.yaml"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "${RELEASE_NAME}" oci://registry-1.docker.io/kasmweb/kasm-helm \
  --version "${KASM_CHART_VERSION}" -n "${NAMESPACE}" -f "${VALUES}"
