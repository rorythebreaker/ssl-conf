# ssl-wizard

An interactive wizard for creating SSL certificates. It asks simple questions step by step and runs the necessary commands for you.

It can:

- obtain free **Let's Encrypt** certificates;
- create **self-signed** certificates and your own certificate authority (CA);
- generate standalone keys and random strings.

| System | File | Let's Encrypt client |
|---|---|---|
| Linux | `ssl-wizard.sh` | acme.sh |
| Windows | `ssl-wizard.ps1` (started via `ssl-wizard.cmd`) | Posh-ACME |

The interface is available in **English and Russian**.

---

## Running

**Linux**

```bash
chmod +x ssl-wizard.sh
sudo ./ssl-wizard.sh
```

**Windows** — double-click `ssl-wizard.cmd`. Or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\ssl-wizard.ps1
```

On Windows, administrator rights are needed only for the "Standalone" method (it listens on port 80).

### The `ssl-wizard` command

On first run the wizard adds itself to `PATH`, so afterwards it starts from any folder:

```bash
sudo ssl-wizard        # Linux
```

```powershell
ssl-wizard             # Windows, in a new terminal window
```

| System | What is installed | PATH change |
|---|---|---|
| Linux | a copy of the script at `/usr/local/bin/ssl-wizard` (`/usr/bin/ssl-wizard` if sudo's PATH has no `/usr/local/bin`) | none needed |
| Windows | a launcher at `%LOCALAPPDATA%\ssl-wizard\bin\ssl-wizard.cmd` and a copy of the script next to it | `%LOCALAPPDATA%\ssl-wizard\bin` is appended to the user's `PATH` |

The command runs a copy, so the downloaded files can be moved or deleted. Running a newer `ssl-wizard.sh` / `ssl-wizard.ps1` refreshes the copy.

To keep the wizard off `PATH`, set `SSLWIZ_NO_PATH=1` before running it. To undo: delete the file on Linux; on Windows remove the `bin` folder from the user `PATH` (Settings → Environment Variables).

---

## Language

On first run the wizard asks which language to use and remembers the answer. To switch later, choose **Язык / Language** in the main menu.

You can also set the language without the prompt:

| System | How | Where the choice is stored |
|---|---|---|
| Linux | `sudo SSLWIZ_LANG=en ./ssl-wizard.sh` | `~/.ssl-wizard-lang` |
| Windows | `ssl-wizard.cmd -Lang en` or the `SSLWIZ_LANG` environment variable | `%LOCALAPPDATA%\ssl-wizard\lang.txt` |

Accepted values are `en` and `ru`.

---

## Components install themselves

On first run the wizard checks what is installed and adds anything missing without asking.

| System | What is installed | Where |
|---|---|---|
| Linux | `openssl`, `curl`, `socat` — via the package manager (apt, dnf, yum, pacman, apk, zypper); `acme.sh` — via its official installer | system-wide; acme.sh goes to `~/.acme.sh/` |
| Windows | OpenSSL (portable build, verified by SHA-256), the Posh-ACME module | `%LOCALAPPDATA%\ssl-wizard` |

If OpenSSL or Posh-ACME is already present on the system, the wizard uses it and downloads nothing.
On Windows the components folder can be changed with the `SSLWIZ_HOME` environment variable.

If something cannot be installed (for example, there is no internet connection), the wizard says so. Self-signed certificates need only OpenSSL. The installation log on Linux is `/tmp/ssl-wizard-install.log`.

The wizard does not install `nginx`: the "Via nginx" method is meant for a server that is already set up.

---

## Navigation

| Input | Effect |
|---|---|
| number + Enter | select an option |
| Enter | keep the value shown in square brackets |
| `0` + Enter | **back** — to the previous step or question |
| `0` at the first step | exit |

Files are saved to the folder you started the wizard from, or to any other folder you type in. Files that would be overwritten are [backed up](#backups) first.

You can go back from any step, including the review screen. Answers you already gave are kept and offered as defaults.

If certificate creation fails, the wizard stays open: you can go back, fix the details and try again.

---

## Methods

### Let's Encrypt — free, trusted by browsers

Requires your own domain that already points to this server. The certificate is valid for 90 days. Not issued for IP addresses.

| Method | When to choose it |
|---|---|
| Standalone | Port 80 is free, no web server is running. |
| Via site folder | The site is already running and cannot be stopped. The wizard places a verification file in the site folder. |
| Via nginx *(Linux only)* | nginx is installed and serves this domain. |
| Wildcard, manual DNS | You need a certificate for `*.domain`. The wizard shows a TXT record; you add it to DNS and press Enter. |
| Wildcard, Cloudflare | Same, but the record is added automatically using a Cloudflare API token. |

### Self-signed — for testing and internal networks

No domain required; an IP address works too. Browsers will show a warning.

| Method | When to choose it |
|---|---|
| Quick | You need a certificate right now: 3 questions. No SAN — modern browsers may reject it. |
| RSA | Works everywhere. Pick this if unsure. |
| ECDSA | Shorter, faster key for modern systems. |
| Ed25519 | The newest algorithm. Browsers do not support such certificates. |
| Own authority (CA) | Creates your own CA and a certificate signed by it. Install `ca.crt` on your computers once and the warnings disappear. |

### Other

| Method | What it does |
|---|---|
| Key or password | Creates only a key (RSA, ECDSA, Ed25519) or a random string (base64 / hex). No certificate is created. |
| Scan a folder | Finds existing certificates (in subfolders too, if you want), shows when they expire and puts them on auto-renewal. See [Scanning a folder](#scanning-a-folder). |
| Auto-renewal | The certificates on auto-renewal; check them all or renew one right now. See [The auto-renewal list](#the-auto-renewal-list). |
| Settings | Port 80 auto-fix and notifications. See [Settings](#settings). |
| Язык / Language | Switches the interface language. |

---

## File formats

| Option | Files |
|---|---|
| Regular | `<domain>.crt` + `<domain>.key` |
| fullchain + privkey | `<domain>_fullchain.pem` + `<domain>_privkey.pem` |
| PKCS#12 | `<domain>.crt` + `<domain>.key` + `<domain>.p12` (no password) |

The contents of `.crt` and `_fullchain.pem` are identical — only the names differ. For your own CA, `_fullchain.pem` contains the server certificate followed by the CA certificate.

Additional files that appear in the folder:

| Method | Files |
|---|---|
| Let's Encrypt | `<domain>_chain.pem` — the issuing authority's chain |
| Quick | `privkey.pem`, `cert.csr`, `fullchain.pem` (no format choice) |
| RSA / ECDSA / Ed25519 | `openssl.cnf` — the settings the certificate was created with |
| Own authority (CA) | `ca.key` (keep secret), `ca.crt` (distribute to clients), `<domain>.csr`, `openssl.cnf` |
| Key or password | `key_rsa<bits>.pem`, `key_ecdsa_<curve>.pem`, `key_ed25519.pem` or `rand_<n>bytes.<format>` |

If the chosen folder already contains `ca.key` and `ca.crt`, the wizard does not create a new CA and signs the certificate with the existing one.

Access to key files is restricted: `chmod 600` on Linux; owner, Administrators and SYSTEM only on Windows.

After creation the wizard prints ready-to-paste nginx lines:

```nginx
ssl_certificate     /path/to/cert;
ssl_certificate_key /path/to/key;
```

---

## Cloudflare token

You need an **API token**, not the Global API Key:

1. Cloudflare → My Profile → API Tokens
2. Create Token → "Edit zone DNS" template
3. Zone Resources → your domain
4. Copy the token and paste it when the wizard asks

---

## Let's Encrypt renewal

### Linux

After a certificate is issued (and for every certificate added by [folder scan](#scanning-a-folder)) the wizard puts it on auto-renewal: every day at 03:30 it runs `ssl-wizard --renew`, through `/etc/cron.d/ssl-wizard` or, on systems without cron, through the `ssl-wizard-renew.timer` systemd timer. When a certificate is due, it is renewed and the files in the output folder are updated — same names, same format (including `.p12`).

- The "Wildcard, manual DNS" method is not renewed automatically: the TXT record has to be added by hand. Run the wizard again every 2 months.
- If the "Standalone" check fails, see [Port 80 auto-fix](#port-80-auto-fix). If renewal fails, the wizard [notifies you](#notifications).

| File | What it is |
|---|---|
| `/etc/ssl-wizard/renew.d/*.conf` | one file per certificate: what it is and which files to update |
| `/etc/ssl-wizard/after-renew.sh` | your own script, run after every successful renewal — for example `systemctl reload nginx` |
| `/var/log/ssl-wizard-renew.log` | log: when checks ran, what was renewed, any errors |

Check renewal manually, or turn it off:

```bash
sudo ssl-wizard --renew && tail -n 5 /var/log/ssl-wizard-renew.log
sudo rm /etc/cron.d/ssl-wizard                               # cron
sudo systemctl disable --now ssl-wizard-renew.timer          # systemd
```

### Windows

After a certificate is issued, the wizard creates a scheduled task named `ssl-wizard-renew`. Every day at 03:30 it checks the expiry date and, when the certificate is due, renews it and updates the files in the same folder and in the same format (including `.p12`).

- The task runs as the user who ran the wizard, and only while that user is logged on. If the computer was off or the user was not logged on, the check runs at the next logon.
- The "Wildcard, manual DNS" method is not renewed automatically: the TXT record has to be added by hand. Run the wizard again every 2 months.
- The "Standalone" method briefly listens on port 80 during renewal. If that check fails, see [Port 80 auto-fix](#port-80-auto-fix). If renewal fails, the wizard [notifies you](#notifications).
- Your web server will not pick up the new files by itself. Put your own script at `%LOCALAPPDATA%\ssl-wizard\after-renew.ps1` — it runs after every successful renewal. Example: `Restart-Service nginx`.

Everything renewal needs lives in `%LOCALAPPDATA%\ssl-wizard`:

| File | What it is |
|---|---|
| `renew.log` | log: when checks ran, what was renewed, any errors |
| `renew.json` | list of certificates and the folders they are saved to |
| `ssl-wizard.ps1` | the copy of the wizard that the task runs |

Certificates added by [folder scan](#scanning-a-folder) are renewed by the same task.

Check renewal manually:

```powershell
Start-ScheduledTask -TaskName ssl-wizard-renew
Get-Content $env:LOCALAPPDATA\ssl-wizard\renew.log -Tail 5
```

Turn auto-renewal off:

```powershell
Unregister-ScheduledTask -TaskName ssl-wizard-renew -Confirm:$false
```

### The auto-renewal list

**Auto-renewal** in the main menu lists every certificate the daily check takes care of — issued by the wizard or added by a folder scan. Soonest expiry comes first. For each certificate you see:

- name and kind (Let's Encrypt and how the domain is checked, self-signed, signed by your own CA);
- expiry date, days left, and the date from which it will be renewed;
- the file it lives in, and how many more files are updated with it.

Below the list: whether the daily check is set up, and where the renewal log is.

| Action | What it does |
|---|---|
| Check all now | exactly what the daily check does: renews the certificates that are due and skips the rest |
| Renew a certificate | renews the certificate you choose right away, whatever its expiry date — same files, same kind, with a backup of the old files |
| Remove from auto-renewal | the certificate is no longer renewed; its files stay where they are. A folder scan can add it back |

Everything a manual run does is shown on screen and written to the renewal log, just like the daily check — including the [port 80 auto-fix](#port-80-auto-fix). Notifications are not sent for manual runs: you see the result yourself.

---

## Settings

**Settings** in the main menu holds two groups of options. Both are off / empty until you turn them on.

| Option | What it allows |
|---|---|
| Stop the service | stop the service holding port 80 during a "Standalone" check, and start it again afterwards |
| Open the firewall | open port 80 in the firewall during the check, and close it afterwards |
| Telegram / E-mail / Webhook | where to send a message when an automatic renewal fails |
| Test notifications | sends a test message to every channel that is set up |

| System | Where settings are kept |
|---|---|
| Linux | `/etc/ssl-wizard/settings.conf`, readable by root only |
| Windows | `%LOCALAPPDATA%\ssl-wizard\settings.json`; tokens and passwords are encrypted for the current Windows user |

### Port 80 auto-fix

The "Standalone" method needs port 80 to be free on this server and reachable from the internet. When Let's Encrypt cannot check the domain this way — on first issue or on renewal — the wizard does not give up at once:

1. **Finds out why.** Who holds port 80 (a service, a Docker container, or some other process), and whether the firewall closes it: ufw, firewalld or iptables on Linux, Windows Firewall on Windows.
2. **Fixes what the settings allow.**
   - Port held by a service → the service is stopped (on Linux a systemd service or a Docker container; on Windows a service, including IIS).
   - Port closed by the firewall → port 80 is opened: ufw rule, firewalld runtime rule, iptables rule, or a temporary Windows Firewall rule.
3. **Retries the check once.**
4. **Puts everything back**, whether the retry worked or not: the service or container is started again, the firewall rule is removed.

What the wizard does not do, even with both options on:
- It does not stop a process that is neither a service nor a container: there would be no reliable way to start it again.
- It does not change firewalls outside the server (cloud security groups, a router, the provider). When nothing on the server blocks port 80, the wizard says that the cause is most likely there, or that the domain points to another address.

Everything found and done is shown on screen, written to the renewal log, and included in the notification.

### Notifications

When an automatic renewal fails — including after the port 80 auto-fix — the wizard sends a message to every channel set up in **Settings**. The message says which certificate failed and on which server, how many days are left, and what happened. Failed checks are retried every day, so a message can repeat until the problem is fixed or the certificate is renewed.

| Channel | What you need |
|---|---|
| Telegram | a bot token from @BotFather; send the bot any message and the wizard finds the chat id by itself |
| E-mail | an SMTP server, port, login and password, sender and recipients (comma separated). Linux: SSL (465), STARTTLS (587) or no encryption. Windows: STARTTLS or no encryption — SSL on port 465 is not supported by Windows |
| Webhook | a URL. The wizard sends a POST with JSON fields `event`, `host`, `subject`, `text` and `content` — that works with Slack, Mattermost and Discord as is |

Example webhook body:

```json
{"event":"renewal_failed","host":"web-01","subject":"ssl-wizard: could not renew the certificate example.com",
 "text":"…","content":"…"}
```

---

## Scanning a folder

**Scan a folder** in the main menu takes over certificates that already exist — made by this wizard, by hand, or by another tool. It works the same on Linux and Windows.

1. Enter a folder path (Enter = the current folder).
2. Choose **With subfolders** (the folder and everything inside it) or **This folder only**. The wizard reads `.crt`, `.cer`, `.pem` and `.key` files.
3. The wizard lists every server certificate it found: name, key type, issuer, expiry date and days left, the files it lives in, and whether it can be renewed.
4. Choose **Add to auto-renewal**. For Let's Encrypt certificates you are asked once how the domain should be checked (Standalone, site folder or Cloudflare token). On Linux, a certificate that acme.sh already manages with the same key needs no question — acme.sh renews it the way it was issued.
5. If some certificates have already expired or expire soon, the wizard offers to renew them right away. The rest are renewed by the daily check (see [Let's Encrypt renewal](#lets-encrypt-renewal) for where it lives).

### What gets renewed, and how

The renewed certificate is written to **the same files under the same names**, and it is the same kind of certificate:

| Detected kind | How it is renewed | What stays the same |
|---|---|---|
| Self-signed | re-signed with its own key | subject, domains / IPs (SAN), all extensions, key, key type and size, validity length |
| Signed by your own CA | re-signed by the CA whose certificate and key are in the scanned folder | the same, plus the issuing CA |
| Let's Encrypt | new certificate from Let's Encrypt, requested with the existing key | domains, key; the new certificate comes from Let's Encrypt |

The file layout is kept as well:

- a file that held one certificate gets the new certificate;
- a file that held a chain (`fullchain.pem`) gets the new certificate on top, followed by the chain;
- if the same certificate sits in several files (`cert.pem` and `fullchain.pem`), every file is updated;
- a `.p12` / `.pfx` next to the certificate with the same base name and no password is rebuilt too;
- the private key file is never touched.

A certificate is renewed when a third of its validity is left, but no earlier than 30 days before expiry (a 1-year certificate — 30 days before, a 30-day one — 10 days before).

### What cannot be taken over

The scan shows the reason next to each such certificate:

- issued by a public authority other than Let's Encrypt (for example, a commercial CA);
- the private key is not in the folder, or it is protected by a password;
- for certificates signed by your own CA: the CA certificate or key is not in the folder, or the CA key has a password;
- `.p12` / `.pfx` files on their own, without the certificate and key next to them.

A Cloudflare token entered during the scan is kept for the renewals: on Windows encrypted for the current user (only that user's renewal task can read it); on Linux in the certificate's file in `/etc/ssl-wizard/renew.d/`, readable by root only — the same way acme.sh keeps its own tokens.

---

## Backups

Before the wizard overwrites any file — when a certificate is renewed, or when you create a certificate in a folder that already has files with the same names — the old files are copied to a backup folder:

| System | Backup folder |
|---|---|
| Linux | `/var/backups/ssl-wizard/` (root only) |
| Windows | `%LOCALAPPDATA%\ssl-wizard\backup\` (you, Administrators and SYSTEM only) |

Each certificate gets its own set named by date and time, with the full original path inside it:

```
/var/backups/ssl-wizard/2026-10-01_033000/etc/nginx/ssl/example.com.crt
%LOCALAPPDATA%\ssl-wizard\backup\2026-10-01_033000\C\ssl\example.com.crt
```

To restore, copy the file back to its original place. The wizard keeps the 30 newest sets and deletes older ones. Backups contain private keys — treat the folder accordingly. The folder scan never picks up files from it.

The renewal log and the wizard's screen show where each backup was saved.

---

## Installing your CA on clients

**Windows** (PowerShell as administrator)

```powershell
Import-Certificate -FilePath "ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

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

**macOS**

```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain ca.crt
```

---

## Notes

- `ssl-wizard.sh` must be run as root (`sudo`) and needs bash 4.3 or newer.
- `ssl-wizard.ps1` works in Windows PowerShell 5.1 and newer.
- All keys are created without a password so the web server can start unattended. The exception is the key of your own CA: the wizard lets you protect it with a password.
- `.p12` files are created with an empty password.
