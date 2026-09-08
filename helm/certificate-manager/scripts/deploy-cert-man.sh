#!/bin/bash
#
# Installs cert-manager, then the ADCS issuer. Versions come from config.env.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "Installing Cert Manager version $CERT_MANAGER_VERSION with Helm:"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --values "$SCRIPT_DIR/../cert-man-values.yaml" \
  --set installCRDs=true

echo "Installing ADCS Issuer version $ADCS_ISSUER_VERSION for Cert Manager:"
ISSUER_VERSION="$ADCS_ISSUER_VERSION" "$SCRIPT_DIR/deploy-adcs-clusterissuer-helm.sh"

echo "Configuring ADCS cluster cert issuer:"
ISSUER_VERSION="$ADCS_ISSUER_VERSION" "$SCRIPT_DIR/configure-clusterissuer.sh"
