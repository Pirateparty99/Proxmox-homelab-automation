#!/bin/bash
#
# authorize-ssh-key.sh - install this machine's SSH public key on the CA host so
#                        copy-to-ca-host.sh runs without prompting.
#
# Windows OpenSSH does NOT read ~/.ssh/authorized_keys for accounts in the local
# Administrators group. Its shipped sshd_config ends with:
#
#     Match Group administrators
#         AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
# so admin keys go in one shared file, C:\ProgramData\ssh\administrators_authorized_keys,
# and that file is ignored unless its ACL grants only Administrators and SYSTEM.
# ssh-copy-id knows none of this: it writes ~/.ssh/authorized_keys, reports
# success, and changes nothing. This script picks the right file by checking the
# target account's group membership, and fixes the ACL.
#
# You are prompted for the account's password once, by ssh. It is never handled
# here, and never stored.
#
# NOTE: administrators_authorized_keys is shared by every administrator on the
# host. A key added here is domain-admin access - consider a dedicated key
# rather than your general-purpose one.
#
# Usage:
#   scripts/ad/authorize-ssh-key.sh
#   scripts/ad/authorize-ssh-key.sh --dry-run
#   scripts/ad/authorize-ssh-key.sh --key ~/.ssh/id_ed25519_ad.pub
#   scripts/ad/authorize-ssh-key.sh --user 'KANTO\svc-adcs' --host dc02.kanto.internal
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

SSH_HOST="${ADCS_HOST:?set ADCS_HOST in config.env}"
SSH_USER="${ADCS_SSH_USER:?set ADCS_SSH_USER in config.env}"
KEY_FILE="${ADCS_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --key)     KEY_FILE="${2:?--key needs a value}"; shift 2 ;;
    --user)    SSH_USER="${2:?--user needs a value}"; shift 2 ;;
    --host)    SSH_HOST="${2:?--host needs a value}"; shift 2 ;;
    *)         echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------- helpers
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- preflight
log "Preflight"
[[ -f "$KEY_FILE" ]] || die "no public key at $KEY_FILE - generate one with: ssh-keygen -t ed25519"
case "$KEY_FILE" in
  *.pub) ;;
  *) die "$KEY_FILE is not a .pub file - do not send a private key anywhere" ;;
esac

PUBKEY=$(tr -d '\r\n' < "$KEY_FILE")
grep -q '^ssh-' <<<"$PUBKEY" || die "$KEY_FILE does not look like an OpenSSH public key"
# The key is embedded in a single-quoted PowerShell string below.
[[ "$PUBKEY" != *"'"* ]] || die "public key contains a single quote; refusing to build the remote command"

info "key:   $KEY_FILE"
info "       $(ssh-keygen -lf "$KEY_FILE" | awk '{print $1, $2}')"
info "target: ${SSH_USER}@${SSH_HOST}"

timeout 5 bash -c "echo > /dev/tcp/${SSH_HOST}/22" 2>/dev/null \
  || die "nothing listening on ${SSH_HOST}:22 - is the OpenSSH server running?"

# ------------------------------------------------------------- remote programme
# Decides the file from the account's actual group membership rather than
# assuming, so this works for a non-admin service account too. Idempotent: an
# already-present key is left alone.
read -r -d '' REMOTE <<PSEOF || true
\$ErrorActionPreference = 'Stop'
\$key = '${PUBKEY}'

\$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (\$isAdmin) {
    \$file = Join-Path \$env:ProgramData 'ssh\administrators_authorized_keys'
} else {
    \$dir = Join-Path \$env:USERPROFILE '.ssh'
    if (-not (Test-Path \$dir)) { New-Item -ItemType Directory -Path \$dir | Out-Null }
    \$file = Join-Path \$dir 'authorized_keys'
}
Write-Output "file: \$file"
Write-Output "admin account: \$isAdmin"

if (-not (Test-Path \$file)) { New-Item -ItemType File -Path \$file | Out-Null }

\$existing = @(Get-Content -Path \$file -ErrorAction SilentlyContinue)
if (\$existing -contains \$key) {
    Write-Output 'result: key already present, nothing to do'
} else {
    Add-Content -Path \$file -Value \$key
    Write-Output 'result: key added'
}

if (\$isAdmin) {
    # sshd refuses the file outright if anyone else can write it.
    icacls \$file /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    Write-Output 'acl: reset to Administrators + SYSTEM'
}
PSEOF

if (( DRY_RUN )); then
  log "Dry run - would run this on ${SSH_HOST}, as ${SSH_USER}"
  printf '%s\n' "$REMOTE" | sed 's/^/    /'
  exit 0
fi

# -EncodedCommand takes UTF-16LE base64, which sidesteps quoting through
# bash -> ssh -> cmd.exe -> powershell entirely.
ENCODED=$(printf '%s' "$REMOTE" | python3 -c \
  "import sys, base64; sys.stdout.write(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")

log "Authorising (ssh will ask for the ${SSH_USER} password)"
ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" \
    powershell -NoProfile -EncodedCommand "$ENCODED" | sed 's/^/    /'

# ---------------------------------------------------------------------- verify
log "Verifying key authentication"
if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}@${SSH_HOST}" hostname >/dev/null 2>&1; then
  info "OK - $(timeout 15 ssh -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" hostname 2>/dev/null)"
  info "scripts/ad/copy-to-ca-host.sh will now run without prompting."
else
  die "key authentication still fails.
    Check on ${SSH_HOST}:
      Get-Content C:\\ProgramData\\ssh\\administrators_authorized_keys
      icacls C:\\ProgramData\\ssh\\administrators_authorized_keys
      Get-Service sshd
    sshd logs the reason: Get-EventLog -LogName Application -Source sshd -Newest 20"
fi
