#!/usr/bin/env python3
"""Render every *.tmpl in this repo from config.env, and expose the same values
to the shell scripts.

    ./bootstrap.py                 render all templates into rendered/, and
                                   stage the static scripts that go with them
    ./bootstrap.py --list          show what would be rendered
    ./bootstrap.py --export        emit `export K=V` lines for a shell to eval
    ./bootstrap.py --json          emit the resolved config as JSON
    ./bootstrap.py --credentials   also obtain any missing credential in secrets/

This is the single place where derived values are computed. lib/config.sh evals
--export rather than deriving anything itself, so bash and the templates can
never drift apart. PowerShell scripts are rendered with their values baked into
param() defaults, so Windows hosts need neither Python nor config.env.

Requires Jinja2:  dnf install python3-jinja2   |   pip install jinja2
Targets Python 3.6+ so it runs on the older interpreters in LXC containers.
"""

import argparse
import base64
import glob
import json
import os
import shlex
import shutil
import subprocess
import sys

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:
    sys.exit("Jinja2 is not installed. Try: dnf install python3-jinja2  (or pip install jinja2)")

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = {".git", "rendered", "secrets"}
# A *.tmpl under one of these renders to the tree BELOW it, so both top-level
# groupings collapse to the same output shape:
#     templates/helm/x.yaml.tmpl -> rendered/helm/x.yaml
#     scripts/ad/y.ps1.tmpl      -> rendered/ad/y.ps1
# Scripts that happen to need rendering therefore sit with the other scripts,
# not in a separate tree, while their output stays where the docs say it is.
RENDER_ROOTS = ("templates", "scripts")

# Static files copied verbatim into the render tree, as (glob, destination).
# A rendered directory should be self-contained: rendered/ad holds the AD CS
# scripts next to the adcs.env they read, so it can be handed to the CA host as
# one folder rather than assembled by hand from two places.
STAGED_FILES = [("scripts/ad/*.ps1", "ad")]

# Credentials are not rendered. They are obtained once from the live systems and
# written into secrets/, so they are listed here rather than templated: as
# (what it produces, what produces it, what it is for). --credentials runs the
# ones whose output is missing. A plain run never touches the network - it only
# says which are absent - because rendering is something you do casually after
# editing config.env, and it should not depend on being online or logged in.
# Each entry is tested either by the file it produces, or - where it leaves no
# artifact - by trying it. Order is the order they are obtained in.
CREDENTIALS = [
    {"desc": "key-based ssh to the CA host",
     "script": "scripts/ad/authorize-ssh-key.sh",
     "check": "ssh"},
    {"desc": "Proxmox API token, for snapshotting the DC",
     "script": "scripts/proxmox/create-pve-api-token.sh",
     "file": "secrets/pve-api-token.env"},
    {"desc": "OKD kubeconfig, from a non-expiring ServiceAccount token",
     "script": "scripts/okd/create-oc-token.sh",
     "file": "secrets/okd-kubeconfig"},
]


def load_config(path):
    """Parse config.env. An existing environment variable wins over the file, so
    a one-off override works:  AD_DC_HOST=dc02.example.internal ./bootstrap.py
    """
    if not os.path.isfile(path):
        sys.exit("%s not found. Copy config.env.example to config.env and edit it." % path)

    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            cfg[key] = os.environ.get(key) or value
    return cfg


