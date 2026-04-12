# ssl-wizard.sh

Interactive SSL certificate creation wizard.
Covers Let's Encrypt via acme.sh, self-signed via openssl, and a standalone key / random string generator.

---

## Requirements

| Tool | When needed | Install |
|---|---|---|
| `bash` 4+ | always | — |
| `openssl` | always | `apt install openssl` |
| `curl` | acme.sh install | `apt install curl` |
| `acme.sh` | Let's Encrypt methods | auto-installed by wizard |
| `socat` | LE standalone mode | `apt install socat` |
| `nginx` | LE nginx mode | `apt install nginx` |

The wizard checks all of these at startup and reports what is missing before doing anything.
If acme.sh is not found, it offers to install it automatically.

---

## Usage

```bash
chmod +x ssl-wizard.sh
sudo ./ssl-wizard.sh
```

---

## Navigation

| Input | Effect |
|---|---|
| number + Enter | select option |
| `b` + Enter | go back to previous step |
| `0` + Enter | exit (step 1 only) |

Step 1 has no back — type `0` to exit instead.

---

## Methods

### Step 1 — choose a method

**Let's Encrypt** — free, publicly trusted, valid 90 days, requires a real domain (not an IP):

| # | Method | What happens |
|---|---|---|
| 1 | Standalone | acme.sh binds port 80 directly. Requires `socat`. nginx must not be running on port 80. |
| 2 | Webroot | nginx stays running. acme.sh writes a challenge file to the webroot you specify. |
| 3 | nginx mode | acme.sh handles nginx reload automatically. nginx must be installed. |
| 4 | Wildcard — manual DNS | acme.sh outputs a TXT record value. You add it to DNS manually, then complete issuance. |
| 5 | Wildcard — Cloudflare | Fully automated via Cloudflare API token. No manual DNS edits needed. |

**Self-signed** — openssl, no CA trust, suitable for internal services and development:

| # | Method | What happens |
|---|---|---|
| 6 | Simple — no passphrase | Three commands: `genrsa` → `req` → `x509`. Minimal input, no config file. |
| 7 | RSA | Full self-signed with SAN config. Choose key size. |
| 8 | ECDSA | Full self-signed with SAN config. Choose curve. |
| 9 | Ed25519 | Full self-signed with SAN config. Fixed algorithm. |
| 10 | Local CA + signed | Create a root CA, then sign a server cert with it. Install the CA once on clients — no more browser warnings for any cert signed by it. |

**Utilities:**

| # | Method | What happens |
|---|---|---|
| 11 | Key / random generator | Generate a standalone key or random byte string. No certificate is created. |

---

## Steps walkthrough

### Let's Encrypt methods (1–5)

**Steps: Method → Format → Variables → Output dir → Summary**

Variables asked:
- Domain name (no www)
- Contact email — used by acme.sh to register an ACME account
- Webroot path — only for method 2
- Cloudflare API token — only for method 5

Output format choice (step 2) affects file naming only — acme.sh always writes PEM internally.

---

### Simple self-signed (method 6)

**Steps: Method → Variables → Output dir → Summary**

No format selection, no openssl.cnf generated.

Variables asked:
- RSA key size: `2048` / `3072` / `4096`
- Domain or IP address
- Validity in days (default: `365`)

Runs exactly these three commands:
```bash
openssl genrsa -out privkey.pem <bits>
openssl req -new -key privkey.pem -out cert.csr -subj "/CN=<domain>"
openssl x509 -req -days <days> -in cert.csr -signkey privkey.pem -out fullchain.pem
```

---

### RSA / ECDSA / Ed25519 self-signed (methods 7–9)

**Steps: Method → Format → Variables → Output dir → Summary**

Variables asked:
- Domain or IP address
- Country code (2 letters)
- State / Region
- City
- Organisation name
- Department / Unit
- Validity in days (default: `398`)
- RSA key size — method 7 only: `2048` / `3072` / `4096`
- ECDSA curve — method 8 only: `P-256` / `P-384` / `P-521`

Generates `openssl.cnf` with Subject Alternative Names automatically.
For IP addresses the SAN is written as `IP.1` — no manual editing needed.

---

### Local CA + signed cert (method 10)

**Steps: Method → Format → Variables → Output dir → Summary**

Same variables as RSA/ECDSA/Ed25519 plus:
- CA key passphrase: with or without

Three internal steps:
1. Generate root CA key and self-signed CA certificate (valid 10 years)
2. Generate server key and CSR
3. Sign server CSR with the CA

After completion the wizard prints instructions for installing `ca.crt` into trust stores on Linux, Windows, and macOS.

---

### Key / random generator (method 11)

**Steps: Method → Algorithm → Output dir → Summary**

No certificate is created. Choose an algorithm:

| Algorithm | Parameters | Output file |
|---|---|---|
| RSA | key size: 2048 / 3072 / 4096 | `key_rsa<bits>.pem` |
| ECDSA | curve: P-256 / P-384 / P-521 | `key_ecdsa_<curve>.pem` |
| Ed25519 | none | `key_ed25519.pem` |
| Random bytes | format: base64 / hex; length in bytes | `rand_<n>bytes.<format>` |

For RSA, ECDSA, and Ed25519 the public key is also printed to the terminal after generation.
For random bytes the string is printed to the terminal and saved to the output file.

