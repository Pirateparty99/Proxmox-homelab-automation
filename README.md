# Proxmox-homelab-automation

Scripts and configs for a Proxmox homelab: an Active Directory domain, an
OpenShift (OKD) cluster on Proxmox, and the pieces joining them — LDAP auth,
Ceph CSI storage, cert-manager with an AD CS issuer.

Nothing site-specific is committed. Hostnames, domains, IPs and credentials live
in `config.env`, which is gitignored.

## Layout

```
config.env          site values (gitignored)
bootstrap.py        renders every *.tmpl -> rendered/, and exports the same values to bash
lib/config.sh       what bash scripts source to get those values

templates/          config-driven files that are not themselves scripts
  helm/<chart>/       values files and manifests

scripts/            everything runnable, grouped by what it targets
  ad/                 PowerShell for the domain controllers / CA
  okd/                against the OKD cluster
  helm/<chart>/       helm installs and the objects around them
  proxmox/            against the Proxmox API / nodes

rendered/           bootstrap.py output (gitignored)
  ad/                 the self-contained bundle to copy to the CA host
secrets/            certificates pulled from the domain (gitignored)
```

## Setup

```bash
pip install jinja2                    # or: dnf install python3-jinja2
cp config.env.example config.env
$EDITOR config.env                    # set AD_DOMAIN and the site values
```

Export the AD root CA to wherever `AD_CA_CERT_FILE` points:

```bash
certutil -ca.cert ca.cer                                   # on the CA
openssl x509 -inform der -in ca.cer -out secrets/ad-ca.crt
```

## Usage

```bash
./bootstrap.py            # render templates - re-run after editing config.env
```

Then run any script directly; they read the config themselves.

```bash
scripts/okd/setup-okd-ldap-auth.sh
scripts/helm/certificate-manager/deploy-cert-man.sh
```

Scripts run from your workstation and need `oc`, `helm` and a working
`KUBECONFIG`. PowerShell scripts are rendered into `rendered/` — copy the
rendered `.ps1` to the Windows host and run it there.

To get the same variables in your own shell:

```bash
source lib/config.sh
```

Other `bootstrap.py` flags: `--list` (what would render), `--export` (shell
export lines), `--json` (resolved config).

## How it fits together

`config.env` holds site values; `bootstrap.py` derives the rest, so setting
`AD_DOMAIN=example.internal` gives you:

| | |
| --- | --- |
| `AD_REALM` | `EXAMPLE.INTERNAL` |
| `AD_BASE_DN` | `OU=EXAMPLE,DC=example,DC=internal` |
| `AD_BIND_DN` | `CN=ldap.svc,OU=Service Accounts,OU=EXAMPLE,DC=example,DC=internal` |
| `ADCS_URL` | `https://dc01.example.internal/certsrv` |

Uncomment the matching line in `config.env` to override any of them. An
environment variable set at run time wins over the file.

`bootstrap.py` is the only implementation of these rules — `lib/config.sh` evals
`bootstrap.py --export`, so the shell scripts cannot drift from the templates.

## Conventions

Follow these and new scripts need no changes here.

- **Never hardcode a site value.** Add it to `config.env.example` and `config.env`.
- **Everything runnable lives under `scripts/`,** grouped by what it targets:
  `scripts/ad`, `scripts/okd`, `scripts/helm/<chart>`, `scripts/proxmox`.
- **Static files a rendered directory needs** are listed in `STAGED_FILES` in
  `bootstrap.py`, which copies them in — so a rendered directory is something
  you can hand to another machine whole.
- **A file needing site values is a `*.tmpl`.** `bootstrap.py` renders it into
  `rendered/`, dropping the leading `templates/` or `scripts/` — so
  `templates/helm/x.yaml.tmpl` becomes `rendered/helm/x.yaml`, and
  `templates/ad/adcs.env.tmpl` becomes `rendered/ad/adcs.env`. A script that
  needs rendering would sit with the other scripts; today only config is
  templated, so `templates/` holds all of it.
- **Bash scripts** `source lib/config.sh` and read the variables.
- **PowerShell scripts** are ordinary `.ps1`, not templates. They read
  `adcs.env` through `scripts/ad/Get-AdcsConfig.ps1`; only that env file is
  generated. Any parameter passed on the command line wins over the file, and an
  environment variable of the same name wins over both.
- **`config.env`, `secrets/` and `rendered/` are gitignored.** Anything
  site-specific belongs in one of them.

Rendering is strict: an undefined name raises `UndefinedError`, and a
defined-but-empty one fails if the template marks it `| required(...)`. Neither
silently produces a blank.

## AD CS bring-up

The issuer talks to the **Certification Authority Web Enrollment** pages
(`/certsrv`) over HTTPS. That role service, not the CA on its own and not CES,
is what it depends on — without it the issuer never goes ready.

