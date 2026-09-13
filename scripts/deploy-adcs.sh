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
#   - PVE_API_TOKEN available (scripts/proxmox/create-pve-api-token.sh writes it to
#     secrets/pve-api-token.env, which lib/config.sh sources automatically)
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

echo "Create a API token to authenticate to Proxmox to create a snapshot of the DC:"
run "'$SCRIPTS/proxmox/create-pve-api-token.sh'"

# lib/config.sh sourced secrets/pve-api-token.env at the top of this script,
# which is before the line above had a chance to write it. Pick it up now, or
# step 2 would send an empty token to the CA host.
if [[ -z "${PVE_API_TOKEN:-}" && -f "$REPO_ROOT/secrets/pve-api-token.env" ]]; then
    . "$REPO_ROOT/secrets/pve-api-token.env"
fi
(( DRY_RUN )) || : "${PVE_API_TOKEN:?still unset - create-pve-api-token.sh did not write secrets/pve-api-token.env. If the token already existed, its secret cannot be read back: re-run that script with --recreate}"

# Check it actually authenticates before sending it to the CA host. Without
# this the first sign of a bad token is a 401 from inside the snapshot call on
# the DC, several screens into step 2.
#
# The likeliest cause of a stale one is an old `export PVE_API_TOKEN=...` still
# live in this shell: lib/config.sh only reads secrets/pve-api-token.env when
# the variable is unset, so an exported value wins - including one that
# --recreate has since invalidated.
_token_http() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: PVEAPIToken=${PVE_API_TOKEN_ID}=${1}" \
    "https://${PVE_API_HOST}:8006/api2/json/version" 2>/dev/null || echo 000
}

if (( ! DRY_RUN )); then
  _code=$(_token_http "$PVE_API_TOKEN")
  if [[ "$_code" != "200" ]]; then
    # An exported PVE_API_TOKEN beats the file by design, for one-off overrides.
    # An override the API rejects is not worth honouring, though - and a stale
    # export left over from before a --recreate is the usual reason we get here.
    # Prefer the file if it holds something that actually works.
    _file_token=$( . "$REPO_ROOT/secrets/pve-api-token.env" >/dev/null 2>&1; printf '%s' "${PVE_API_TOKEN:-}" )
    if [[ -n "$_file_token" && "$_file_token" != "$PVE_API_TOKEN" && "$(_token_http "$_file_token")" == "200" ]]; then
      export PVE_API_TOKEN="$_file_token"
      printf '    the exported PVE_API_TOKEN was rejected (HTTP %s); using secrets/pve-api-token.env instead\n' "$_code"
      printf '    run `unset PVE_API_TOKEN` to stop the stale one shadowing it\n'
    else
      die "the Proxmox API rejected PVE_API_TOKEN (HTTP $_code), and secrets/pve-api-token.env has nothing better.
    Re-issue it:  scripts/proxmox/create-pve-api-token.sh --recreate"
    fi
    unset _file_token
  else
    printf '    proxmox token OK\n'
  fi
  unset _code
fi

echo "Testing ssh to DC01:"
ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}@${SSH_HOST}" exit 2>/dev/null \
  || die "no key-based ssh to ${SSH_USER}@${SSH_HOST} - run scripts/ad/authorize-ssh-key.sh"

echo "Testing Openshift Client tool's auth:"
if ! oc whoami >/dev/null 2>&1; then
  # `oc login` hands out a token that expires, so rather than telling you to run
  # it again, mint a credential that does not. This prompts for the
  # OKD_LOGIN_USER password.
  run "'$SCRIPTS/okd/create-oc-token.sh'"

  # Same ordering problem as the Proxmox token above: lib/config.sh looked for
  # the kubeconfig before the line above had a chance to write it.
  if [[ -z "${KUBECONFIG:-}" && -f "$REPO_ROOT/secrets/okd-kubeconfig" ]]; then
      export KUBECONFIG="$REPO_ROOT/secrets/okd-kubeconfig"
  fi
fi
(( DRY_RUN )) || oc whoami >/dev/null 2>&1 \
  || die "oc is still not authenticated after scripts/okd/create-oc-token.sh"
(( DRY_RUN )) || printf '    ssh %s@%s, oc as %s\n' "$SSH_USER" "$SSH_HOST" "$(oc whoami)"

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
# powershell.exe serialises its warning/error/information streams as CLIXML on
# stderr when it is not attached to a host, which is unreadable over ssh.
# Merging every stream into the success stream and stringifying it gives plain
# text on stdout; the try/catch keeps a failure a non-zero exit rather than
# something swallowed by the merge.
REMOTE_PS="\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$env:PVE_API_TOKEN = '${PVE_API_TOKEN}'
Set-Location '${REMOTE_DIR}'
try { .\\Install-AdcsChain.ps1 *>&1 | ForEach-Object { \"\$_\" } }
catch { Write-Output ('ERROR: ' + \$_.Exception.Message); exit 1 }"
if (( DRY_RUN )); then
  printf '    [dry-run] ssh %s@%s powershell -EncodedCommand <chain, token redacted>\n' "$SSH_USER" "$SSH_HOST"
else
  ENCODED=$(printf '%s' "$REMOTE_PS" | python3 -c \
    "import sys,base64;sys.stdout.write(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
  # -tt forces a pseudo-terminal. The chain prompts - New-AdcsEnrollmentAccount.ps1
  # asks for the new account's password - and Read-Host with no tty blocks
  # forever rather than failing, which looks exactly like a hang. Forcing one
  # (rather than -t, which silently gives up when stdin is not a terminal) means
  # the prompt reaches you when run from a terminal, and returns EOF and fails
  # promptly when it is not.
  #
  # The password is typed straight into the remote prompt: it is not read here,
  # not put in the encoded command, and not stored.
  ssh -tt -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" \
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
