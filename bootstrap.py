#!/usr/bin/env python3
"""Render every *.tmpl in this repo from config.env, and expose the same values
to the shell scripts.

    ./bootstrap.py                 render all templates into rendered/, and
                                   stage the static scripts that go with them
    ./bootstrap.py --list          show what would be rendered
    ./bootstrap.py --export        emit `export K=V` lines for a shell to eval
    ./bootstrap.py --json          emit the resolved config as JSON
    ./bootstrap.py --charts        list the Helm charts and their pinned versions
    ./bootstrap.py --pull-charts   mirror those charts into charts/
    ./bootstrap.py --dependencies  install missing Python packages first
    ./bootstrap.py --credentials   also obtain any missing credential in secrets/

This is the single place where derived values are computed. lib/config.sh evals
--export rather than deriving anything itself, so bash and the templates can
never drift apart. PowerShell scripts are rendered with their values baked into
param() defaults, so Windows hosts need neither Python nor config.env.

Requires Jinja2 to render: ./bootstrap.py --dependencies installs it and the
rest of requirements.txt, or use dnf install python3-jinja2.
Targets Python 3.6+ so it runs on the older interpreters in LXC containers.
"""

import argparse
import base64
import glob
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys

# Bound here so a failed import leaves them None rather than unbound - render()
# tests for None, and a NameError would bypass that check with a worse message.
Environment = FileSystemLoader = StrictUndefined = None


def _load_jinja():
    """Import Jinja2 into module scope, reporting whether it is there.

    Deliberately not fatal at import time: --dependencies exists to install
    Jinja2, and it cannot do that if merely starting up without Jinja2 is an
    error. Only render() actually needs it, so that is where it is enforced.
    Called again after an install, because by then the import can succeed."""
    global Environment, FileSystemLoader, StrictUndefined
    try:
        from jinja2 import Environment, FileSystemLoader, StrictUndefined
        return True
    except ImportError:
        return False


_load_jinja()

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

# Third-party Python modules the scripts in this repo need, as (import name,
# what needs it). The versions live in requirements.txt, which stays the single
# source for what gets installed - this table exists only to say whether a
# package is already present, which needs the import name rather than the pip
# name (PyYAML imports as yaml).
DEPENDENCIES = [
    ("jinja2", "bootstrap.py, to render the templates"),
    ("yaml", "scripts/okd/deploy-wmco.py"),
    ("kubernetes", "scripts/okd/deploy-wmco.py"),
]
REQUIREMENTS = os.path.join(REPO_ROOT, "requirements.txt")