def derive(cfg):
    """Fill in everything that follows from AD_DOMAIN. Anything already set in
    config.env is left alone."""
    if not cfg.get("AD_DOMAIN"):
        sys.exit("AD_DOMAIN is not set in config.env")

    def default(key, value):
        if not cfg.get(key):
            cfg[key] = value

    domain = cfg["AD_DOMAIN"]
    default("AD_REALM", domain.upper())
    default("AD_NETBIOS", domain.split(".")[0].upper())
    default("AD_DOMAIN_DN", "DC=" + domain.replace(".", ",DC="))

    # May legitimately be empty (objects at the domain root), so only default it
    # when the key is absent entirely.
    if "AD_BASE_OU" not in cfg:
        cfg["AD_BASE_OU"] = "OU=" + cfg["AD_NETBIOS"]

    base_ou = cfg["AD_BASE_OU"]
    default("AD_BASE_DN", "%s,%s" % (base_ou, cfg["AD_DOMAIN_DN"]) if base_ou else cfg["AD_DOMAIN_DN"])
    default("AD_GROUP_BASE_DN", "OU=Groups,%s" % cfg["AD_BASE_DN"])
    default("AD_BIND_DN", "CN=%s,OU=Service Accounts,%s"
                          % (cfg.get("AD_BIND_USER", "ldap.svc"), cfg["AD_BASE_DN"]))

    # The adcs-issuer controller appends the page names itself, so no trailing slash.
    default("ADCS_URL", "https://%s/certsrv" % cfg.get("ADCS_HOST", ""))
    # OKD puts the API on api.<base domain>:6443.
    default("OKD_API_URL", "https://api.%s:6443" % cfg.get("OKD_BASE_DOMAIN", ""))
    default("ADCS_CREDENTIALS_SECRET", "%s-credentials" % cfg.get("ADCS_ISSUER_NAME", "adcs"))
    default("CEPH_SSH", "%s@%s" % (cfg.get("CEPH_SSH_USER", "root"), cfg.get("PVE_CEPH_HOST", "")))
    # Same login, different node: PVE_API_HOST is whichever node hosts the DC VM,
    # which need not be the one the ceph CLI is run on.
    default("PVE_SSH", "%s@%s" % (cfg.get("CEPH_SSH_USER", "root"), cfg.get("PVE_API_HOST", "")))

    # Paths in config.env may be relative to the repo root.
    ca = cfg.get("AD_CA_CERT_FILE", "")
    if ca and not os.path.isabs(ca):
        ca = os.path.join(REPO_ROOT, ca)
    cfg["AD_CA_CERT_FILE"] = ca

    # Read the CA in here so the certificate itself never has to live in a
    # template. Absent is not fatal - templates guard on it.
    cfg["ADCS_CA_BUNDLE_B64"] = ""
    if ca and os.path.isfile(ca):
        with open(ca, "rb") as fh:
            cfg["ADCS_CA_BUNDLE_B64"] = base64.b64encode(fh.read()).decode("ascii")

    # Scripts run from a workstation, so the kubeconfig lives wherever the user
    # keeps it. Expand ~ here: --export shell-quotes values, so a literal tilde
    # would survive the eval unexpanded and silently point oc at nothing.
    if cfg.get("KUBECONFIG"):
        cfg["KUBECONFIG"] = os.path.expanduser(cfg["KUBECONFIG"])

    cfg["REPO_ROOT"] = REPO_ROOT
    return cfg


def find_templates():
    found = []
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name.endswith(".tmpl"):
                found.append(os.path.relpath(os.path.join(dirpath, name), REPO_ROOT))
    return sorted(found)


def _output_path(rel):
    """Where a template renders to, relative to the render dir.

    The leading RENDER_ROOTS segment is dropped, so the rendered tree mirrors
    the path below it rather than repeating the grouping directory. A .tmpl
    found anywhere else keeps its own path, so a one-off still works.
    """
    out = rel[:-len(".tmpl")]
    for root in RENDER_ROOTS:
        prefix = root + os.sep
        if out.startswith(prefix):
            return out[len(prefix):]
    return out


def _required(value, name="value"):
    """StrictUndefined catches names that do not exist; this catches ones that
    exist but are empty, which is the more common config.env mistake."""
    if value is None or value == "":
        raise ValueError("%s is empty - set it in config.env" % name)
    return value


def _psquote(value):
    """Render a value as a PowerShell single-quoted string, doubling any embedded
    quote. Lets bootstrap.py bake config into .ps1 files safely, so Windows hosts
    need neither Python nor a copy of config.env."""
    return "'" + str(value).replace("'", "''") + "'"


def render(cfg, out_dir, dry_run=False):
    env = Environment(
        loader=FileSystemLoader(REPO_ROOT),
        undefined=StrictUndefined,   # an unset variable is an error, not a blank
        keep_trailing_newline=True,
    )
    env.filters["required"] = _required
    env.filters["psquote"] = _psquote
    results = []
    for rel in find_templates():
        dest = os.path.join(out_dir, _output_path(rel))
        results.append((rel, dest))
        if dry_run:
            continue
        text = env.get_template(rel.replace(os.sep, "/")).render(**cfg)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(text)
    return results


def stage(out_dir, dry_run=False):
    """Copy STAGED_FILES into the render tree. Returns (src, dest) pairs."""
    results = []
    for pattern, dest_dir in STAGED_FILES:
        for src in sorted(glob.glob(os.path.join(REPO_ROOT, pattern))):
            dest = os.path.join(out_dir, dest_dir, os.path.basename(src))
            results.append((os.path.relpath(src, REPO_ROOT), dest))
            if dry_run:
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(src, dest)
    return results


