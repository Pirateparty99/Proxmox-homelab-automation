#!/bin/bash
#
# install-salt-minion.sh - install and configure salt-minion on a RHEL VM.
#
# Installs from the official Salt Project repo - the same flat, distro-agnostic
# RPM repo the master image is built from, so master and minion run the same
# release. Runs over ssh against SALT_MINION_HOST, or locally with --local if
# you are already on the VM.
#
# The minion is pointed at the master's NodePort, because 4505/4506 are raw TCP
# and cannot go through a Route. After it starts, its key must be accepted on
# the master before it can do anything.
#
# Usage:
#   scripts/helm/salt/install-salt-minion.sh                 # over ssh to SALT_MINION_HOST
#   scripts/helm/salt/install-salt-minion.sh --local         # on the VM itself
#   scripts/helm/salt/install-salt-minion.sh --accept        # accept its key on the master
#   scripts/helm/salt/install-salt-minion.sh --status
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${SALT_NAMESPACE:-salt}"
RELEASE="${SALT_RELEASE:-salt}"
SALT_VER="${SALT_VERSION:-3008.2}"
MASTER="${SALT_MASTER_ADDR:?set SALT_MASTER_ADDR in config.env}"
PUBLISH_PORT="${SALT_NODEPORT_PUBLISH:-30505}"
RET_PORT="${SALT_NODEPORT_RET:-30506}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Switch on the argument itself, not on a defaulted copy: defaulting first sent
# the no-argument case into *) where $1 is unbound, so the documented usage
# failed under `set -u` before doing anything.
MODE=remote
case "${1:-}" in
  "")       MODE=remote ;;
  --local)  MODE=local ;;
  --accept) MODE=accept ;;
  --status) MODE=status ;;
  *)        die "unknown argument: ${1}" ;;
esac

if [[ "$MODE" == accept || "$MODE" == status ]]; then
  command -v oc >/dev/null || die "oc not found in PATH"
  if [[ "$MODE" == accept ]]; then
    log "Accepting pending minion keys"
    # Deliberately not -A with auto-yes on everything unseen: look first.
    oc exec -n "$NAMESPACE" "${RELEASE}-0" -- salt-key -L 2>/dev/null | sed 's/^/    /'
    read -rp "    Accept all unaccepted keys? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "nothing accepted"; exit 0; }
    oc exec -n "$NAMESPACE" "${RELEASE}-0" -- salt-key -A -y 2>&1 | sed 's/^/    /'
  fi
  log "Keys on the master"
  oc exec -n "$NAMESPACE" "${RELEASE}-0" -- salt-key -L 2>/dev/null | sed 's/^/    /'
  log "Minions responding"
  oc exec -n "$NAMESPACE" "${RELEASE}-0" -- salt '*' test.ping --timeout=10 2>&1 | head -10 | sed 's/^/    /' || info "none yet"
  exit 0
fi

# The work done on the VM. Kept as one script so the local and ssh paths cannot
# drift apart.
MINION_SETUP=$(cat <<EOF
set -euo pipefail
if [ "\$(id -u)" -ne 0 ]; then echo "must run as root on the VM" >&2; exit 1; fi

# The Salt repo is flat - one baseurl for every distribution - because the
# packages are onedir builds carrying their own Python.
rpm --import https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public
cat > /etc/yum.repos.d/salt.repo <<'REPO'
[salt]
name=Salt Project
baseurl=https://packages.broadcom.com/artifactory/saltproject-rpm/
enabled=1
gpgcheck=1
gpgkey=https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public
REPO

dnf install -y "salt-minion-${SALT_VER}"

mkdir -p /etc/salt/minion.d
cat > /etc/salt/minion.d/master.conf <<'MINION'
master: ${MASTER}
master_port: ${PUBLISH_PORT}
# The return port is a separate NodePort, so it has to be named explicitly -
# the minion would otherwise assume master_port + 1.
ret_port: ${RET_PORT}
id: ${SALT_MINION_ID:-\$(hostname -f)}
MINION

# SELinux is enforcing on RHEL by default; salt-minion ships its own policy
# handling, so this only reports state rather than changing it.
command -v getenforce >/dev/null && echo "SELinux: \$(getenforce)"

systemctl enable --now salt-minion
sleep 3
systemctl is-active salt-minion && echo "salt-minion is running"
salt-call --local grains.get id 2>/dev/null | tail -2 || true
EOF
)

if [[ "$MODE" == local ]]; then
  log "Installing salt-minion ${SALT_VER} locally"
  info "master: ${MASTER}:${PUBLISH_PORT}"
  bash -c "$MINION_SETUP"
else
  HOST="${SALT_MINION_HOST:?set SALT_MINION_HOST in config.env, or use --local}"
  USER="${SALT_MINION_SSH_USER:-root}"
  log "Installing salt-minion ${SALT_VER} on ${HOST}"
  info "master: ${MASTER}:${PUBLISH_PORT}"

  # Key-based ssh only: this script never handles a password, and a fresh RHEL
  # install offers password auth alone. Checked up front so the failure names
  # the fix rather than surfacing as a bare "Permission denied" mid-install.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
       "${USER}@${HOST}" true 2>/dev/null; then
    die "cannot log in to ${USER}@${HOST} with a key.
    Authorize one - it will ask you for the account password, not this script:
      ssh-copy-id ${USER}@${HOST}
    Then re-run. Or run this on the VM itself with --local."
  fi

  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      "${USER}@${HOST}" "bash -s" <<< "$MINION_SETUP"
fi

log "Next"
info "The minion is running but its key is not accepted yet, so it can do"
info "nothing until you accept it:"
info "  scripts/helm/salt/install-salt-minion.sh --accept"
