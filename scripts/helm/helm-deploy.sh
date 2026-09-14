#!/bin/bash
#
# helm-deploy.sh - one place where this repo runs `helm upgrade --install`.
#
# Every deployment differs only in which chart, which values and which namespace,
# so those are arguments and everything around them - cache lookup, namespace
# creation, waiting for the rollout, reporting what failed - is shared. A new
# deployment is then a values template plus a few lines calling this.
#
# Bash rather than Python: it is a thin wrapper over the helm and oc CLIs, and it
# needs chart_args and the exported config from lib/config.sh, which are already
# bash. Python would buy nothing here and would mean maintaining two config paths.
#
#   scripts/helm/helm-deploy.sh \
#     --chart kasm-helm \
#     --release kasm-workspaces \
#     --namespace kasm-workspaces \
#     --values rendered/helm/kasm-workspaces/values.yaml \
#     --wait
#
# Options:
#   --chart NAME        chart name as listed in bootstrap.py HELM_CHARTS (required)
#   --release NAME      helm release name (required)
#   --namespace NS      target namespace (required)
#   --values FILE       values file; repeatable, applied in order
#   --set K=V           inline override; repeatable
#   --no-create-namespace   do not create the namespace first
#   --wait              wait for the release's workloads to roll out
#   --timeout DUR       how long to wait, default 300s
#   --dry-run           render the manifests and apply nothing
#   -- ARGS...          everything after -- is passed to helm verbatim
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/config.sh"

CHART="" RELEASE="" NAMESPACE="" TIMEOUT="300s"
CREATE_NS=1 WAIT=0 DRY_RUN=0
VALUES=() SETS=() EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart)      CHART="$2"; shift 2 ;;
    --release)    RELEASE="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --values)     VALUES+=("$2"); shift 2 ;;
    --set)        SETS+=("$2"); shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --no-create-namespace) CREATE_NS=0; shift ;;
    --wait)       WAIT=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --)           shift; EXTRA=("$@"); break ;;
    *)            echo "helm-deploy.sh: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$CHART"     ]] || die "--chart is required"
[[ -n "$RELEASE"   ]] || die "--release is required"
[[ -n "$NAMESPACE" ]] || die "--namespace is required"

command -v helm >/dev/null || die "helm not found in PATH"
command -v oc >/dev/null || die "oc not found in PATH"

for f in "${VALUES[@]}"; do
  [[ -f "$f" ]] || die "values file not found: $f
    Templates render at deploy time - run ./bootstrap.py if this is under rendered/."
done

# Cached .tgz when pull-charts.sh has run, upstream reference otherwise.
read -ra CHART_REF <<< "$(chart_args "$CHART")"

HELM_ARGS=(--namespace "$NAMESPACE")
for f in "${VALUES[@]}"; do HELM_ARGS+=(--values "$f"); done
for kv in "${SETS[@]}"; do HELM_ARGS+=(--set "$kv"); done
(( ${#EXTRA[@]} )) && HELM_ARGS+=("${EXTRA[@]}")

log "$RELEASE"
info "chart:     ${CHART_REF[*]}"
info "namespace: $NAMESPACE"
for f in "${VALUES[@]}"; do info "values:    $(realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null || echo "$f")"; done

if (( DRY_RUN )); then
  log "Rendering only"
  helm template "$RELEASE" "${CHART_REF[@]}" "${HELM_ARGS[@]}" \
    | grep -E "^kind:|^  name:" | paste - - | sed 's/^/    /'
  exit 0
fi

oc whoami >/dev/null 2>&1 || die "oc is not authenticated - run scripts/okd/create-oc-token.sh"

if (( CREATE_NS )); then
  # Not --create-namespace: helm only creates it on a first install, so an
  # upgrade into a namespace someone deleted would fail confusingly.
  oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null
fi

log "Installing"
helm upgrade --install "$RELEASE" "${CHART_REF[@]}" "${HELM_ARGS[@]}"

(( WAIT )) || exit 0

# helm reports success once the objects apply. Anything that rejects a pod later
# - an SCC denial, an unschedulable request, a missing image - happens after
# that, so the rollout is what actually says whether this worked.
log "Waiting for rollout (timeout ${TIMEOUT})"
mapfile -t WORKLOADS < <(oc get deployment,statefulset -n "$NAMESPACE" \
  -l "app.kubernetes.io/instance=${RELEASE}" -o name 2>/dev/null)

if (( ${#WORKLOADS[@]} == 0 )); then
  # Not every chart labels its workloads with the release; fall back to helm's
  # own inventory rather than silently skipping the wait.
  mapfile -t WORKLOADS < <(helm get manifest "$RELEASE" -n "$NAMESPACE" 2>/dev/null \
    | awk '/^kind: (Deployment|StatefulSet)$/{k=tolower($2)} /^  name: /{if(k){print k"/"$2; k=""}}')
fi

if (( ${#WORKLOADS[@]} == 0 )); then
  info "no Deployments or StatefulSets in this release - nothing to wait for"
  exit 0
fi

failed=0
for w in "${WORKLOADS[@]}"; do
  info "$w"
  if ! oc rollout status "$w" -n "$NAMESPACE" --timeout="$TIMEOUT" 2>&1 | sed 's/^/      /'; then
    failed=1
  fi
done

if (( failed )); then
  log "Recent events in $NAMESPACE"
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /'
  die "$RELEASE did not roll out"
fi

log "Deployed"
