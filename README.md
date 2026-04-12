# ssl-wizard.sh

Interactive SSL certificate creation wizard.
Supports Let's Encrypt via acme.sh, self-signed via openssl, and a standalone key generator.

---

## Requirements

| Tool | When needed | Install |
|---|---|---|
| `bash` 4+ | always | — |
| `openssl` | always | `apt install openssl` |
| `curl` | always (acme.sh install) | `apt install curl` |
| `acme.sh` | Let's Encrypt methods | auto-installed by wizard |
| `socat` | LE standalone mode only | `apt install socat` |
| `nginx` | LE nginx mode only | `apt install nginx` |

> The wizard checks all dependencies at startup and tells you what is missing before doing anything.

---

## Usage

```bash
chmod +x ssl-wizard.sh
sudo ./ssl-wizard.sh
```

---

## Navigation

- Type a number and press Enter to select an option
- Type `b` and press Enter at any prompt to go back to the previous step
- Step 1 (method selection) has no back — type `0` to exit

---

## Steps

The wizard walks through 5 steps for certificate methods, or 3 steps for the key generator.

---

### Step 1 — Method

**Let's Encrypt** (free, publicly trusted, 90-day certificates):

| # | Method | Requirements |
|---|---|---|
| 1 | Standalone | `socat`, port 80 must be free |
| 2 | Webroot | nginx running, serving `/.well-known/acme-challenge/` |
| 3 | nginx mode | nginx installed, acme.sh reloads it automatically |
| 4 | Wildcard — manual DNS | access to your DNS panel to add a TXT record |
| 5 | Wildcard — Cloudflare | Cloudflare API token |

> Let's Encrypt does not issue certificates for IP addresses. Use a domain name.

**Self-signed** (openssl, no CA trust, suitable for internal/dev use):

| # | Method | Notes |
|---|---|---|
| 6 | RSA | choose key size: 2048 / 3072 / 4096 |
| 7 | ECDSA | choose curve: P-256 / P-384 / P-521 |
| 8 | Ed25519 | modern algorithm, fixed key size |
| 9 | Local CA + signed cert | sign multiple certs with one CA |

> Self-signed certificates trigger a browser warning on public sites.
> For IP addresses, use self-signed — the IP is written as `IP.1` in the SAN automatically.

**Utilities:**

| # | Method | Notes |
|---|---|---|
| 10 | Key / random generator | generate keys or random byte strings |

---

### Step 2 — Output format

| # | Format | Files produced |
|---|---|---|
| 1 | PEM | `<domain>.crt` + `<domain>.key` |
| 2 | PEM bundle | `<domain>_fullchain.pem` + `<domain>_privkey.pem` |
| 3 | PKCS#12 | `<domain>.p12` (no password by default) |

> Let's Encrypt always outputs PEM. The format choice for LE methods affects file naming only.

---

### Step 3 — Certificate details

The wizard asks only for fields relevant to the chosen method:

| Field | Asked for |
|---|---|
| Domain or IP | all methods |
| Contact email | Let's Encrypt only |
| Country, state, city, org, department | self-signed only |
| Validity in days | self-signed only |
| RSA key size | RSA methods |
| ECDSA curve | ECDSA methods |
| Webroot path | LE webroot method |
| Cloudflare API token | LE Cloudflare wildcard |
| CA key passphrase (yes / no) | Local CA method only |

---

### Step 4 — Output directory

Choose where certificate files are saved:

- **Same directory as the script** — files appear next to `ssl-wizard.sh`
- **Custom path** — enter any absolute path; the directory is created if it does not exist

---

### Step 5 — Summary

Review all selected parameters before execution.
Confirm with `y`, go back with `b`, or press Enter / any other key to cancel.

---

## Key generator (method 10)

Separate flow — no certificate is created, only a key or random value.

### RSA

Generates a private key using `openssl genpkey`.
Choose key size: `2048` / `3072` / `4096` bits.
Output: `key_rsa<bits>.pem`
The corresponding public key is printed to the terminal after generation.

### ECDSA

Generates a private key using `openssl genpkey`.
Choose curve: `P-256` (prime256v1) / `P-384` (secp384r1) / `P-521` (secp521r1).
Output: `key_ecdsa_<curve>.pem`
The corresponding public key is printed to the terminal after generation.

### Ed25519

