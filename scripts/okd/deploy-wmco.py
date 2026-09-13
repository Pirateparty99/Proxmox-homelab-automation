#!/usr/bin/env python3
"""
deploy_wmco.py

Deploys the Windows Machine Config Operator (WMCO) to an OpenShift/OKD
cluster using the official `kubernetes` Python client library (no kubectl
or oc subprocess calls). YAML manifests are Jinja2 templates under
templates/okd/wmco, rendered in-memory and applied via the Kubernetes API.
They take their values from the command-line arguments below, so they are
rendered here rather than by bootstrap.py (which only handles *.tmpl).

Requires a working kubeconfig context with cluster-admin privileges and
OLM already installed on the cluster.

Usage:
    python3 deploy_wmco.py [--namespace NS] [--package PKG] [--channel CH]
                            [--catalog-source SRC] [--catalog-source-namespace NS]
                            [--timeout SECONDS] [--dry-run]

Defaults target OKD's community-operators catalog. For OpenShift with a Red Hat
subscription, pass --package windows-machine-config-operator --channel stable
--catalog-source redhat-operators.

Dependencies:
    ./bootstrap.py --dependencies      (installs requirements.txt)
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

try:
    import yaml
    from jinja2 import Environment, FileSystemLoader
    from kubernetes import client, config
    from kubernetes.client.rest import ApiException
except ImportError as e:
    print(
        "ERROR: missing dependency. Install with:\n"
        "  ./bootstrap.py --dependencies\n"
        f"({e})",
        file=sys.stderr,
    )
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
# scripts/okd/ -> repo root, matching the ../../ the shell scripts use.
REPO_ROOT = SCRIPT_DIR.parents[1]
TEMPLATE_DIR = REPO_ROOT / "templates" / "okd" / "wmco"

OLM_GROUP = "operators.coreos.com"
OPERATORGROUP_VERSION = "v1"
SUBSCRIPTION_VERSION = "v1alpha1"


def log(msg: str) -> None:
    print(f"\033[1;34m[INFO]\033[0m {msg}")


def ok(msg: str) -> None:
    print(f"\033[1;32m[ OK ]\033[0m {msg}")


def err(msg: str) -> None:
    print(f"\033[1;31m[FAIL]\033[0m {msg}", file=sys.stderr)


def render_manifest(name: str, context: dict) -> dict:
    if not TEMPLATE_DIR.is_dir():
        err(f"Template directory not found: {TEMPLATE_DIR}")
        raise SystemExit(1)
    env = Environment(loader=FileSystemLoader(str(TEMPLATE_DIR)), keep_trailing_newline=True)
    template = env.get_template(f"{name}.yaml.j2")
    rendered = template.render(**context)
    manifest = yaml.safe_load(rendered)
    ok(f"Rendered {name}.yaml.j2")
    return manifest


def load_kube_client() -> None:
    try:
        config.load_kube_config()
    except Exception:
        # Fall back to in-cluster config if running inside a pod
        config.load_incluster_config()
    ctx = config.list_kube_config_contexts()
    current = ctx[1]["name"] if ctx and ctx[1] else "in-cluster"
    ok(f"Connected using context: {current}")


def apply_namespace(manifest: dict) -> None:
    v1 = client.CoreV1Api()
    name = manifest["metadata"]["name"]
    try:
        v1.create_namespace(body=manifest)
        ok(f"Namespace '{name}' created.")
    except ApiException as e:
        if e.status == 409:
            v1.patch_namespace(name=name, body=manifest)
            ok(f"Namespace '{name}' already existed, patched.")
        else:
            err(f"Failed to create namespace: {e}")
            raise SystemExit(1)


def apply_custom_object(manifest: dict, version: str, plural: str, namespace: str) -> None:
    api = client.CustomObjectsApi()
    name = manifest["metadata"]["name"]
    try:
        api.create_namespaced_custom_object(
            group=OLM_GROUP, version=version, namespace=namespace,
            plural=plural, body=manifest,
        )
        ok(f"{plural[:-1].capitalize()} '{name}' created.")
    except ApiException as e:
        if e.status == 409:
            api.patch_namespaced_custom_object(
                group=OLM_GROUP, version=version, namespace=namespace,
                plural=plural, name=name, body=manifest,
            )
            ok(f"{plural[:-1].capitalize()} '{name}' already existed, patched.")
        else:
            err(f"Failed to create {plural}: {e}")
            raise SystemExit(1)


def wait_for_installed_csv(namespace: str, package: str, timeout: int) -> str:
    log(f"Waiting for Subscription to report an installed CSV (up to {timeout}s)...")
    api = client.CustomObjectsApi()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            sub = api.get_namespaced_custom_object(
                group=OLM_GROUP, version=SUBSCRIPTION_VERSION, namespace=namespace,
                plural="subscriptions", name=package,
            )
            csv = sub.get("status", {}).get("installedCSV")
            if csv:
                ok(f"CSV installed: {csv}")
                return csv
            # OLM reports an unresolvable subscription here rather than failing
            # outright, and it would otherwise just look like a slow install.
            for cond in sub.get("status", {}).get("conditions", []):
                if cond.get("type") == "ResolutionFailed" and cond.get("status") == "True":
                    err(f"OLM cannot resolve the subscription: {cond.get('message')}")
                    err("Check --package/--channel/--catalog-source against: "
                        f"oc get packagemanifest -n {namespace}")
                    raise SystemExit(1)
        except ApiException as e:
            if e.status != 404:
                err(f"Error querying subscription: {e}")
                raise SystemExit(1)
        time.sleep(5)
    err("Timed out waiting for the Subscription to report an installed CSV.")
    raise SystemExit(1)


def wait_for_csv_succeeded(namespace: str, csv: str, timeout: int) -> None:
    log(f"Waiting for CSV '{csv}' to reach phase=Succeeded...")
    api = client.CustomObjectsApi()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            obj = api.get_namespaced_custom_object(
                group=OLM_GROUP, version="v1alpha1", namespace=namespace,
                plural="clusterserviceversions", name=csv,
            )
            phase = obj.get("status", {}).get("phase")
            if phase == "Succeeded":
                ok("CSV succeeded.")
                return
            if phase == "Failed":
                err(f"CSV '{csv}' entered Failed phase.")
                raise SystemExit(1)
        except ApiException as e:
            if e.status != 404:
                err(f"Error querying CSV: {e}")
                raise SystemExit(1)
        time.sleep(5)
    err(f"Timed out waiting for CSV '{csv}' to succeed.")
    raise SystemExit(1)


def csv_deployment_names(namespace: str, csv: str) -> list[str]:
    """The deployments a CSV installs. Read from the CSV rather than assumed,
    because the community package and the Red Hat one do not name them alike."""
    api = client.CustomObjectsApi()
    obj = api.get_namespaced_custom_object(
        group=OLM_GROUP, version="v1alpha1", namespace=namespace,
        plural="clusterserviceversions", name=csv,
    )
    deployments = (obj.get("spec", {}).get("install", {})
                      .get("spec", {}).get("deployments", []))
    names = [d["name"] for d in deployments if d.get("name")]
    if not names:
        err(f"CSV '{csv}' declares no deployments.")
        raise SystemExit(1)
    return names


def wait_for_deployment(namespace: str, name: str, timeout: int) -> None:
    log(f"Waiting for deployment '{name}' to become available...")
    apps = client.AppsV1Api()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            dep = apps.read_namespaced_deployment_status(name=name, namespace=namespace)
            conditions = dep.status.conditions or []
            if any(c.type == "Available" and c.status == "True" for c in conditions):
                ok(f"Deployment '{name}' is available.")
                return
        except ApiException as e:
            if e.status != 404:
                err(f"Error querying deployment: {e}")
                raise SystemExit(1)
        time.sleep(5)
    err(f"Timed out waiting for deployment '{name}' to become available.")
    raise SystemExit(1)


def print_pods(namespace: str, deployment: str) -> None:
    """Selector comes from the deployment, so this does not depend on the
    operator using any particular label convention."""
    apps = client.AppsV1Api()
    v1 = client.CoreV1Api()
    dep = apps.read_namespaced_deployment(name=deployment, namespace=namespace)
    match = (dep.spec.selector.match_labels or {}) if dep.spec.selector else {}
    selector = ",".join(f"{k}={v}" for k, v in match.items())
    pods = v1.list_namespaced_pod(namespace=namespace, label_selector=selector)
    for pod in pods.items:
        print(f"  {pod.metadata.name}\t{pod.status.phase}")


def print_post_install_notes(namespace: str) -> None:
    print(f"""
