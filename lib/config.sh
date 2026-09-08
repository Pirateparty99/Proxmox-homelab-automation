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

# render_templates [--list] [--quiet] - renders every *.tmpl into RENDER_DIR.
render_templates() {
    python3 "$REPO_ROOT/bootstrap.py" "$@"
}
