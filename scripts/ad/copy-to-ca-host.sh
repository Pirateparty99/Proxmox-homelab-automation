#!/bin/bash
#
# copy-to-ca-host.sh - render, then copy the AD CS bundle to the CA host.
#
# bootstrap.py stages scripts/ad/*.ps1 next to the generated adcs.env, so
# rendered/ad is self-contained: one directory holding everything the CA host
# needs. This renders it fresh and copies it across with scp.
#
# Windows OpenSSH is listening on the CA host; if that ever stops being true,
# --zip produces rendered/ad.zip to move across by whatever means you have
# (RDP drive redirection, a share, a mounted ISO).
#
# The scripts still have to be run on the CA host, elevated - this only copies.
#
# Usage:
#   scripts/ad/copy-to-ca-host.sh                  # render + scp
#   scripts/ad/copy-to-ca-host.sh --dry-run
#   scripts/ad/copy-to-ca-host.sh --zip            # make a zip, copy nothing
#   scripts/ad/copy-to-ca-host.sh --user 'KANTO\svc-adcs' --dest 'C:/adcs'
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

SSH_HOST="${ADCS_HOST:?set ADCS_HOST in config.env}"
SSH_USER="${ADCS_SSH_USER:?set ADCS_SSH_USER in config.env}"
# Relative, so it lands in the SSH user's profile directory. Pass an absolute
# Windows path (forward slashes) to put it elsewhere.
DEST="adcs"

DRY_RUN=0
ZIP_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --zip)     ZIP_ONLY=1; shift ;;
    --user)    SSH_USER="${2:?--user needs a value}"; shift 2 ;;
    --host)    SSH_HOST="${2:?--host needs a value}"; shift 2 ;;
    --dest)    DEST="${2:?--dest needs a value}"; shift 2 ;;
    *)         echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------- helpers
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

BUNDLE="$RENDER_DIR/ad"

# ------------------------------------------------------------------- the bundle
log "Building the bundle"
render_templates --quiet
[[ -d "$BUNDLE" ]] || die "$BUNDLE does not exist - did ./bootstrap.py run?"

# The env file is generated and the .ps1 are staged; if either half is missing
# the copy would look like it worked and then fail on the CA host.
[[ -f "$BUNDLE/adcs.env" ]]          || die "$BUNDLE/adcs.env is missing"
[[ -f "$BUNDLE/Get-AdcsConfig.ps1" ]] || die "$BUNDLE/Get-AdcsConfig.ps1 is missing - check STAGED_FILES in bootstrap.py"
count=$(find "$BUNDLE" -maxdepth 1 -name '*.ps1' | wc -l)
(( count >= 2 )) || die "only $count .ps1 in $BUNDLE - staging did not run"
info "$BUNDLE: adcs.env + $count .ps1"

# adcs.env carries hostnames and a token id. Not secrets, but not for sharing.
info "adcs.env holds site values - it is gitignored, keep it that way"

if (( ZIP_ONLY )); then
  log "Zipping"
  ZIP="$RENDER_DIR/ad.zip"
  run "rm -f '$ZIP'"
  # python3 is already a hard dependency (bootstrap.py), unlike zip(1).
  run "cd '$RENDER_DIR' && python3 -m zipfile -c '$ZIP' ad/"
  (( DRY_RUN )) || info "wrote $ZIP"
  info "Copy it across, unpack it, and run Install-AdcsChain.ps1 from inside."
  exit 0
fi

# --------------------------------------------------------------------- transfer
log "Copying to $SSH_USER@$SSH_HOST:$DEST"
timeout 5 bash -c "echo > /dev/tcp/${SSH_HOST}/22" 2>/dev/null \
  || die "nothing listening on ${SSH_HOST}:22 - install the OpenSSH server on the CA host, or use --zip"

# Copy the bundle's CONTENTS, not the directory. `scp -r <dir> host:<dest>`
# puts <dir> INSIDE <dest> when <dest> already exists, so repeat runs nest at
# <dest>/ad/ and the CA host keeps running the first copy. Deleting <dest>
# first is not a reliable way round that: Windows will not remove a directory
# that is some process's working directory, so a shell sitting in it makes the
# delete fail and the next copy nest anyway.
#
# Copying file-by-file into <dest> cannot nest, and overwrites in place.
[[ -n "$DEST" ]] || die "DEST is empty"
# No pipe or semicolon in the remote command: the CA host's default ssh shell is
# cmd.exe, which consumes them before powershell ever sees them. Output is
# discarded locally instead.
run "ssh -o BatchMode=yes '${SSH_USER}@${SSH_HOST}' powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '${DEST}'\" >/dev/null"
run "scp '$BUNDLE'/* '${SSH_USER}@${SSH_HOST}:${DEST}/'"

log "Next"
cat <<EOF
    On $SSH_HOST, in an elevated PowerShell:

      cd $DEST
      \$env:PVE_API_TOKEN = '<secret from create-pve-api-token.sh>'
      .\\Install-AdcsChain.ps1
EOF