Once the three prerequisites below are in place, `scripts/deploy-adcs.sh` runs
the whole thing — bundle, the DC, cert-manager, the issuer:

```bash
PVE_API_TOKEN=... scripts/deploy-adcs.sh --dry-run   # then without --dry-run
```

It needs `PVE_API_TOKEN` exported, key-based ssh to the CA host, and `oc`
logged in; it checks all three before touching anything, and sets up none of
them. The rest of this section is what it does, step by step.

First create the Proxmox API token the CA step uses to snapshot the DC:

```bash
scripts/proxmox/create-pve-api-token.sh --dry-run   # then without --dry-run
```

That makes a `PVESnapshotOnly` role (`VM.Audit`, `VM.Snapshot` — deliberately
*not* `VM.Snapshot.Rollback`) and grants it on the DC's VM alone, so the
credential sitting on a Windows host cannot do anything else. Proxmox prints the
secret once; it is never stored in the repo.

Then get the bundle onto the CA host. `./bootstrap.py` renders `adcs.env` and
stages the `.ps1` beside it, so `rendered/ad` is self-contained — one directory
holding everything that host needs:

```bash
scripts/ad/authorize-ssh-key.sh          # once - so the copy runs unprompted
scripts/ad/copy-to-ca-host.sh            # render, then scp to $ADCS_HOST
scripts/ad/copy-to-ca-host.sh --zip      # or write rendered/ad.zip to move by hand
```

`authorize-ssh-key.sh` installs your public key on the CA host. It exists
because `ssh-copy-id` silently does nothing useful there: Windows OpenSSH sends
accounts in the local Administrators group to a shared
`C:\ProgramData\ssh\administrators_authorized_keys`, ignores
`~/.ssh/authorized_keys` for them, and refuses that shared file unless its ACL
grants only Administrators and SYSTEM. The script checks the account's group
membership, picks the right file and fixes the ACL. Note that file is shared by
every administrator on the host, so prefer a dedicated key (`--key`) over your
general-purpose one.

It checks both halves of the bundle are present before copying, so a half-staged
directory fails here rather than on the CA host. One elevated run does the lot:

```powershell
$env:PVE_API_TOKEN = '<secret>'      # or let it prompt
.\Install-AdcsChain.ps1
```

It calls the three scripts in order, and installs the gMSA on the host in
between:

| # | Script | Does |
| --- | --- | --- |
| 1 | `Install-AdcsCertificationAuthority.ps1` | snapshot, AD CS role, Enterprise CA |
| 2 | `New-AdcsWebEnrollmentGmsa.ps1` | gMSA for the `/certsrv` app pool |
| 3 | `Install-AdcsWebEnrollment.ps1` | publishes `/certsrv` over HTTPS |

Run as Enterprise Admins — step 2 alone would only need Domain Admins.

**These are one-shot, from-scratch scripts.** Every step assumes nothing it
creates already exists — no CA on the host, no KDS root key in the forest, no
`/certsrv` application, no HTTPS binding. That keeps them short and means they
never silently adapt to a half-configured host, but it also means **re-running
after a partial failure will fail** on whatever the first run did create. Roll
back to the snapshot the CA step takes and start again.

This works as one run because the CA host here is also a domain controller. Split
those roles across machines and the three scripts have to be run separately, on
the right host each time; `Install-AdcsChain.ps1` checks and refuses rather than
guessing. Step 2 normally needs a reboot before step 3 so the host sees its new
group membership — the chain purges the computer's Kerberos tickets instead, and
only asks for a reboot if that was not enough.

Taking a snapshot of a running DC is safe. **Rolling one back is not**, and no
script here does it — see the `.NOTES` in `Install-AdcsCertificationAuthority.ps1`
for the USN-rollback and VM-GenerationID detail before you ever restore one.

Then, from the workstation:

```bash
scripts/helm/certificate-manager/deploy-cert-man.sh          # cert-manager + adcs-issuer
scripts/helm/certificate-manager/configure-clusterissuer.sh  # secret + ClusterAdcsIssuer
```

The second checks `ADCS_URL` is reachable and that its certificate validates
against `AD_CA_CERT_FILE` before creating anything, then waits for the issuer to
report ready. `SKIP_PREFLIGHT=1` bypasses the check.

`New-AdcsCesGmsa.ps1` is separate and optional — CES (`ADCS-Enroll-Web-Svc`) is a
different role service, for clients that enrol over the WS-Trust API. The
adcs-issuer does not use it.

## Notes

- The CA service (`CertSvc`) runs as LocalSystem and does **not** support a gMSA.
  The gMSAs here are for the IIS application pools in front of it.