Random bytes examples:
```bash
openssl rand -base64 48   # 48 bytes → 64-char base64 string
openssl rand -hex 32      # 32 bytes → 64-char hex string
```

---

## Output files

### Let's Encrypt (methods 1–5)

acme.sh stores certificates in `~/.acme.sh/<domain>/`.
The wizard copies them to your chosen output directory.

```
<outdir>/
  <domain>_fullchain.pem    ← ssl_certificate
  <domain>_privkey.pem      ← ssl_certificate_key
  <domain>_chain.pem        ← ssl_trusted_certificate (if available)
  <domain>.p12              ← only if PKCS#12 format selected
```

---

### Simple self-signed (method 6)

```
<outdir>/
  privkey.pem               ← ssl_certificate_key
  cert.csr                  ← intermediate file, can be deleted after
  fullchain.pem             ← ssl_certificate
```

---

### RSA / ECDSA / Ed25519 self-signed (methods 7–9)

```
<outdir>/
  <domain>.key              ← ssl_certificate_key
  <domain>.crt              ← ssl_certificate
  openssl.cnf               ← generated SAN config
  <domain>.p12              ← only if PKCS#12 format selected
```

---

### Local CA (method 10)

```
<outdir>/
  ca.key                    ← keep safe, needed to sign future certs
  ca.crt                    ← distribute to client trust stores
  <domain>.key              ← ssl_certificate_key
  <domain>.csr              ← intermediate file, can be deleted after
  <domain>.crt              ← ssl_certificate
  openssl.cnf               ← generated SAN config
  <domain>.p12              ← only if PKCS#12 format selected
```

---

## nginx directives

After every successful certificate creation the wizard prints ready-to-paste nginx lines:

```nginx
ssl_certificate     /path/to/cert;
ssl_certificate_key /path/to/key;
```

---

## Output formats

| # | Format | Files |
|---|---|---|
| 1 | PEM | `<domain>.crt` + `<domain>.key` |
| 2 | PEM bundle | `<domain>_fullchain.pem` + `<domain>_privkey.pem` |
| 3 | PKCS#12 | `<domain>.p12` — no password by default |

> Not available for method 6 (Simple) and method 11 (Key generator).

---

## Passphrase behaviour

| Method | CA key | Server key |
|---|---|---|
| Simple (6) | — | no passphrase |
| RSA (7) | — | no passphrase |
| ECDSA (8) | — | no passphrase |
| Ed25519 (9) | — | no passphrase |
| Local CA (10) | your choice at step 3 | no passphrase |
| Key generator (11) | — | no passphrase |

Keys without a passphrase load automatically when nginx starts.
A CA key with a passphrase must be entered manually each time you sign a new certificate.

---

## Let's Encrypt — Cloudflare wildcard (method 5)

Uses the `dns_cf` plugin built into acme.sh. Requires a Cloudflare **API token** (not the global API key).

How to create a token:
1. Cloudflare dashboard → My Profile → API Tokens
2. Create Token → Edit zone DNS (template)
3. Zone Resources → your domain
4. Copy the token and paste it when the wizard asks

The token is passed as the `CF_Token` environment variable and is not stored anywhere.

---

## Let's Encrypt — manual DNS wildcard (method 4)

acme.sh outputs a TXT record value and pauses. Add the record to your DNS:

| Field | Value |
|---|---|
| Type | `TXT` |
| Name | `_acme-challenge.<domain>` |
| Value | shown by acme.sh |

After the record propagates, complete issuance by running:

```bash
~/.acme.sh/acme.sh --renew \
  --domain <domain> \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please
```

---

## Let's Encrypt — auto-renewal

acme.sh installs a cron job automatically during setup:

```
0 0 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null
```

To reload nginx automatically after each renewal, run once after issuance:

```bash
~/.acme.sh/acme.sh --install-cert \
  --domain <domain> \
  --cert-file      /etc/ssl/custom/<domain>.crt \
  --key-file       /etc/ssl/custom/<domain>.key \
  --fullchain-file /etc/ssl/custom/<domain>_fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

Test renewal without making changes:

```bash
~/.acme.sh/acme.sh --renew --domain <domain> --force --test
```

---

## Local CA — install into trust stores

After running method 10, distribute `ca.crt` to all clients:

**Debian / Ubuntu**
```bash
cp ca.crt /usr/local/share/ca-certificates/my-ca.crt
update-ca-certificates
```

**RHEL / Rocky / CentOS**
```bash
cp ca.crt /etc/pki/ca-trust/source/anchors/my-ca.crt
update-ca-trust
```

**Windows — PowerShell (run as Administrator)**
```powershell
Import-Certificate -FilePath "ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

**macOS**
```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain ca.crt
```

---

## Notes

- The script must be run as root (`sudo`).
- acme.sh is installed to `~/.acme.sh/` of the user running the script (root when using sudo).
- Let's Encrypt does not issue certificates for bare IP addresses — use self-signed methods for IP-only servers.
- For IP addresses, the wizard automatically places the IP under `IP.1` in the SAN field instead of `DNS.1`.
- PKCS#12 files are exported without a password. To add one, edit the `maybe_convert_p12` function and change `-passout pass:` to `-passout pass:yourpassword`.
- Method 6 (Simple) does not include Subject Alternative Names — modern browsers may show a warning. Use methods 7–9 for anything that needs SAN support.
