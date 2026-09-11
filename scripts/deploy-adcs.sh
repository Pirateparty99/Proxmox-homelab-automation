#!/bin/bash
#
# deploy-adcs.sh - the whole AD CS deployment, end to end.
#
# Runs, in order:
#   1. scripts/ad/copy-to-ca-host.sh                      render + scp the bundle
#   2. Install-AdcsChain.ps1 on the CA host, over ssh      CA, gMSA, /certsrv
#   3. scripts/helm/.../deploy-cert-man.sh                 cert-manager + adcs-issuer
#   4. scripts/helm/.../configure-clusterissuer.sh         secret + ClusterAdcsIssuer
#
# Stops at the first failure. Like the scripts it calls, this assumes a
# from-scratch install - there is no resume, and re-running after a partial
# failure will fail. Roll back to the snapshot step 2 takes and start again.
#
# Prerequisites, none of which this script sets up:
#   - PVE_API_TOKEN exported (scripts/proxmox/create-pve-api-token.sh prints it)
#   - key-based ssh to the CA host (scripts/ad/authorize-ssh-key.sh)
#   - oc logged in to the cluster
#
# Step 4 prompts for the ADCS_ENROLL_USER password.
#
# Usage:
#   PVE_API_TOKEN=... scripts/deploy-adcs.sh
#   PVE_API_TOKEN=... scripts/deploy-adcs.sh --dry-run
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

SCRIPTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SSH_HOST="${ADCS_HOST:?set ADCS_HOST in config.env}"
SSH_USER="${ADCS_SSH_USER:?set ADCS_SSH_USER in config.env}"
REMOTE_DIR="adcs"          # where copy-to-ca-host.sh puts the bundle

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '\n\033[1m### %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ------------------------------------------------------------------- preflight
log "Preflight"
: "${PVE_API_TOKEN:?not set - the CA step needs it to snapshot the DC. Run scripts/proxmox/create-pve-api-token.sh}"
ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}@${SSH_HOST}" exit 2>/dev/null \
  || die "no key-based ssh to ${SSH_USER}@${SSH_HOST} - run scripts/ad/authorize-ssh-key.sh"
oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run 'oc login'"
printf '    ssh %s@%s, oc as %s\n' "$SSH_USER" "$SSH_HOST" "$(oc whoami)"

# ------------------------------------------------------------------ 1. bundle
log "1/4  Copying the bundle to $SSH_HOST"
run "'$SCRIPTS/ad/copy-to-ca-host.sh'$( ((DRY_RUN)) && echo ' --dry-run')"

# --------------------------------------------------------------- 2. the DC
log "2/4  Running Install-AdcsChain.ps1 on $SSH_HOST"
# The token is passed inside the remote command rather than through the
# environment: sshd only forwards variables it is configured to accept, and the
# chain cannot prompt for one over a non-interactive session. -EncodedCommand
# keeps it off the remote command line in plain text - it is still recoverable
# by anyone who can read that process list, so treat the token as exposed to
# administrators of the CA host, which it already is.
REMOTE_PS="\$env:PVE_API_TOKEN = '${PVE_API_TOKEN}'
Set-Location '${REMOTE_DIR}'
.\\Install-AdcsChain.ps1"
if (( DRY_RUN )); then
  printf '    [dry-run] ssh %s@%s powershell -EncodedCommand <chain, token redacted>\n' "$SSH_USER" "$SSH_HOST"
else
  ENCODED=$(printf '%s' "$REMOTE_PS" | python3 -c \
    "import sys,base64;sys.stdout.write(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
  ssh -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" \
      powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$ENCODED"
fi

# ------------------------------------------------------------- 3. cert-manager
log "3/4  Installing cert-manager and the ADCS issuer"
run "'$SCRIPTS/helm/certificate-manager/deploy-cert-man.sh'"

# ------------------------------------------------------------ 4. clusterissuer
log "4/4  Creating the credentials Secret and ClusterAdcsIssuer"
if (( DRY_RUN )); then
  printf '    [dry-run] %s   (prompts for the %s password)\n' \
    "$SCRIPTS/helm/certificate-manager/configure-clusterissuer.sh" "${ADCS_ENROLL_USER}"
else
  "$SCRIPTS/helm/certificate-manager/configure-clusterissuer.sh"
fi

log "Done"
