#!/bin/bash
#
# create-salt-minion-vm.sh - create the Proxmox VM that will run the Salt minion.
#
# Creates the VM and attaches the RHEL install ISO. It does not install RHEL:
# the available media is a boot/netinstall ISO, so the installer fetches packages
# from Red Hat's CDN and needs your subscription. That step is interactive, at
# the console.
#
# Once RHEL is installed and reachable over ssh, install the minion with
# scripts/helm/salt/install-salt-minion.sh.
#
# Usage:
#   scripts/proxmox/create-salt-minion-vm.sh
#   scripts/proxmox/create-salt-minion-vm.sh --dry-run
#   scripts/proxmox/create-salt-minion-vm.sh --status
#   scripts/proxmox/create-salt-minion-vm.sh --destroy    # asks first
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

VMID="${SALT_MINION_VMID:?set SALT_MINION_VMID in config.env}"
NAME="${SALT_MINION_VM_NAME:-salt-minion}"
NODE="${SALT_MINION_VM_NODE:-pve1}"
CORES="${SALT_MINION_VM_CORES:-2}"
MEMORY="${SALT_MINION_VM_MEMORY:-2048}"
DISK="${SALT_MINION_VM_DISK:-20}"
STORAGE="${SALT_MINION_VM_STORAGE:-local-lvm}"
BRIDGE="${SALT_MINION_VM_BRIDGE:-vmbr0}"
ISO="${SALT_MINION_VM_ISO:?set SALT_MINION_VM_ISO in config.env}"
BIOS="${SALT_MINION_VM_BIOS:-seabios}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
pve()  { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE_SSH" "$@"; }
vm_node() {
    pve "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
      | python3 -c "
import json,sys
print(next((r['node'] for r in json.load(sys.stdin) if r.get('vmid') == $VMID), ''))
" 2>/dev/null
}

MODE=create
case "${1:-}" in
  --dry-run) MODE=dryrun ;;
  --status)  MODE=status ;;
  --destroy) MODE=destroy ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

pve true 2>/dev/null || die "cannot ssh to Proxmox at $PVE_SSH"

if [[ "$MODE" == status ]]; then
  log "VM ${VMID}"
  NODE_OF=$(vm_node)
  [[ -n "$NODE_OF" ]] || { info "VM $VMID does not exist anywhere in the cluster"; exit 0; }
  info "on node $NODE_OF"
  pve "pvesh get /nodes/$NODE_OF/qemu/$VMID/config --output-format json" 2>/dev/null \
    | python3 -c "
import json,sys
c=json.load(sys.stdin)
for k in sorted(c):
    if k in ('name','cores','memory','scsi0','ide2','net0','boot','ostype','agent','onboot'):
        print('    %-8s %s' % (k, c[k]))
" 2>/dev/null
  exit 0
fi

if [[ "$MODE" == destroy ]]; then
  log "Destroying VM ${VMID}"
  info "this deletes the VM and its disk"
  read -rp "    Type the VM id to confirm: " ans
  [[ "$ans" == "$VMID" ]] || { info "not confirmed; nothing done"; exit 0; }
  pve "qm stop $VMID 2>/dev/null; sleep 2; qm destroy $VMID --purge" 2>&1 | sed 's/^/    /'
  exit 0
fi

log "Preflight"
# VM ids are cluster-wide, so asking one node's qm is not enough - it answers
# "does not exist" for a VM living on another node, and the create then fails
# after the preflight has already passed.
EXISTING=$(vm_node)
if [[ -n "$EXISTING" ]]; then
  info "VM $VMID already exists on node $EXISTING"
  info "nothing to create - use --status to inspect it, or --destroy to remove it"
  exit 0
fi
info "vmid $VMID is free"
pve "pvesm list ${ISO%%:*} 2>/dev/null | grep -q '${ISO#*:}'" \
  || die "ISO not found on this Proxmox: $ISO"
info "iso:     $ISO"
info "node:    $NODE"
info "storage: $STORAGE (${DISK}G)"
info "spec:    ${CORES} cores, ${MEMORY}MB, bridge ${BRIDGE}"

# virtio-scsi-single and virtio-net rather than the lsi/vmxnet3 on the imported
# VMs here - those are VMware leftovers, and virtio is faster under KVM.
# The CD must come first: with an empty disk ahead of it the firmware finds no
# boot entry there and, under OVMF especially, stops at a prompt rather than
# falling through to it.
CREATE_ARGS="--name $NAME --cores $CORES --memory $MEMORY --ostype l26 \
--machine q35 --bios ${BIOS} \
--scsihw virtio-scsi-single --scsi0 ${STORAGE}:${DISK} \
--ide2 ${ISO},media=cdrom \
--net0 virtio,bridge=${BRIDGE} \
--boot 'order=ide2;scsi0;net0' \
--agent enabled=1 \
--onboot 1"
# OVMF keeps boot entries in an EFI disk; without one it cannot persist them.
[[ "$BIOS" == "ovmf" ]] && CREATE_ARGS="$CREATE_ARGS --efidisk0 ${STORAGE}:1,efitype=4m"

if [[ "$MODE" == dryrun ]]; then
  log "Would run"
  info "qm create $VMID $CREATE_ARGS"
  exit 0
fi

log "Creating VM ${VMID} on ${NODE}"
# qm is node-local, so this runs on the target node rather than on whichever
# node PVE_SSH happens to point at - otherwise the VM lands in the wrong place.
pve "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${NODE} \"qm create $VMID $CREATE_ARGS\"" 2>&1 | sed 's/^/    /'
info "created"

log "Starting it"
pve "pvesh create /nodes/${NODE}/qemu/${VMID}/status/start" 2>&1 | sed 's/^/    /'
pve "pvesh get /nodes/${NODE}/qemu/${VMID}/status/current" 2>&1 | sed 's/^/    /'

log "Next: install RHEL at the console"
cat <<EOF

    The boot ISO installs over the network, so the installer will ask for your
    Red Hat subscription - that part cannot be scripted from here.

    Console:  https://${PVE_API_HOST:-<proxmox>}:8006  ->  VM ${VMID}  ->  Console

    During the install, to match what the minion scripts expect:
      - create user '${SALT_MINION_USER:-admin}' with the password from config.env
      - enable that user for administration (wheel)
      - enable the ssh server
      - note the IP it gets, and put it in SALT_MINION_HOST in config.env

    Then:
      scripts/helm/salt/install-salt-minion.sh
      scripts/helm/salt/install-salt-minion.sh --accept
EOF