Generates a private key using `openssl genpkey -algorithm Ed25519`.
No parameters to choose — fixed algorithm.
Output: `key_ed25519.pem`
The corresponding public key is printed to the terminal after generation.

### Random bytes

Generates a random byte string using `openssl rand`.
Choose format: `base64` or `hex`.
Choose length: number of input bytes (e.g. `48` → 64-character base64 string).
Output: printed to terminal + saved to `rand_<bytes>bytes.<format>`.

Example equivalent commands:
```bash
openssl rand -base64 48
openssl rand -hex 32
```

---

## Output files

### Let's Encrypt

acme.sh stores certificates in `~/.acme.sh/<domain>/`.
The wizard copies them to your chosen output directory:

```
<outdir>/
  <domain>_fullchain.pem    ← use as ssl_certificate
  <domain>_privkey.pem      ← use as ssl_certificate_key
  <domain>_chain.pem        ← CA chain (for ssl_trusted_certificate)
  <domain>.p12              ← only if PKCS#12 format selected
```

### Self-signed (RSA / ECDSA / Ed25519)

```
<outdir>/
  <domain>.crt              ← use as ssl_certificate
  <domain>.key              ← use as ssl_certificate_key
  openssl.cnf               ← generated config with SAN
  <domain>.p12              ← only if PKCS#12 format selected
```

### Local CA

```
<outdir>/
  ca.crt                    ← distribute to client trust stores
  ca.key                    ← keep safe, needed to sign future certs
  <domain>.crt
  <domain>.key
  <domain>.csr
  openssl.cnf
  <domain>.p12              ← only if PKCS#12 format selected
```

---

## nginx directives

After every successful certificate creation the wizard prints ready-to-use nginx directives:

```nginx
ssl_certificate     /path/to/<domain>.crt;
ssl_certificate_key /path/to/<domain>.key;
```

Copy and paste them into your `server {}` block.

---

## Let's Encrypt — Cloudflare wildcard

The wizard uses the `dns_cf` plugin built into acme.sh.
You need a **Cloudflare API token** (not the global API key).

How to create a token:
1. Cloudflare dashboard → My Profile → API Tokens
2. Create Token → Edit zone DNS (use template)
3. Set Zone Resources to your domain
4. Copy the token and paste it when the wizard asks

The token is passed as the `CF_Token` environment variable — it is not stored anywhere by the wizard.

---

## Let's Encrypt — manual DNS wildcard

When you select method 4, acme.sh outputs a TXT record value and pauses.
Add the record to your DNS:

| Field | Value |
|---|---|
| Type | TXT |
| Name | `_acme-challenge.<domain>` |
| Value | shown by acme.sh |

After the DNS record propagates, complete the issuance by running:

```bash
~/.acme.sh/acme.sh --renew \
  --domain <domain> \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please
```

---

## Local CA — trust store setup

After using method 9, distribute `ca.crt` to all clients that need to trust your internal certificates.

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

## Let's Encrypt — auto-renewal

acme.sh sets up a cron job automatically during installation:

```
0 0 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null
```

To reload nginx after renewal, install a deploy hook:

```bash
~/.acme.sh/acme.sh --install-cert \
  --domain <domain> \
  --cert-file      /etc/ssl/custom/<domain>.crt \
  --key-file       /etc/ssl/custom/<domain>.key \
  --fullchain-file /etc/ssl/custom/<domain>_fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

Test that renewal works without making changes:

```bash
~/.acme.sh/acme.sh --renew --domain <domain> --force --test
```

---

## Passphrase

| Method | Passphrase behaviour |
|---|---|
| RSA self-signed | always without passphrase |
| ECDSA self-signed | always without passphrase |
| Ed25519 self-signed | always without passphrase |
| Local CA key | choose at step 3: with or without |
| Server key in Local CA | always without passphrase |
| Key generator | always without passphrase |

Keys without a passphrase can be loaded by nginx automatically on startup.
Keys with a passphrase require manual entry every time the service starts.

---

## Notes

- The script must be run as root (`sudo`).
- acme.sh is installed to `~/.acme.sh/` of the root user when run with sudo.
- For IP addresses, self-signed methods only. The IP is placed in the `IP.1` SAN field automatically — no manual editing of `openssl.cnf` needed.
- PKCS#12 files are exported without a password by default. To add one, edit the `maybe_convert_p12` function in the script and change `-passout pass:` to `-passout pass:yourpassword`.
- The key generator does not create certificates — use it separately when you only need a key or a random secret.
