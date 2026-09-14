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

ISSUER_VERSION="${ISSUER_VERSION:-${ADCS_ISSUER_VERSION:-}}"
: "${ISSUER_VERSION:?not set - add ADCS_ISSUER_VERSION to config.env}"

render_templates --quiet

# No --set installCRDs=true: that key belongs to cert-manager, not this chart, so
# helm silently ignored it. CRDs are controlled by crd.install in the values file.
#
# --wait matters here specifically: helm reports "deployed" as soon as the
# Deployment applies, but this chart has historically been rejected later by the
# SCC, which only shows up on the ReplicaSet.
"$REPO_ROOT/scripts/helm/helm-deploy.sh" \
  --chart adcs-issuer \
  --release adcs-issuer \
  --namespace "$ADCS_NAMESPACE" \
  --values "$RENDER_DIR/helm/certificate-manager/adcs-issuer-values.yaml" \
  --wait --timeout 180s
