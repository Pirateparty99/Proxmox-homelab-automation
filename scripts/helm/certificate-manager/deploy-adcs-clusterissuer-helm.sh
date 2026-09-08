#!/bin/bash
#
# Installs/upgrades the ADCS issuer. Site values come from config.env; the values
# file is rendered from adcs-issuer-values.yaml.tmpl into rendered/.
#
# ISSUER_VERSION is exported by deploy-cert-man.sh; otherwise it falls back to
# ADCS_ISSUER_VERSION from config.env. There is no hardcoded default - unset,
# this fails instead of letting helm consume the next argument as the version.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ISSUER_VERSION="${ISSUER_VERSION:-${ADCS_ISSUER_VERSION:-}}"
: "${ISSUER_VERSION:?not set - add ADCS_ISSUER_VERSION to config.env}"

render_templates --quiet
VALUES="$RENDER_DIR/helm/certificate-manager/adcs-issuer-values.yaml"

helm repo add djkormo-adcs-issuer https://djkormo.github.io/adcs-issuer/
helm repo update djkormo-adcs-issuer

# No --set installCRDs=true: that key belongs to cert-manager, not this chart, so
# helm silently ignored it. CRDs are controlled by crd.install in the values file.
helm upgrade --install adcs-issuer djkormo-adcs-issuer/adcs-issuer \
  --namespace "$ADCS_NAMESPACE" \
  --create-namespace \
  --version "$ISSUER_VERSION" \
  --values "$VALUES"

# helm reports "deployed" as soon as the Deployment applies. SCC rejections happen
# later, on the ReplicaSet, so check the rollout actually finished.
oc rollout status deployment/adcs-issuer-controller-manager -n "$ADCS_NAMESPACE" --timeout=180s
