#!/bin/bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/config.sh"

NAMESPACE="${KASM_NAMESPACE:-kasm-workspaces}"
RELEASE_NAME="${KASM_RELEASE:-kasm-workspaces}"

render_templates --quiet

# A Job's spec.template is immutable, and this chart does not mark db-init as a
# helm hook - so helm tries to patch it in place and any values change that
# alters its pod template fails the entire upgrade:
#   Job.batch "kasm-workspaces-db-init" is invalid: spec.template: field is immutable
# Deleting it first lets helm recreate it. It is an idempotent init job: it
# checks whether the schema is already at head and exits if so. This has to
# happen before helm runs, so it stays here rather than in helm-deploy.sh.
oc delete job "${RELEASE_NAME}-db-init" -n "$NAMESPACE" --ignore-not-found

# No --wait: this chart's StatefulSets come up in a dependency order of their
# own, and the guac/rdp pods are routinely not Ready until the database has been
# initialised. Waiting here reports failure for something that is merely slow.
"$REPO_ROOT/scripts/helm/helm-deploy.sh" \
  --chart kasm-helm \
  --release "$RELEASE_NAME" \
  --namespace "$NAMESPACE" \
  --values "$RENDER_DIR/helm/kasm-workspaces/values.yaml"
