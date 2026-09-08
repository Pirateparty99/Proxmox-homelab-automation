# Proxmox-homelab-automation

Scripts and configs for a Proxmox homelab: an Active Directory domain, an
OpenShift (OKD) cluster running on Proxmox, and the pieces that join them
together (LDAP auth, Ceph CSI storage, cert-manager with an AD CS issuer).

The repo is templated. No hostname, domain or IP address is hardcoded in a
tracked file — all of it lives in `config.env`, which is gitignored.

## Setup

Install Jinja2 once — it is the only dependency:

```bash
dnf install python3-jinja2        # or: pip install jinja2
```

```bash
cp config.env.example config.env
$EDITOR config.env            # set AD_DOMAIN and the handful of site values
./bootstrap.py                # render every template into rendered/
```

Export the AD root CA and drop it where `AD_CA_CERT_FILE` points:

```bash
certutil -ca.cert ca.cer                                  # on the CA
openssl x509 -inform der -in ca.cer -out secrets/ad-ca.crt
```

To get the same variables in your own shell:

```bash
source lib/config.sh
```

## How the configuration works

`config.env` holds site values. `bootstrap.py` loads it and derives the rest, so
setting `AD_DOMAIN=example.internal` yields:

| Derived | Value |
| --- | --- |
| `AD_REALM` | `EXAMPLE.INTERNAL` |
| `AD_NETBIOS` | `EXAMPLE` |
| `AD_DOMAIN_DN` | `DC=example,DC=internal` |
| `AD_BASE_DN` | `OU=EXAMPLE,DC=example,DC=internal` |
| `AD_GROUP_BASE_DN` | `OU=Groups,OU=EXAMPLE,DC=example,DC=internal` |
| `AD_BIND_DN` | `CN=ldap.svc,OU=Service Accounts,OU=EXAMPLE,DC=example,DC=internal` |
| `ADCS_URL` | `https://dc01.example.internal/certsrv` |

Uncomment the matching line in `config.env` to override any of them. An
environment variable set at run time wins over the file:

```bash
AD_DC_HOST=dc02.example.internal ./bootstrap.py
```

`bootstrap.py` is the only implementation of these rules. `lib/config.sh` evals
`bootstrap.py --export`, so the shell scripts cannot drift from the templates.

```bash
./bootstrap.py --list      # what would be rendered
./bootstrap.py --export    # export lines for a shell to eval
./bootstrap.py --json      # the fully resolved config
```

PowerShell reads `config.env` through `ad/lib/Get-RepoConfig.ps1`, which repeats
the derivation rules — Windows hosts usually have no Python. If you change a rule
in `bootstrap.py`, change it there too.

## Templates

YAML carrying site values is stored as `*.yaml.tmpl` and rendered with Jinja2.
`bootstrap.py` walks the repo, renders every `*.tmpl` into `rendered/` mirroring
the source layout, and the deploy scripts apply from there — so nothing
site-specific ever lands in a tracked path.

Rendering is strict in both directions: an undefined name raises `UndefinedError`,
and a defined-but-empty value fails when the template marks it `| required(...)`.
Neither silently produces a blank.

```jinja
url: {{ ADCS_URL }}
caBundle: {{ ADCS_CA_BUNDLE_B64 | required("is AD_CA_CERT_FILE present?") }}
```

The CA certificate is read from `AD_CA_CERT_FILE` and base64-encoded at render
time, so it never has to be committed.

## Layout

```
config.env.example              template for your local config.env
bootstrap.py                    renders every *.tmpl; single source of derived values
lib/config.sh                   exposes those values to the shell scripts
secrets/                        CA certificate and anything else private
rendered/                       generated manifests and values files

ad/scripts/                     Active Directory (PowerShell)
okd/scripts/                    OKD cluster setup - LDAP auth, Ceph CSI
helm/certificate-manager/       cert-manager and the AD CS issuer
helm/kasm-workspaces/           Kasm Workspaces
```

## Order of operations

```bash
./bootstrap.py                                       # render templates
okd/scripts/setup-ceph-csi.sh                        # storage classes
okd/scripts/setup-okd-ldap-auth.sh                   # AD login + group RBAC
helm/certificate-manager/scripts/deploy-cert-man.sh  # cert-manager + ADCS issuer
helm/certificate-manager/scripts/deploy-adcs-clusterissuer.sh
helm/kasm-workspaces/scripts/deploy-kasm-helm.sh
```

`deploy-adcs-clusterissuer.sh` needs the **Certification Authority Web
Enrollment** role service (`/certsrv`) on the CA, reachable over HTTPS. The
issuer will not become ready without it.
