# Shared configuration for every shell script in this repo.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"   # from a script
#   source lib/config.sh                                     # in your own shell
#
# Every value, derived ones included, comes from bootstrap.py --export, so the
# derivation rules have exactly one implementation. Sourcing this does not render
# templates; call render_templates for that.
#
# An environment variable set before sourcing wins over config.env, so a one-off
# override works:  AD_DC_HOST=dc02.example.internal ./some-script.sh

# shellcheck shell=bash

# BASH_SOURCE in bash; $0 when zsh sources a file. Falls back to git so this also
# works if a copy is sourced by a shell that provides neither.
_cfg_self="${BASH_SOURCE[0]:-$0}"
if [[ -n "$_cfg_self" && "$_cfg_self" != "-"* && -f "$_cfg_self" ]]; then
    REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "$_cfg_self")/.." && pwd)}"
else
    REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
fi
unset _cfg_self

if ! _cfg_exports="$(python3 "$REPO_ROOT/bootstrap.py" --export)"; then
    # bootstrap.py has already explained itself on stderr.
    return 1 2>/dev/null || exit 1
fi
eval "$_cfg_exports"
unset _cfg_exports

# The Proxmox API token secret deliberately does not live in config.env - it is
# a credential, and config.env is a file people paste around. create-pve-api-token.sh
# writes it to secrets/ (gitignored, mode 600) instead; source it here so
# deploy-adcs.sh needs no manual export. An already-set PVE_API_TOKEN wins, so a
# one-off override still works.
_cfg_token="$REPO_ROOT/secrets/pve-api-token.env"
if [[ -z "${PVE_API_TOKEN:-}" && -f "$_cfg_token" ]]; then
    . "$_cfg_token"
fi
unset _cfg_token

# Same idea for the cluster: scripts/okd/create-oc-token.sh writes a kubeconfig
# backed by a non-expiring ServiceAccount token, so nothing depends on an
# `oc login` session that times out. config.env's KUBECONFIG, or one already in
# the environment, still wins.
_cfg_kubeconfig="$REPO_ROOT/secrets/okd-kubeconfig"
if [[ -z "${KUBECONFIG:-}" && -f "$_cfg_kubeconfig" ]]; then
    export KUBECONFIG="$_cfg_kubeconfig"
fi
unset _cfg_kubeconfig

# render_templates [--list] [--quiet] - renders every *.tmpl into RENDER_DIR.
render_templates() {
    python3 "$REPO_ROOT/bootstrap.py" "$@"
}
