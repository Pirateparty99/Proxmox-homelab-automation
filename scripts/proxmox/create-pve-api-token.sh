#!/bin/bash
#
# create-pve-api-token.sh - create the Proxmox API token the PowerShell AD CS
#                           scripts use to snapshot the DC before they change it.
#
# Grants the token a purpose-built role ("SnapshotOnly") on ONE VM rather than
# root's privileges:
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
# Proxmox reserves the "PVE" prefix (case-insensitive) for its built-in roles
# and rejects any custom role ID starting with it:
#   400 Parameter verification failed.
#   roleid: cannot use role ID starting with the (case-insensitive) 'PVE' namespace
PVE_TOKEN_ROLE="${PVE_TOKEN_ROLE:-SnapshotOnly}"

# Where the secret lands. secrets/ is gitignored and already holds ad-ca.crt.
TOKEN_ENV_FILE="${TOKEN_ENV_FILE:-$REPO_ROOT/secrets/pve-api-token.env}"

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
  # Proxmox shows the secret only at creation, so an existing token is only
  # usable if that secret was captured at the time. Silently recreating it would
  # invalidate one that may already be deployed, so that stays opt-in - but a
  # token with no local secret is a dead end, and saying "already exists" would
  # let the caller get two steps further before finding out.
  if [[ -f "$TOKEN_ENV_FILE" ]]; then
    info "already exists, and its secret is in $TOKEN_ENV_FILE - nothing to do"
  elif (( DRY_RUN )); then
    info "already exists, but $TOKEN_ENV_FILE is missing - a real run would stop here"
  else
    die "token '$PVE_API_TOKEN_ID' exists on Proxmox, but $TOKEN_ENV_FILE does not.
    Proxmox shows a token secret once, at creation, and cannot show it again, so
    this token cannot be used from here.

    Re-issue it:   $0 --recreate

    That invalidates the current secret. Safe unless you have already deployed
    it somewhere - if you still have it, write it there by hand instead:
        install -m 600 /dev/null '$TOKEN_ENV_FILE'
        printf 'export PVE_API_TOKEN=%s\\n' '<secret>' >> '$TOKEN_ENV_FILE'"
  fi
elif (( TOKEN_EXISTS && RECREATE )); then
  log "Recreating token - the previous secret stops working now"
  run "pveum user token remove '$TOKEN_USER' '$TOKEN_NAME'"
  TOKEN_EXISTS=0
fi

if (( ! TOKEN_EXISTS )); then
  if (( DRY_RUN )); then
    info "[dry-run] pveum user token add $TOKEN_USER $TOKEN_NAME --privsep 1"
    info "[dry-run] would write the secret to $TOKEN_ENV_FILE"
  else
    # --privsep 1 (the default) means the token carries only the privileges
    # granted to it below, NOT everything $TOKEN_USER can do. With --privsep 0
    # this token would be a full root credential sitting on a Windows host.
    #
    # JSON rather than the default table: the secret is shown exactly once, so
    # it has to be captured here rather than read off the terminal. It is
    # deliberately not echoed - it goes straight to the file.
    TOKEN_JSON=$(pve_cmd "pveum user token add '$TOKEN_USER' '$TOKEN_NAME' --privsep 1 --comment 'AD CS scripts: snapshot VM $PVE_DC_VMID' --output-format json")

    mkdir -p "$(dirname "$TOKEN_ENV_FILE")"
    # Create it empty and locked down BEFORE writing, so the secret is never
    # briefly world-readable.
    install -m 600 /dev/null "$TOKEN_ENV_FILE"
    printf '%s' "$TOKEN_JSON" | python3 -c '
import json, sys
path, token_id = sys.argv[1], sys.argv[2]
value = json.load(sys.stdin).get("value")
if not value:
    sys.exit("no \047value\047 in the pveum response - the token was created but the secret could not be captured")
with open(path, "w") as fh:
    fh.write("# Written by create-pve-api-token.sh. Gitignored; keep it that way.\n")
    fh.write("# Sourced automatically by lib/config.sh.\n")
    fh.write("export PVE_API_TOKEN_ID=%s\n" % json.dumps(token_id))
    fh.write("export PVE_API_TOKEN=%s\n" % json.dumps(value))
' "$TOKEN_ENV_FILE" "$PVE_API_TOKEN_ID"
    info "secret written to $TOKEN_ENV_FILE (mode 600, not echoed)"
    info "lib/config.sh sources it, so scripts/deploy-adcs.sh picks it up"
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
    The secret is in $TOKEN_ENV_FILE and lib/config.sh sources it, so
    nothing needs exporting. Just run:

      scripts/deploy-adcs.sh --dry-run      # then without --dry-run

    Do NOT export PVE_API_TOKEN by hand: an exported value beats the file, so
    one left over from a previous token survives a --recreate and everything
    then fails with 401.

    Running on the CA host by hand instead? Set \$env:PVE_API_TOKEN there and
    Install-AdcsChain.ps1 picks it up.
EOF