# Every Helm chart this repo deploys, as (chart name, where it comes from, which
# config key pins it). `helm pull` accepts both an OCI reference and an https
# repo URL, so one table covers both kinds. scripts/helm/pull-charts.sh mirrors
# these into CHART_CACHE, and lib/config.sh's chart_ref prefers that copy - so a
# deploy does not depend on the chart's origin still being reachable, and every
# cluster gets byte-identical charts. An empty version means "whatever is
# current", which is only resolved when the chart is actually pulled.
HELM_CHARTS = [
    {"chart": "cert-manager",
     "source": "oci://quay.io/jetstack/charts/cert-manager",
     "version_key": "CERT_MANAGER_VERSION"},
    {"chart": "kasm-helm",
     "source": "oci://registry-1.docker.io/kasmweb/kasm-helm",
     "version_key": "KASM_CHART_VERSION"},
    {"chart": "adcs-issuer",
     "source": "https://djkormo.github.io/adcs-issuer/",
     "version_key": "ADCS_ISSUER_VERSION"},
    {"chart": "ceph-csi-rbd",
     "source": "https://ceph.github.io/csi-charts",
     "version_key": "CHART_VERSION_RBD"},
    {"chart": "ceph-csi-cephfs",
     "source": "https://ceph.github.io/csi-charts",
     "version_key": "CHART_VERSION_CEPHFS"},
    {"chart": "confluent-for-kubernetes",
     "source": "https://packages.confluent.io/helm",
     "version_key": "CONFLUENT_CHART_VERSION"},
]

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
     "check": "oc"},
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
    default("AD_SERVICE_ACCOUNT_DN", "OU=Service Accounts,%s" % cfg["AD_BASE_DN"])
    default("AD_BIND_DN", "CN=%s,OU=Service Accounts,%s"
                          % (cfg.get("AD_BIND_USER", "ldap.svc"), cfg["AD_BASE_DN"]))

    # The adcs-issuer controller appends the page names itself, so no trailing slash.
    default("ADCS_URL", "https://%s/certsrv" % cfg.get("ADCS_HOST", ""))
    # OKD puts the API on api.<base domain>:6443.
    default("OKD_API_URL", "https://api.%s:6443" % cfg.get("OKD_BASE_DOMAIN", ""))
    # 636 is LDAPS, 389 plain - the scheme has to follow the port.
    default("KASM_LDAP_URL", "%s://%s:%s" % (
        "ldaps" if str(cfg.get("AD_DC_PORT", "")) == "636" else "ldap",
        cfg.get("AD_DC_HOST", ""), cfg.get("AD_DC_PORT", "")))
    # Kasm substitutes the login name into the filter and wraps the result in
    # parens, so the filter has to pin it to an attribute. Without a placeholder
    # it matches every user in the base and the login is rejected as ambiguous.
    # It has to match on both attributes because the two callers pass different
    # forms: signing in appends the domain (user@domain, matching the UPN) while
    # the config page's Test button passes the name exactly as typed (matching
    # sAMAccountName). {0} rather than {} so it can appear twice.
    _login_attrs = [cfg.get("KASM_LDAP_EMAIL_ATTRIBUTE", "userPrincipalName"), "sAMAccountName"]
    _login_attrs = list(dict.fromkeys(_login_attrs))  # same attribute twice matches nothing extra
    _match = "".join("(%s={0})" % a for a in _login_attrs)
    if len(_login_attrs) > 1:
        _match = "(|%s)" % _match
    default("KASM_LDAP_SEARCH_FILTER", "(&(objectClass=user)%s)" % _match)
    # Resolving the user's groups works the same way, except Kasm substitutes the
    # user's DN and then treats each matching entry's own DN as one of their
    # groups - so this has to select GROUP objects the user is a member of. A
    # filter without a placeholder matches the user themselves, whose DN then
    # matches no sso_to_group_mapping row, and they end up with no privileges.
    # Direct membership only: member:1.2.840.113556.1.4.1941:={0} would also walk
    # nested groups, which can grant admin through an unrelated nesting.
    default("KASM_LDAP_GROUP_FILTER", "(&(objectClass=group)(member={0}))")
    # Charts are cached here rather than under rendered/, which bootstrap.py
    # empties and regenerates - a pulled chart is a fetched artifact, not a
    # rendered one, and re-downloading it on every render would be wasteful.
    default("CHART_CACHE", os.path.join(REPO_ROOT, "charts"))
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
    cfg["ADCS_CA_BUNDLE_PEM"] = ""
    if ca and os.path.isfile(ca):
        with open(ca, "rb") as fh:
            raw = fh.read()
        cfg["ADCS_CA_BUNDLE_B64"] = base64.b64encode(raw).decode("ascii")
        # Charts that want the certificate inline (rather than base64) take the
        # PEM as-is; trailing newline stripped so templates control indentation.
        cfg["ADCS_CA_BUNDLE_PEM"] = raw.decode("ascii").strip()

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
    if Environment is None:
        sys.exit("Jinja2 is not installed, so nothing can be rendered.\n"
                 "  ./bootstrap.py --dependencies   (or: dnf install python3-jinja2)")
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


def _oc_works():
    """Whether the generated kubeconfig actually authenticates. Checking only
    that the file exists is not enough - a kubeconfig can be present and stale,
    or reference a CA that has since been removed."""
    path = os.path.join(REPO_ROOT, "secrets", "okd-kubeconfig")
    if not os.path.isfile(path):
        return False
    env = dict(os.environ, KUBECONFIG=path)
    try:
        with open(os.devnull, "w") as null:
            return subprocess.call(["oc", "whoami"], env=env, stdout=null, stderr=null) == 0
    except OSError:
        return False


CHECKS = {"ssh": lambda cfg: _ssh_works(cfg), "oc": lambda cfg: _oc_works()}


def credential_status(cfg):
    """(credential, present, label) for each, where label names what was tested."""
    out = []
    for cred in CREDENTIALS:
        if "file" in cred:
            out.append((cred, os.path.isfile(os.path.join(REPO_ROOT, cred["file"])), cred["file"]))
        elif cred["check"] == "ssh":
            out.append((cred, CHECKS["ssh"](cfg), "ssh to %s" % cfg.get("ADCS_HOST", "")))
        else:
            out.append((cred, CHECKS["oc"](cfg), "oc via secrets/okd-kubeconfig"))
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


