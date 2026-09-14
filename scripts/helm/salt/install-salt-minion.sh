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

# Salt defaults the minion id to the host's FQDN, which is what we want unless
# SALT_MINION_ID says otherwise. Built here rather than in the heredoc below:
# that heredoc is quoted so the VM writes it verbatim, and a $(hostname -f) in
# it would land in the config file as literal text rather than a hostname.
ID_LINE=""
[[ -n "${SALT_MINION_ID:-}" ]] && ID_LINE="id: ${SALT_MINION_ID}"

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
# Salt's minion-side port names are the opposite way round to what they look
# like. master_port is the master's RET port - the one authentication and
# returns go to (4506 in the pod). publish_port is the publish channel (4505).
# ret_port is a master-side setting and is ignored here entirely, so setting it
# does nothing: the minion sends its auth to master_port and waits, which shows
# up as "Attempt to authenticate with the salt master failed with timeout".
master_port: ${RET_PORT}
publish_port: ${PUBLISH_PORT}
${ID_LINE}
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
  if [[ "$(id -u)" -eq 0 ]]; then
    bash -c "$MINION_SETUP"
  else
    info "not root - running the install under sudo"
    printf '%s' "$MINION_SETUP" | sudo bash -s
  fi
else
  HOST="${SALT_MINION_HOST:?set SALT_MINION_HOST in config.env, or use --local}"
  USER="${SALT_MINION_SSH_USER:-root}"
  SSH_KEY="${SALT_MINION_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
  # IdentitiesOnly: without it ssh offers every key the agent holds and the
  # server may reject on algorithm before ever reaching the one installed here.
  SSH_ID="${SSH_KEY%.pub}"
  ssh_ok() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
                 -o IdentitiesOnly=yes -i "$SSH_ID" \
                 "${USER}@${HOST}" true 2>/dev/null; }
  log "Installing salt-minion ${SALT_VER} on ${HOST}"
  info "master: ${MASTER}:${PUBLISH_PORT}"

  # A fresh RHEL install offers password auth only, and the rest of this script
  # needs key-based ssh. If there is no key yet, install one - ssh-copy-id asks
  # you for the account password itself. It is never handled here, and never
  # stored.
  if ! ssh_ok; then
    log "Authorizing an SSH key on ${HOST}"
    command -v ssh-copy-id >/dev/null || die "ssh-copy-id not found in PATH"
    [[ -f "$SSH_KEY" ]] || die "no public key at ${SSH_KEY}
    Generate one first:  ssh-keygen -t ed25519
    Or point SALT_MINION_SSH_KEY at an existing .pub file."
    info "key: ${SSH_KEY}"
    info "ssh will prompt you for ${USER}'s password"
    # Not ssh-copy-id: on RHEL it installs the key and still leaves you locked
    # out. Anything a shell creates under a home directory is labelled
    # user_home_t, and sshd will not read authorized_keys unless it is
    # ssh_home_t - so the file is plainly there and plainly ignored.
    # ssh-copy-id cannot relabel, so the same authenticated session does the
    # whole job: append the key, fix the modes, restore the SELinux context.
    ssh -o StrictHostKeyChecking=no "${USER}@${HOST}" '
      set -e
      umask 077
      mkdir -p ~/.ssh
      cat >> ~/.ssh/authorized_keys
      # Duplicates accumulate across retries and sshd stops at the first match,
      # so they are harmless - but tidy them up anyway.
      sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
      chmod 700 ~/.ssh
      chmod 600 ~/.ssh/authorized_keys
      chmod go-w ~
      command -v restorecon >/dev/null && restorecon -R ~/.ssh || true
    ' < "$SSH_KEY" || die "could not install the key - check the account and password"
    ssh_ok || die "the key was installed and key-based login still fails.
    sshd logs the reason - on the VM:

      sudo journalctl -u sshd -n 30 --no-pager

    If it says 'signature algorithm ... not in PubkeyAcceptedAlgorithms', the
    key type is the problem rather than the key: RHEL 10's crypto policy
    excludes ssh-ed25519. Point SALT_MINION_SSH_KEY at an RSA key
    (ssh-keygen -t rsa -b 4096) instead of changing the policy."
    info "key authorized"
  fi

  # Installing packages and writing /etc/salt needs root, and we log in as an
  # ordinary user. The script is staged first and then run under sudo with a
  # TTY, so sudo can prompt for the password itself - this script never handles
  # it. A passwordless sudo rule simply means no prompt appears.
  REMOTE_TMP="/tmp/salt-minion-setup.$$.sh"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes -i "$SSH_ID" \
      "${USER}@${HOST}" "cat > ${REMOTE_TMP} && chmod 700 ${REMOTE_TMP}" <<< "$MINION_SETUP" \
    || die "could not stage the installer on ${HOST}"

  info "running the install under sudo on ${HOST}"
  ssh -t -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes -i "$SSH_ID" \
      "${USER}@${HOST}" "sudo bash ${REMOTE_TMP}; rc=\$?; rm -f ${REMOTE_TMP}; exit \$rc" \
    || die "the install failed on ${HOST}
    If sudo refused, add ${USER} to the wheel group on the VM:
      usermod -aG wheel ${USER}"
fi

log "Next"
info "The minion is running but its key is not accepted yet, so it can do"
info "nothing until you accept it:"
info "  scripts/helm/salt/install-salt-minion.sh --accept"
