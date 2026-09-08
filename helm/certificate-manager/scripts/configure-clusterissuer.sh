#!/bin/bash
#
# Creates the ADCS credentials Secret and the ClusterAdcsIssuer.
#
# Requires the "Certification Authority Web Enrollment" role service on the CA
# host, reachable over HTTPS at ADCS_URL. Without it the issuer stays not-ready,
# so this script checks for it up front rather than letting you find out later -
# see ad/scripts/Install-AdcsWebEnrollment.ps1 to put it there.
#
# ADCS_ENROLL_USER (config.env) must have Enroll rights on ADCS_TEMPLATE.
#
# SKIP_PREFLIGHT=1 bypasses the reachability check.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

[[ -f "$AD_CA_CERT_FILE" ]] || {
  echo "AD_CA_CERT_FILE not found: $AD_CA_CERT_FILE" >&2; exit 1; }

# --------------------------------------------------------------------- preflight
#
# The controller reports a bad URL only as a not-ready issuer with a terse
# message, and the two common causes - web enrollment absent, or an IIS
# certificate the AD root does not sign - look identical from inside the cluster.
# Checking from here separates them while the fix is still obvious.
#
# Verifying against AD_CA_CERT_FILE rather than -k is deliberate: this is the
# same trust decision the controller makes with caBundle, so a pass here means
# the bundle it gets is the right one.
preflight_certsrv() {
    local code rc
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
                --cacert "$AD_CA_CERT_FILE" --max-time 15 "$ADCS_URL/" 2>/dev/null) && rc=0 || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "Cannot reach $ADCS_URL (curl exit $rc)" >&2
        case $rc in
          6)  echo "  DNS: ${ADCS_HOST} does not resolve from here." >&2 ;;
          7|28)
              # certsrv on port 80 but nothing on 443 is the usual state of a CA
              # that has web enrollment installed but never published over TLS.
              echo "  Nothing answering on ${ADCS_HOST}:443." >&2
              if curl -sS -o /dev/null --max-time 8 "http://${ADCS_HOST}/certsrv/" 2>/dev/null; then
                  echo "  /certsrv DOES answer over plain HTTP, so the role service is installed" >&2
                  echo "  and only the HTTPS binding is missing. Run, on ${ADCS_HOST}:" >&2
                  echo "    ad/scripts/Install-AdcsWebEnrollment.ps1" >&2
              else
                  echo "  Check IIS is running and the Windows Firewall allows 443." >&2
              fi ;;
          35) echo "  TLS handshake failed - no HTTPS binding on port 443?" >&2 ;;
          60) echo "  Certificate not trusted by $AD_CA_CERT_FILE." >&2
              echo "  The IIS certificate on ${ADCS_HOST} must be signed by this CA." >&2 ;;
        esac
        return 1
    fi

    case "$code" in
      401|200)
        # 401 is the expected answer: certsrv is there and demanding credentials.
        echo "  $ADCS_URL -> $code (web enrollment present)" ;;
      404)
        echo "$ADCS_URL -> 404: the ADCS-Web-Enrollment role service is not installed." >&2
        echo "  Run ad/scripts/Install-AdcsWebEnrollment.ps1 on ${ADCS_HOST}." >&2
        return 1 ;;
      *)
        echo "$ADCS_URL -> $code (unexpected; continuing)" >&2 ;;
    esac
}

if [[ "${SKIP_PREFLIGHT:-}" == "1" ]]; then
    echo "Skipping certsrv preflight (SKIP_PREFLIGHT=1)."
else
    echo "Checking $ADCS_URL ..."
    preflight_certsrv
fi

# -------------------------------------------------------------------- credentials

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

# ------------------------------------------------------------------------ issuer

# bootstrap.py reads AD_CA_CERT_FILE and injects it as caBundle, so the
# certificate never has to live in a template.
render_templates --quiet
MANIFEST="$RENDER_DIR/helm/certificate-manager/adcs-clusterissuer.yaml"

oc apply -f "$MANIFEST"

# The CRD declares no structural status schema, so `oc wait --for=condition=Ready`
# has nothing to match on and fails opaquely. Poll the condition instead and print
# whatever the controller actually said, which is where the useful error lives.
echo "Waiting for $ADCS_ISSUER_NAME to become ready..."
for _ in $(seq 1 30); do
    ready=$(oc get clusteradcsissuer "$ADCS_ISSUER_NAME" \
              -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" == "True" ]] && break
    sleep 4
done

oc get clusteradcsissuer "$ADCS_ISSUER_NAME" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || true
echo

if [[ "${ready:-}" != "True" ]]; then
    echo "Issuer is not ready. Controller logs:" >&2
    echo "  oc logs -n $ADCS_NAMESPACE deployment/adcs-issuer-controller-manager --tail=50" >&2
    exit 1
fi
echo "$ADCS_ISSUER_NAME is ready."