def chart_status(cfg):
    """(chart, cached filename or None, version) for each chart in HELM_CHARTS."""
    cache = cfg.get("CHART_CACHE", "")
    out = []
    for entry in HELM_CHARTS:
        chart = entry["chart"]
        version = cfg.get(entry["version_key"], "")
        found = sorted(glob.glob(os.path.join(cache, "%s-*.tgz" % chart)))
        if version:
            # A pinned chart is only satisfied by that exact version; an older
            # cached copy is worse than none, because it would be used silently.
            exact = os.path.join(cache, "%s-%s.tgz" % (chart, version))
            found = [exact] if os.path.isfile(exact) else []
        out.append((chart, os.path.basename(found[-1]) if found else None, version))
    return out


def pull_charts(dry_run=False):
    """Hand off to the pull script, which owns the helm invocations."""
    script = os.path.join(REPO_ROOT, "scripts", "helm", "pull-charts.sh")
    if not os.path.isfile(script):
        sys.exit("%s is missing." % script)
    cmd = [script] + (["--list"] if dry_run else [])
    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError as exc:
        sys.exit("\n%s failed (exit %d)." % (script, exc.returncode))


def dependency_status():
    """(module, present, what needs it) for each third-party module."""
    importlib.invalidate_caches()
    return [(mod, importlib.util.find_spec(mod) is not None, why)
            for mod, why in DEPENDENCIES]


def install_dependencies(dry_run=False):
    """pip install anything missing, from requirements.txt.

    Installs the whole file rather than just the missing names so the pinned
    versions there are what actually gets applied."""
    missing = [(mod, why) for mod, present, why in dependency_status() if not present]
    if not missing:
        print("  all Python dependencies present")
        return
    for mod, why in missing:
        print("  missing %s (needed by %s)" % (mod, why))
    if dry_run:
        print("  would run pip install -r %s" % os.path.relpath(REQUIREMENTS, REPO_ROOT))
        return
    if not os.path.isfile(REQUIREMENTS):
        sys.exit("%s is missing, so there is nothing to install from." % REQUIREMENTS)

    cmd = [sys.executable, "-m", "pip", "install", "-r", REQUIREMENTS]
    print("\n  %s" % " ".join(cmd))
    if subprocess.call(cmd) != 0:
        # PEP 668: a distro-packaged interpreter refuses to install into itself.
        # Outside a virtualenv that refusal is the normal outcome on Fedora and
        # Debian, and this flag is the documented way past it - so retry rather
        # than making the user work out which of the two failures this was.
        print("\n  pip declined; retrying with --break-system-packages")
        if subprocess.call(cmd + ["--break-system-packages"]) != 0:
            sys.exit("\npip install failed. Install them by hand:\n"
                     "  pip install -r %s" % os.path.relpath(REQUIREMENTS, REPO_ROOT))

    still = [mod for mod, present, _ in dependency_status() if not present]
    if still:
        sys.exit("\npip reported success but these are still not importable: %s"
                 % ", ".join(still))
    # Rendering happens later in this same process, which started without it.
    _load_jinja()
    print("  installed")


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
    ap.add_argument("--pull-charts", action="store_true",
                    help="mirror the Helm charts into CHART_CACHE (needs network)")
    ap.add_argument("--charts", action="store_true",
                    help="emit the Helm chart table as name/source/version TSV")
    ap.add_argument("--dependencies", action="store_true",
                    help="install missing Python packages from requirements.txt")
    ap.add_argument("--credentials", action="store_true",
                    help="also obtain any missing credential (needs network "
                         "access; oc and ssh will prompt for passwords)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.dependencies:
        install_dependencies(dry_run=args.list)

    cfg = derive(load_config(args.config))
    cfg["RENDER_DIR"] = args.out
    cfg["CONFIG_FILE"] = args.config

    if args.charts:
        # Tab separated so the shell can read it without quoting games; a chart
        # whose version key is unset prints an empty third field, meaning latest.
        for entry in HELM_CHARTS:
            print("%s\t%s\t%s" % (entry["chart"], entry["source"],
                                   cfg.get(entry["version_key"], "")))
        return

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

    if not args.quiet and not args.dependencies:
        # Cheap - just an import check - so unlike the credential probes this
        # does not need to wait for a flag before it is worth doing.
        absent = ["%s (%s)" % (mod, why)
                  for mod, present, why in dependency_status() if not present]
        if absent:
            print("\n  missing Python packages: %s" % ", ".join(absent))
            print("  run ./bootstrap.py --dependencies to install them")

    if args.pull_charts:
        pull_charts(dry_run=args.list)
    elif not args.quiet:
        missing = [c for c, cached, _ in chart_status(cfg) if cached is None]
        if missing:
            print("\n  charts not cached: %s" % ", ".join(missing))
            print("  run ./bootstrap.py --pull-charts to mirror them locally")

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
