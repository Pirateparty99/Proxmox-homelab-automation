# Proxmox-homelab-automation

Scripts and configs for a Proxmox homelab: an Active Directory domain, an
OpenShift (OKD) cluster on Proxmox, and the pieces joining them — LDAP auth,
Ceph CSI storage, cert-manager with an AD CS issuer.

Nothing site-specific is committed. Hostnames, domains, IPs and credentials live
in `config.env`, which is gitignored.

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
okd/scripts/setup-okd-ldap-auth.sh
helm/certificate-manager/scripts/deploy-cert-man.sh
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
- **A file needing site values is a `*.tmpl`.** `bootstrap.py` finds every one in
  the repo and renders it into `rendered/`, mirroring the source path.
- **Bash scripts** `source lib/config.sh` and read the variables.
- **PowerShell scripts** are templated whole — values are baked into `param()`
  defaults via the `psquote` filter, so the Windows host needs no config file.
- **`config.env`, `secrets/` and `rendered/` are gitignored.** Anything
  site-specific belongs in one of them.

Rendering is strict: an undefined name raises `UndefinedError`, and a
defined-but-empty one fails if the template marks it `| required(...)`. Neither
silently produces a blank.

## AD CS bring-up

The issuer talks to the **Certification Authority Web Enrollment** pages
(`/certsrv`) over HTTPS. That role service, not the CA on its own and not CES,
is what it depends on — without it the issuer never goes ready.

Render first (`./bootstrap.py`), then copy each rendered `.ps1` to the Windows
host named and run it elevated:

| # | On | Script | Does |
| --- | --- | --- | --- |
| 1 | CA host | `Install-AdcsCertificationAuthority.ps1` | AD CS role + Enterprise CA |
| 2 | a DC | `New-AdcsWebEnrollmentGmsa.ps1` | gMSA for the `/certsrv` app pool |
| 3 | CA host | `Install-AdcsWebEnrollment.ps1` | publishes `/certsrv` over HTTPS |

Step 2 needs Domain Admins; 1 and 3 need Enterprise Admins. Reboot the web host
between 2 and 3 so it picks up its new group membership, or
`Test-ADServiceAccount` fails in step 3.

Step 1 snapshots its own VM through the Proxmox API before it changes anything.
Create a token and grant it `VM.Snapshot` on the DC:

```bash
pveum user token add root@pam automation --privsep 0
```

Put the token *id* in `PVE_API_TOKEN_ID`; the secret is never stored in the repo
— export `PVE_API_TOKEN` on the Windows host or let the script prompt. Add
`-WhatIf` to see what it would snapshot, or `-SnapshotFirst:$false` to skip.

Taking a snapshot of a running DC is safe. **Rolling one back is not**, and no
script here does it — see the `.NOTES` in `Install-AdcsCertificationAuthority.ps1`
for the USN-rollback and VM-GenerationID detail before you ever restore one.

Then, from the workstation:

```bash
helm/certificate-manager/scripts/deploy-cert-man.sh          # cert-manager + adcs-issuer
helm/certificate-manager/scripts/deploy-adcs-clusterissuer.sh  # secret + ClusterAdcsIssuer
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