def _ssh_works(cfg):
    """Whether key-based ssh to the CA host already works. Nothing is written
    when it does, so the only way to know is to try it."""
    target = "%s@%s" % (cfg.get("ADCS_SSH_USER", ""), cfg.get("ADCS_HOST", ""))
    try:
        with open(os.devnull, "w") as null:
            return subprocess.call(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target, "exit"],
                stdout=null, stderr=null) == 0
    except OSError:
        return False


def credential_status(cfg):
    """(credential, present, label) for each, where label names what was tested."""
    out = []
    for cred in CREDENTIALS:
        if "file" in cred:
            out.append((cred, os.path.isfile(os.path.join(REPO_ROOT, cred["file"])), cred["file"]))
        else:
            out.append((cred, _ssh_works(cfg), "ssh to %s" % cfg.get("ADCS_HOST", "")))
    return out


def fetch_credentials(cfg, dry_run=False):
    """Run the script behind each missing credential, in order. Present ones are
    left alone - re-issuing a token invalidates the one already deployed. These
    scripts prompt: oc and ssh ask for passwords themselves, and nothing here
    reads, stores or echoes one."""
    for cred, present, label in credential_status(cfg):
        if present:
            print("  have %s" % label)
            continue
        if dry_run:
            print("  would run %s -> %s" % (cred["script"], label))
            continue
        print("\n  %s: running %s" % (cred["desc"], cred["script"]))
        try:
            subprocess.check_call([os.path.join(REPO_ROOT, cred["script"])])
        except subprocess.CalledProcessError as exc:
            # The script has already said what went wrong on stderr; a Python
            # traceback on top of that buries it.
            sys.exit("\n%s failed (exit %d). Nothing further was attempted."
                     % (cred["script"], exc.returncode))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.environ.get("CONFIG_FILE",
                                                       os.path.join(REPO_ROOT, "config.env")))
    ap.add_argument("--out", default=os.environ.get("RENDER_DIR",
                                                    os.path.join(REPO_ROOT, "rendered")))
    ap.add_argument("--list", action="store_true", help="show what would be rendered")
    ap.add_argument("--export", action="store_true", help="emit shell export lines")
    ap.add_argument("--json", action="store_true", help="emit the resolved config as JSON")
    ap.add_argument("--credentials", action="store_true",
                    help="also obtain any missing credential (needs network "
                         "access; oc and ssh will prompt for passwords)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    cfg = derive(load_config(args.config))
    cfg["RENDER_DIR"] = args.out
    cfg["CONFIG_FILE"] = args.config

    if args.json:
        print(json.dumps(cfg, indent=2, sort_keys=True))
        return

    if args.export:
        # Skip empties: exporting KUBECONFIG="" would point oc at nothing, which
        # is worse than leaving it unset and letting the default apply.
        for key in sorted(cfg):
            if cfg[key] != "":
                print("export %s=%s" % (key, shlex.quote(cfg[key])))
        return

    try:
        results = render(cfg, args.out, dry_run=args.list)
        staged = stage(args.out, dry_run=args.list)
    except Exception as exc:                      # noqa: BLE001 - message is the point
        sys.exit("render failed: %s: %s" % (type(exc).__name__, exc))

    if not args.quiet:
        verb = "would render" if args.list else "rendered"
        for src, dest in results:
            print("  %s %s -> %s" % (verb, src, os.path.relpath(dest, REPO_ROOT)))
        if not results:
            print("  no *.tmpl files found")
        verb = "would stage" if args.list else "staged"
        for src, dest in staged:
            print("  %s %s -> %s" % (verb, src, os.path.relpath(dest, REPO_ROOT)))

    if args.credentials:
        fetch_credentials(cfg, dry_run=args.list)
    elif not args.quiet:
        # Worth saying, since the deployment stops on a missing one - but only
        # when something is actually absent. The ssh check costs a connection
        # attempt, so this is skipped under --quiet.
        missing = [label for _, present, label in credential_status(cfg) if not present]
        if missing:
            print("\n  missing credentials: %s" % ", ".join(missing))
            print("  run ./bootstrap.py --credentials to obtain them")


if __name__ == "__main__":
    main()
