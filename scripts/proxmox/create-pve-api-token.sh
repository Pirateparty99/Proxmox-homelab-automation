#!/bin/bash
#
# create-pve-api-token.sh - create the Proxmox API token the PowerShell AD CS
#                           scripts use to snapshot the DC before they change it.
#
# Grants the token a purpose-built role on ONE VM rather than root's privileges:
#
#   VM.Audit      read the VM's config and the status of its own tasks
#   VM.Snapshot   create (and delete) snapshots
#
# VM.Snapshot.Rollback is deliberately NOT granted. Install-AdcsCertificationAuthority.ps1
# only ever takes a snapshot; rolling a domain controller back is a decision for a
# human at the Proxmox console, not something a script's credentials should permit.
#
# The token secret is shown ONCE, by Proxmox, at creation. It is never written to
# the repo - export it as PVE_API_TOKEN on the Windows host, or let the script prompt.
#
# Prerequisites:
#   - key-based ssh to PVE_API_HOST as a user that can run pveum (root)
#
# Usage:
#   proxmox/setup/scripts/create-pve-api-token.sh
#   proxmox/setup/scripts/create-pve-api-token.sh --dry-run
#   proxmox/setup/scripts/create-pve-api-token.sh --recreate   # invalidates the old secret
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

PVE_SSH="${PVE_SSH:?set PVE_API_HOST in config.env}"
PVE_DC_VMID="${PVE_DC_VMID:?set PVE_DC_VMID in config.env}"
PVE_API_TOKEN_ID="${PVE_API_TOKEN_ID:?set PVE_API_TOKEN_ID in config.env}"
PVE_TOKEN_ROLE="${PVE_TOKEN_ROLE:-PVESnapshotOnly}"

DRY_RUN=0
RECREATE=0
for arg in "${@:-}"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --recreate) RECREATE=1 ;;
    "")         ;;
    *)          echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------- helpers
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
pve_cmd() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE_SSH" "$@"; }
# has_row <remote command emitting a JSON array> <python predicate over row `r`>
has_row() {
  pve_cmd "$1" 2>/dev/null | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any($2 for r in rows) else 1)
"
}
run() { if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else pve_cmd "$*"; fi; }

# PVE_API_TOKEN_ID is "<user>@<realm>!<tokenname>" - pveum wants the two halves
# as separate arguments.
TOKEN_USER="${PVE_API_TOKEN_ID%%!*}"
TOKEN_NAME="${PVE_API_TOKEN_ID##*!}"
[[ "$TOKEN_USER" != "$PVE_API_TOKEN_ID" ]] \
  || die "PVE_API_TOKEN_ID must look like user@realm!tokenname (got: $PVE_API_TOKEN_ID)"

# ------------------------------------------------------------------- preflight
log "Preflight"
command -v ssh >/dev/null || die "ssh not found in PATH"
pve_cmd "pveum role list --output-format json" >/dev/null 2>&1 \
  || die "cannot run 'pveum' via ssh on $PVE_SSH"
info "proxmox:   $PVE_SSH"
info "token:     $PVE_API_TOKEN_ID"
info "vm:        $PVE_DC_VMID ($PVE_NODE)"

pve_cmd "qm config $PVE_DC_VMID" >/dev/null 2>&1 \
  || die "VM $PVE_DC_VMID not found on $PVE_SSH - is PVE_DC_VMID/PVE_NODE right?"
info "vm name:   $(pve_cmd "qm config $PVE_DC_VMID" | sed -n 's/^name: //p')"

# ------------------------------------------------------------------------ role
log "Role '$PVE_TOKEN_ROLE'"
if has_row "pveum role list --output-format json" "r.get('roleid') == '$PVE_TOKEN_ROLE'"; then
  info "already exists - leaving as is"
else
  run "pveum role add $PVE_TOKEN_ROLE --privs 'VM.Audit VM.Snapshot'"
  info "created with VM.Audit, VM.Snapshot (no rollback)"
fi

# ----------------------------------------------------------------------- token
log "Token '$PVE_API_TOKEN_ID'"
TOKEN_EXISTS=0
if has_row "pveum user token list '$TOKEN_USER' --output-format json" \
           "r.get('tokenid') == '$TOKEN_NAME'"; then
  TOKEN_EXISTS=1
fi

if (( TOKEN_EXISTS && ! RECREATE )); then
  # Proxmox shows the secret only at creation, so there is nothing useful to do
  # with an existing token here - and silently recreating it would invalidate a
  # secret that may already be deployed.
  info "already exists - not touching it"
  info "the secret cannot be read back; re-run with --recreate to issue a new one"
  info "(that immediately invalidates the current secret)"
elif (( TOKEN_EXISTS && RECREATE )); then
  log "Recreating token - the previous secret stops working now"
  run "pveum user token remove '$TOKEN_USER' '$TOKEN_NAME'"
  TOKEN_EXISTS=0
fi

if (( ! TOKEN_EXISTS )); then
  if (( DRY_RUN )); then
    info "[dry-run] pveum user token add $TOKEN_USER $TOKEN_NAME --privsep 1"
  else
    log "Token secret - copy it now, it is not recoverable"
    # --privsep 1 (the default) means the token carries only the privileges
    # granted to it below, NOT everything $TOKEN_USER can do. With --privsep 0
    # this token would be a full root credential sitting on a Windows host.
    pve_cmd "pveum user token add '$TOKEN_USER' '$TOKEN_NAME' --privsep 1 --comment 'AD CS scripts: snapshot VM $PVE_DC_VMID'"
  fi
fi

# ------------------------------------------------------------------------- acl
log "Permissions on /vms/$PVE_DC_VMID"
if has_row "pveum acl list --output-format json" \
           "r.get('path') == '/vms/$PVE_DC_VMID' and r.get('ugid') == '$PVE_API_TOKEN_ID'"; then
  info "already granted"
else
  run "pveum acl modify /vms/$PVE_DC_VMID --tokens '$PVE_API_TOKEN_ID' --roles $PVE_TOKEN_ROLE"
  info "granted $PVE_TOKEN_ROLE to $PVE_API_TOKEN_ID"
fi

pve_cmd "pveum acl list --output-format json" | python3 -c '
import json, sys
rows = [a for a in json.load(sys.stdin) if a.get("ugid") == "'"$PVE_API_TOKEN_ID"'"]
for r in rows:
    print("    %-18s %-18s %s" % (r.get("path"), r.get("roleid"), r.get("type")))
' 2>/dev/null || true

# ------------------------------------------------------------------------ next
log "Next"
cat <<EOF
    On the CA host, before running Install-AdcsCertificationAuthority.ps1:

      \$env:PVE_API_TOKEN = '<secret printed above>'

    Or omit it and let the script prompt. Verify without changing anything:

      .\\Install-AdcsCertificationAuthority.ps1 -WhatIf
EOF
