# ssl-wizard.sh

Interactive SSL certificate creation wizard with a TUI menu.
Supports Let's Encrypt (certbot) and self-signed (openssl) certificates.

---

## Requirements

| Tool | Required for |
|---|---|
| `bash` 4+ | always |
| `openssl` | self-signed methods |
| `certbot` | Let's Encrypt methods |
| `pip` | Let's Encrypt wildcard via Cloudflare |

The script must be run as **root** (`sudo`).

---

## Usage

```bash
chmod +x ssl-wizard.sh
sudo ./ssl-wizard.sh
```

---

## What it does

The wizard walks you through 4 steps:

**Step 1 — Method**
Choose how the certificate will be created:

| # | Method | Notes |
|---|---|---|
| 1 | Let's Encrypt — nginx plugin | nginx auto-configured, stays running |
| 2 | Let's Encrypt — webroot | nginx stays running, serves challenge path |
| 3 | Let's Encrypt — standalone | nginx stopped briefly during issuance |
| 4 | Let's Encrypt — wildcard, manual DNS | you add a TXT record in your DNS panel |
| 5 | Let's Encrypt — wildcard, Cloudflare | automated via Cloudflare API key |
| 6 | Self-signed — RSA 4096 | widest compatibility |
| 7 | Self-signed — ECDSA P-384 | smaller key, faster handshake |
| 8 | Self-signed — Local CA + signed cert | install CA once, no browser warnings for all internal certs |

**Step 2 — Output format**

| # | Format | File(s) |
|---|---|---|
| 1 | PEM | `<domain>.crt` + `<domain>.key` |
| 2 | PEM bundle | `fullchain.pem` + `privkey.pem` |
| 3 | PKCS#12 | `<domain>.p12` (no password by default) |

> Let's Encrypt always outputs PEM — format choice affects file naming only.

**Step 3 — Variables**
The wizard asks only for what the chosen method actually needs:

- Domain name
- Contact email *(Let's Encrypt only)*
- Country, state, city, organisation, department *(self-signed only)*
- Validity in days *(self-signed only)*
- Webroot path *(webroot method only)*
- Cloudflare credentials file path *(Cloudflare method only)*

**Step 4 — Output directory**
Choose where the certificate files will be saved:
- Same directory as the script
- Custom path (enter manually)

After that a summary is shown. Confirm to execute.

---

## Output files

### Let's Encrypt
certbot always writes to `/etc/letsencrypt/live/<domain>/`.
If you chose a different output directory, the wizard copies the files there.

```
<outdir>/
  <domain>_fullchain.pem
  <domain>_privkey.pem
  <domain>_chain.pem
  <domain>.p12          ← only if PKCS#12 format was selected
```

### Self-signed (RSA / ECDSA)
```
<outdir>/
  <domain>.crt
  <domain>.key
  openssl.cnf           ← generated config with SAN
  <domain>.p12          ← only if PKCS#12 format was selected
```

### Self-signed — Local CA
```
<outdir>/
  ca.crt                ← distribute this to client trust stores
  ca.key                ← keep safe, needed to sign future certs
  <domain>.crt
  <domain>.key
  <domain>.csr
  openssl.cnf
  <domain>.p12          ← only if PKCS#12 format was selected
```

---

## nginx directives after issuance

```nginx
ssl_certificate     /path/to/<domain>.crt;      # or fullchain.pem
ssl_certificate_key /path/to/<domain>.key;      # or privkey.pem
```

---

## Local CA — trust store setup

After running method 8, distribute `ca.crt` to clients so browsers show a green padlock for all certs signed by that CA.

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

**Windows (PowerShell, run as Administrator)**
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

Let's Encrypt certificates expire in **90 days**. Set up automatic renewal.

**cron** — add to `/etc/cron.d/certbot`:
```
0 3,15 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
```

**systemd timer** — create `/etc/systemd/system/certbot-renew.timer`:
```ini
[Timer]
OnBootSec=1min
OnUnitActiveSec=12h
RandomizedDelaySec=3h
Persistent=true
```
Then enable:
```bash
systemctl enable --now certbot-renew.timer
```

Test renewal without making changes:
```bash
certbot renew --dry-run
```

---

## Notes

- Self-signed certificates will show a browser warning on public sites. Use Let's Encrypt for anything public-facing.
- For IP addresses (no domain) only self-signed methods work. In `openssl.cnf` the IP must be listed as `IP.1 = x.x.x.x` under `[alt_names]`, not as `DNS.1`.
- The PKCS#12 file is exported without a password by default. Add `-passout pass:yourpassword` to the `openssl pkcs12` command inside the script if you need one.
- The script does not set up auto-renewal — do that separately using the cron or systemd instructions above.
