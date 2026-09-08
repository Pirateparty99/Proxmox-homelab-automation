#!/bin/bash
#
# Creates the ADCS credentials Secret and the ClusterAdcsIssuer.
#
# Requires the "Certification Authority Web Enrollment" role service on the CA
# host, reachable over HTTPS at ADCS_URL. Without it the issuer stays not-ready.
#
# ADCS_ENROLL_USER (config.env) must have Enroll rights on ADCS_TEMPLATE.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

[[ -f "$AD_CA_CERT_FILE" ]] || {
  echo "AD_CA_CERT_FILE not found: $AD_CA_CERT_FILE" >&2; exit 1; }

read -rsp "Password for ${ADCS_ENROLL_USER}@${AD_REALM}: " ADCS_PASSWORD
echo

# 'realm' is required in addition to username/password because the controller runs
# in kerberos auth mode (controllerManager.kerberosAuthentication.enabled=true).
# The CRD description claims only two keys are needed; the code requires three.
oc create secret generic "$ADCS_CREDENTIALS_SECRET" \
  --namespace "$ADCS_NAMESPACE" \
  --from-literal=username="$ADCS_ENROLL_USER" \
  --from-literal=password="$ADCS_PASSWORD" \
  --from-literal=realm="$AD_REALM" \
  --dry-run=client -o yaml | oc apply -f -

unset ADCS_PASSWORD

# bootstrap.py reads AD_CA_CERT_FILE and injects it as caBundle, so the
# certificate never has to live in a template.
render_templates --quiet
MANIFEST="$RENDER_DIR/helm/certificate-manager/adcs-clusterissuer.yaml"

oc apply -f "$MANIFEST"
oc get clusteradcsissuer "$ADCS_ISSUER_NAME"