------------------------------------------------------------------------------
WMCO is deployed. Before it can configure Windows nodes you still need to:

  1. Create the cloud provider secret WMCO uses to provision instances,
     e.g. for AWS:
       kubectl create secret generic cloud-private-key \\
         --namespace {namespace} \\
         --from-file=private-key.pem=/path/to/your-key.pem

  2. Ensure a Windows-capable MachineSet/MachineConfig exists so WMCO knows
     which nodes to configure (version-dependent).

  3. Verify DNS/network access from the cluster to the Windows instances
     and confirm the RDP/WinRM/SSH access method your WMCO version expects.

Docs: https://docs.okd.io/latest/windows_containers/enabling-windows-container-workloads.html
------------------------------------------------------------------------------
""")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Deploy WMCO to OpenShift/OKD via the Kubernetes Python client.")
    p.add_argument("--namespace", default="openshift-windows-machine-config-operator")
    # OKD ships the community catalog; redhat-operators is OpenShift-only and
    # needs a Red Hat pull secret, so pointing at it here fails to resolve with
    # "no operators found from catalog redhat-operators". The community build is
    # a differently named package, and its only channel is preview.
    p.add_argument("--package", default="community-windows-machine-config-operator",
                   help="operator package name in the catalog")
    p.add_argument("--channel", default="preview")
    p.add_argument("--catalog-source", default="community-operators")
    p.add_argument("--catalog-source-namespace", default="openshift-marketplace")
    p.add_argument("--timeout", type=int, default=300, help="Seconds to wait for each readiness check")
    p.add_argument("--dry-run", action="store_true", help="Render and print manifests without applying them")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    context = {
        "namespace": args.namespace,
        "package": args.package,
        "channel": args.channel,
        "catalog_source": args.catalog_source,
        "catalog_source_namespace": args.catalog_source_namespace,
    }

    namespace_manifest = render_manifest("namespace", context)
    operatorgroup_manifest = render_manifest("operatorgroup", context)
    subscription_manifest = render_manifest("subscription", context)

    if args.dry_run:
        for m in (namespace_manifest, operatorgroup_manifest, subscription_manifest):
            print(yaml.dump(m, sort_keys=False))
            print("---")
        log("Dry run complete; nothing was applied.")
        return

    load_kube_client()

    apply_namespace(namespace_manifest)
    apply_custom_object(operatorgroup_manifest, OPERATORGROUP_VERSION, "operatorgroups", args.namespace)
    apply_custom_object(subscription_manifest, SUBSCRIPTION_VERSION, "subscriptions", args.namespace)

    csv = wait_for_installed_csv(args.namespace, args.package, args.timeout)
    wait_for_csv_succeeded(args.namespace, csv, args.timeout)

    deployments = csv_deployment_names(args.namespace, csv)
    for deployment in deployments:
        wait_for_deployment(args.namespace, deployment, args.timeout)

    print_pods(args.namespace, deployments[0])
    print_post_install_notes(args.namespace)


if __name__ == "__main__":
    main()

