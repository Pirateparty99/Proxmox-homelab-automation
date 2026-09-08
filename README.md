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

## Notes

- The AD CS issuer needs the **Certification Authority Web Enrollment** role
  service (`/certsrv`) on the CA, over HTTPS. It will not go ready without it.
