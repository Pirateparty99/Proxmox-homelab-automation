#!/bin/bash
#
# Installs cert-manager, then the ADCS issuer. Versions come from config.env.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

render_templates --quiet

echo "Installing Cert Manager version $CERT_MANAGER_VERSION with Helm:"
"$REPO_ROOT/scripts/helm/helm-deploy.sh" \
  --chart cert-manager \
  --release cert-manager \
  --namespace cert-manager \
  --values "$RENDER_DIR/helm/certificate-manager/cert-man-values.yaml" \
  --set installCRDs=true \
  --wait

echo "Installing ADCS Issuer version $ADCS_ISSUER_VERSION for Cert Manager:"
ISSUER_VERSION="$ADCS_ISSUER_VERSION" "$SCRIPT_DIR/deploy-adcs-clusterissuer-helm.sh"

echo "Configuring ADCS cluster cert issuer:"
ISSUER_VERSION="$ADCS_ISSUER_VERSION" "$SCRIPT_DIR/configure-clusterissuer.sh"
