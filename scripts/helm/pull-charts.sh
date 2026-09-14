#!/bin/bash
#
# pull-charts.sh - mirror every Helm chart this repo deploys into CHART_CACHE.
#
# The chart list lives in bootstrap.py (HELM_CHARTS) so the versions already in
# config.env stay the only place a chart is pinned. Once a chart is cached,
# chart_args in lib/config.sh hands the deploy scripts the local .tgz instead of
# the upstream reference, which means a deploy no longer depends on quay.io,
# docker.io or a GitHub Pages repo being reachable, and every cluster gets
# byte-identical charts.
#
# Charts pinned to a version are only fetched when that exact version is absent.
# Unpinned ones (ceph-csi) are fetched once and then left alone, since "latest"
# changing underneath a cache is the thing a cache exists to prevent - use
# --force to deliberately refresh them.
#
# Usage:
#   scripts/helm/pull-charts.sh            # fetch whatever is missing
#   scripts/helm/pull-charts.sh --force    # re-fetch everything, including latest
#   scripts/helm/pull-charts.sh --list     # show what is cached, fetch nothing
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

CACHE="${CHART_CACHE:?CHART_CACHE is not set}"

FORCE=0
LIST=0
case "${1:-}" in
  --force) FORCE=1 ;;
  --list)  LIST=1 ;;
  "")      ;;
  *)       echo "unknown argument: $1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v helm >/dev/null || die "helm not found in PATH"

if (( LIST )); then
  log "Cached charts in $(realpath --relative-to="$REPO_ROOT" "$CACHE" 2>/dev/null || echo "$CACHE")"
  if compgen -G "$CACHE/*.tgz" >/dev/null; then
    for f in "$CACHE"/*.tgz; do
      printf '    %-46s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
  else
    info "(nothing cached yet)"
  fi
  log "Expected"
  while IFS=$'\t' read -r chart source version; do
    [[ -n "$chart" ]] || continue
    if cached=$(ls -t "$CACHE/$chart"-*.tgz 2>/dev/null | head -1); [[ -n "$cached" ]]; then
      printf '    %-28s %s\n' "$chart" "cached: $(basename "$cached")"
    else
      printf '    %-28s %s\n' "$chart" "MISSING (${version:-latest})"
    fi
  done < <(python3 "$REPO_ROOT/bootstrap.py" --charts)
  exit 0
fi

mkdir -p "$CACHE"
log "Pulling charts into $(realpath --relative-to="$REPO_ROOT" "$CACHE" 2>/dev/null || echo "$CACHE")"

pulled=0
skipped=0
while IFS=$'\t' read -r chart source version; do
  [[ -n "$chart" ]] || continue

  if (( ! FORCE )); then
    if [[ -n "$version" ]]; then
      # Pinned: helm names the file <chart>-<version>.tgz, so the exact version
      # being present is the whole question.
      if [[ -f "$CACHE/$chart-$version.tgz" ]]; then
        info "have    $chart-$version.tgz"
        skipped=$((skipped + 1))
        continue
      fi
    elif compgen -G "$CACHE/$chart-*.tgz" >/dev/null; then
      existing=$(basename "$(ls -t "$CACHE/$chart"-*.tgz | head -1)")
      info "have    $existing (unpinned - --force to refresh)"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  args=(--destination "$CACHE")
  [[ -n "$version" ]] && args+=(--version "$version")
  if [[ "$source" == oci://* ]]; then
    target=("$source")
  else
    # A classic repo needs the chart name and --repo rather than a URL on its
    # own, and passing --repo avoids mutating the user's `helm repo` list.
    target=("$chart" --repo "$source")
  fi

  info "pulling $chart ${version:+($version) }from $source"
  if ! helm pull "${target[@]}" "${args[@]}" 2>&1 | sed 's/^/      /'; then
    die "failed to pull $chart from $source"
  fi
  pulled=$((pulled + 1))
done < <(python3 "$REPO_ROOT/bootstrap.py" --charts)

log "Done"
info "pulled $pulled, already had $skipped"
info "deploy scripts will now use these instead of fetching from upstream"
