#!/usr/bin/env bash
# ==============================================================================
# ssl-wizard.sh — Interactive SSL Certificate Creation Wizard
# ==============================================================================
# Usage  : sudo ./ssl-wizard.sh
# Requires: bash 4+, openssl, certbot (for Let's Encrypt methods)
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Color scheme
# ==============================================================================
R=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[38;2;210;65;65m'
GREEN=$'\033[38;2;80;200;120m'
YELLOW=$'\033[38;2;230;185;55m'
CYAN=$'\033[38;2;75;200;215m'
BLUE=$'\033[38;2;70;145;235m'
MAGENTA=$'\033[38;2;190;105;235m'
WHITE=$'\033[38;2;235;235;235m'

# ==============================================================================
# Logging
# ==============================================================================
info()  { echo -e "${CYAN}  ●${R} $*"; }
ok()    { echo -e "${GREEN}  ✔${R} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${R} $*"; }
err()   { echo -e "${RED}  ✖${R} $*" >&2; }
die()   { err "$*"; exit 1; }
blank() { echo ""; }
hr()    { echo -e "${DIM}  $(printf '%.0s─' {1..58})${R}"; }

# ==============================================================================
# State — all user-supplied values are stored here
# ==============================================================================
S_METHOD=""       # le_nginx | le_webroot | le_standalone | le_wildcard_manual
                  # le_wildcard_cf | ss_rsa | ss_ecdsa | ss_ca
S_FORMAT=""       # pem | crt_key | p12
S_DOMAIN=""
S_EMAIL=""
S_COUNTRY=""
S_STATE=""
S_CITY=""
S_ORG=""
S_OU=""
S_DAYS=""
S_OUTDIR=""
S_WEBROOT=""
S_CF_INI=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Helpers
# ==============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

require_cmd() {
    command -v "$1" &>/dev/null || die "Command not found: ${BOLD}$1${R}  — install it first."
}

clear_screen() { printf '\033[2J\033[H'; }

# Prompt: ask a question, store result, re-ask on empty input.
# ask VAR "Question" ["default"]
ask() {
    local -n _ref=$1
    local prompt="$2"
    local default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${R}"
    while true; do
        printf "  %s%s: " "$prompt" "$display_default"
        read -r _ref
        [[ -z "$_ref" && -n "$default" ]] && _ref="$default"
        [[ -n "$_ref" ]] && break
        warn "Value cannot be empty."
    done
}

# yes/no prompt — returns 0 for yes, 1 for no
confirm() {
    local ans
    printf "  %s [y/N]: " "$1"
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

# ==============================================================================
# Banner
# ==============================================================================
banner() {
    clear_screen
    echo ""
    echo -e "  ${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${R}"
    echo -e "  ${BOLD}${BLUE}║${R}  ${BOLD}${WHITE}SSL Certificate Creation Wizard${R}                   ${BOLD}${BLUE}║${R}"
    echo -e "  ${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${R}"
    echo ""
}

# ==============================================================================
# STEP 1 — Choose method (Let's Encrypt or self-signed)
# ==============================================================================
step_method() {
    banner
    echo -e "  ${BOLD}Step 1 of 4${R} — Certificate method"
    hr; blank

    echo -e "  ${BOLD}${CYAN}Let's Encrypt (free, publicly trusted, 90 days)${R}"
    echo -e "  ${BLUE}  1)${R}  nginx plugin          ${DIM}— nginx configures itself automatically${R}"
    echo -e "  ${BLUE}  2)${R}  webroot               ${DIM}— nginx stays running, serves challenge${R}"
    echo -e "  ${BLUE}  3)${R}  standalone            ${DIM}— nginx must be stopped during issuance${R}"
    echo -e "  ${BLUE}  4)${R}  wildcard (manual DNS) ${DIM}— add TXT record manually in your DNS${R}"
    echo -e "  ${BLUE}  5)${R}  wildcard (Cloudflare) ${DIM}— automated via Cloudflare API${R}"
    blank
    echo -e "  ${BOLD}${MAGENTA}Self-signed (openssl — no CA trust, dev/internal use)${R}"
    echo -e "  ${BLUE}  6)${R}  RSA 4096              ${DIM}— widest compatibility${R}"
    echo -e "  ${BLUE}  7)${R}  ECDSA P-384           ${DIM}— smaller key, faster handshake${R}"
    echo -e "  ${BLUE}  8)${R}  Local CA + signed     ${DIM}— install CA once, trust all internal certs${R}"
    blank
    echo -e "  ${RED}  0)${R}  Exit"
    blank; hr; blank

    local choice
    while true; do
        printf "  Select [0-8]: "
        read -r choice
        case "$choice" in
            1) S_METHOD="le_nginx";          break ;;
            2) S_METHOD="le_webroot";        break ;;
            3) S_METHOD="le_standalone";     break ;;
            4) S_METHOD="le_wildcard_manual";break ;;
            5) S_METHOD="le_wildcard_cf";    break ;;
            6) S_METHOD="ss_rsa";            break ;;
            7) S_METHOD="ss_ecdsa";          break ;;
            8) S_METHOD="ss_ca";             break ;;
            0) info "Exiting."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# STEP 2 — Output format
# ==============================================================================
step_format() {
    banner
    echo -e "  ${BOLD}Step 2 of 4${R} — Output file format"
    hr; blank

    echo -e "  ${BLUE}  1)${R}  PEM          ${DIM}— .crt + .key (standard for nginx / Apache)${R}"
    echo -e "  ${BLUE}  2)${R}  PEM bundle   ${DIM}— fullchain.pem + privkey.pem (same as LE layout)${R}"
    echo -e "  ${BLUE}  3)${R}  PKCS#12      ${DIM}— .p12 bundle (Java, Windows, some load balancers)${R}"
    blank

    # Let's Encrypt output is always PEM — format choice is cosmetic for naming
    if [[ "$S_METHOD" == le_* ]]; then
        warn "Let's Encrypt always outputs PEM files. Format choice affects naming only."
    fi

    blank; hr; blank

    local choice
    while true; do
        printf "  Select [1-3]: "
        read -r choice
        case "$choice" in
            1) S_FORMAT="pem";    break ;;
            2) S_FORMAT="bundle"; break ;;
            3) S_FORMAT="p12";    break ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# STEP 3 — Variables
# ==============================================================================
step_variables() {
    banner
    echo -e "  ${BOLD}Step 3 of 4${R} — Certificate details"
    hr; blank

    ask S_DOMAIN  "Domain name (without www)"

    # Email required only for LE
    if [[ "$S_METHOD" == le_* ]]; then
        ask S_EMAIL "Contact email (Let's Encrypt notifications)"
    fi

    # Subject fields required only for self-signed
    if [[ "$S_METHOD" == ss_* ]]; then
        ask S_COUNTRY "Country code (2 letters)"  "RU"
        ask S_STATE   "State / Region"             "Moscow"
        ask S_CITY    "City"                       "Moscow"
        ask S_ORG     "Organisation name"
        ask S_OU      "Department / Unit"          "IT"
        ask S_DAYS    "Validity in days"           "398"
    fi

    # Webroot for LE webroot method
    if [[ "$S_METHOD" == "le_webroot" ]]; then
        ask S_WEBROOT "Webroot path (must be served by nginx)" "/var/www/letsencrypt"
    fi

    # Cloudflare ini for LE wildcard CF
    if [[ "$S_METHOD" == "le_wildcard_cf" ]]; then
        ask S_CF_INI "Path to cloudflare.ini credentials file" "/etc/letsencrypt/cloudflare.ini"
    fi
}

# ==============================================================================
# STEP 4 — Output directory
# ==============================================================================
step_outdir() {
    banner
    echo -e "  ${BOLD}Step 4 of 4${R} — Output directory"
    hr; blank

    echo -e "  ${DIM}Where should the certificate files be saved?${R}"
    blank

    if [[ "$S_METHOD" == le_* ]]; then
        info "Let's Encrypt always writes to /etc/letsencrypt/live/${S_DOMAIN}/"
        info "You can optionally specify a directory to COPY the files into."
        blank
    fi

    echo -e "  ${BLUE}  1)${R}  Same directory as this script  ${DIM}(${SCRIPT_DIR})${R}"
    echo -e "  ${BLUE}  2)${R}  Custom path"
    blank; hr; blank

    local choice
    while true; do
        printf "  Select [1-2]: "
        read -r choice
        case "$choice" in
            1) S_OUTDIR="${SCRIPT_DIR}"; break ;;
            2) ask S_OUTDIR "Enter full output path"; break ;;
            *) warn "Invalid choice." ;;
        esac
    done

    mkdir -p "${S_OUTDIR}"
}

# ==============================================================================
# Summary screen
# ==============================================================================
show_summary() {
    banner
    echo -e "  ${BOLD}Summary — review before executing${R}"
    hr; blank

    echo -e "  ${DIM}Method   :${R}  ${WHITE}${S_METHOD}${R}"
    echo -e "  ${DIM}Format   :${R}  ${WHITE}${S_FORMAT}${R}"
    echo -e "  ${DIM}Domain   :${R}  ${WHITE}${S_DOMAIN}${R}"
    [[ -n "$S_EMAIL"   ]] && echo -e "  ${DIM}Email    :${R}  ${WHITE}${S_EMAIL}${R}"
    [[ -n "$S_COUNTRY" ]] && echo -e "  ${DIM}Country  :${R}  ${WHITE}${S_COUNTRY}${R}"
    [[ -n "$S_ORG"     ]] && echo -e "  ${DIM}Org      :${R}  ${WHITE}${S_ORG}${R}"
    [[ -n "$S_DAYS"    ]] && echo -e "  ${DIM}Validity :${R}  ${WHITE}${S_DAYS} days${R}"
    echo -e "  ${DIM}Output   :${R}  ${WHITE}${S_OUTDIR}${R}"
    blank; hr; blank

    confirm "Proceed?" || { info "Aborted by user."; exit 0; }
}

# ==============================================================================
# openssl.cnf generator
# ==============================================================================
write_openssl_cnf() {
    local dir="$1"
    cat > "${dir}/openssl.cnf" <<OPENSSLCNF
[req]
default_bits       = 4096
default_md         = sha256
prompt             = no
distinguished_name = req_distinguished_name
req_extensions     = v3_req
x509_extensions    = v3_req

[req_distinguished_name]
C  = ${S_COUNTRY}
ST = ${S_STATE}
L  = ${S_CITY}
O  = ${S_ORG}
OU = ${S_OU}
CN = ${S_DOMAIN}

[v3_req]
basicConstraints   = CA:FALSE
keyUsage           = digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth
subjectAltName     = @alt_names

[alt_names]
DNS.1 = ${S_DOMAIN}
DNS.2 = www.${S_DOMAIN}
DNS.3 = *.${S_DOMAIN}
OPENSSLCNF
}

# ==============================================================================
# PKCS#12 conversion helper
# ==============================================================================
maybe_convert_p12() {
    local cert="$1" key="$2" out="$3"
    if [[ "$S_FORMAT" == "p12" ]]; then
        info "Converting to PKCS#12..."
        local p12="${out}/${S_DOMAIN}.p12"
        openssl pkcs12 -export \
            -in   "$cert" \
            -inkey "$key" \
            -out  "$p12" \
            -name "$S_DOMAIN" \
            -passout pass:
        ok "PKCS#12: ${p12}  (no password — set one with -passout pass:<pw> if needed)"
    fi
}

# ==============================================================================
# Copy LE files to output dir
# ==============================================================================
copy_le_files() {
    local le_dir="/etc/letsencrypt/live/${S_DOMAIN}"
    [[ "$S_OUTDIR" == "/etc/letsencrypt/live/${S_DOMAIN}" ]] && return
    info "Copying certificate files to ${S_OUTDIR}..."
    cp "${le_dir}/fullchain.pem" "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem"
    cp "${le_dir}/privkey.pem"   "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    cp "${le_dir}/chain.pem"     "${S_OUTDIR}/${S_DOMAIN}_chain.pem"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    ok "Files copied."
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
                      "${S_OUTDIR}/${S_DOMAIN}_privkey.pem" \
                      "${S_OUTDIR}"
}

# ==============================================================================
# Execution: Let's Encrypt methods
# ==============================================================================
run_le_nginx() {
    require_cmd certbot
    info "Running certbot --nginx for ${S_DOMAIN}..."
    certbot --nginx \
        --non-interactive --agree-tos \
        --email "${S_EMAIL}" \
        -d "${S_DOMAIN}" -d "www.${S_DOMAIN}"
    copy_le_files
}

run_le_webroot() {
    require_cmd certbot
    mkdir -p "${S_WEBROOT}/.well-known/acme-challenge"
    info "Running certbot --webroot for ${S_DOMAIN}..."
    certbot certonly \
        --webroot --webroot-path "${S_WEBROOT}" \
        --non-interactive --agree-tos \
        --email "${S_EMAIL}" \
        -d "${S_DOMAIN}" -d "www.${S_DOMAIN}"
    copy_le_files
}

run_le_standalone() {
    require_cmd certbot
    warn "nginx will be stopped temporarily."
    confirm "Stop nginx now?" || die "Aborted."
    systemctl stop nginx
    info "Running certbot --standalone for ${S_DOMAIN}..."
    if certbot certonly \
        --standalone \
        --non-interactive --agree-tos \
        --email "${S_EMAIL}" \
        -d "${S_DOMAIN}" -d "www.${S_DOMAIN}"; then
        ok "Certificate obtained."
    else
        systemctl start nginx
        die "certbot failed."
    fi
    systemctl start nginx
    ok "nginx restarted."
    copy_le_files
}

run_le_wildcard_manual() {
    require_cmd certbot
    warn "You will be prompted to add a DNS TXT record."
    warn "Record: _acme-challenge.${S_DOMAIN}"
    blank
    confirm "Ready to proceed?" || die "Aborted."
    certbot certonly \
        --manual \
        --preferred-challenges dns \
        --agree-tos \
        --email "${S_EMAIL}" \
        -d "${S_DOMAIN}" -d "*.${S_DOMAIN}"
    copy_le_files
}

run_le_wildcard_cf() {
    require_cmd certbot
    [[ -f "${S_CF_INI}" ]] || die "Cloudflare credentials file not found: ${S_CF_INI}"
    pip install --quiet certbot-dns-cloudflare 2>/dev/null || true
    info "Running certbot --dns-cloudflare for *.${S_DOMAIN}..."
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "${S_CF_INI}" \
        --non-interactive --agree-tos \
        --email "${S_EMAIL}" \
        -d "${S_DOMAIN}" -d "*.${S_DOMAIN}"
    copy_le_files
}

# ==============================================================================
# Execution: self-signed methods
# ==============================================================================
run_ss_rsa() {
    require_cmd openssl
    write_openssl_cnf "${S_OUTDIR}"
    info "Generating RSA 4096 self-signed certificate (${S_DAYS} days)..."
    openssl req -x509 \
        -newkey rsa:4096 \
        -keyout "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out    "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days   "${S_DAYS}" \
        -nodes \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Key : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Cert: ${S_OUTDIR}/${S_DOMAIN}.crt"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
}

run_ss_ecdsa() {
    require_cmd openssl
    write_openssl_cnf "${S_OUTDIR}"
    info "Generating ECDSA P-384 self-signed certificate (${S_DAYS} days)..."
    openssl ecparam -name secp384r1 -genkey -noout \
        -out "${S_OUTDIR}/${S_DOMAIN}.key"
    openssl req -x509 \
        -key  "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out  "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days "${S_DAYS}" \
        -subj "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Key : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Cert: ${S_OUTDIR}/${S_DOMAIN}.crt"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
}

run_ss_ca() {
    require_cmd openssl
    write_openssl_cnf "${S_OUTDIR}"
    blank
    info "Step 1/3 — Creating root CA key and certificate..."
    warn "You will be prompted for a CA key passphrase — remember it."
    openssl genrsa -aes256 -out "${S_OUTDIR}/ca.key" 4096
    openssl req -x509 -new -nodes \
        -key    "${S_OUTDIR}/ca.key" \
        -sha256 -days 3650 \
        -out    "${S_OUTDIR}/ca.crt" \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG} CA/CN=${S_ORG} Root CA"
    ok "CA cert: ${S_OUTDIR}/ca.crt"
    blank

    info "Step 2/3 — Generating server key and CSR..."
    openssl genrsa -out "${S_OUTDIR}/${S_DOMAIN}.key" 4096
    openssl req -new \
        -key    "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out    "${S_OUTDIR}/${S_DOMAIN}.csr" \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -config "${S_OUTDIR}/openssl.cnf"
    ok "CSR: ${S_OUTDIR}/${S_DOMAIN}.csr"
    blank

    info "Step 3/3 — Signing certificate with local CA..."
    openssl x509 -req \
        -in         "${S_OUTDIR}/${S_DOMAIN}.csr" \
        -CA         "${S_OUTDIR}/ca.crt" \
        -CAkey      "${S_OUTDIR}/ca.key" \
        -CAcreateserial \
        -out        "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days       "${S_DAYS}" \
        -sha256 \
        -extensions v3_req \
        -extfile    "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Key : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "Cert: ${S_OUTDIR}/${S_DOMAIN}.crt"
    blank

    warn "Distribute ${S_OUTDIR}/ca.crt to client trust stores to avoid browser warnings."
    info "Debian/Ubuntu : cp ${S_OUTDIR}/ca.crt /usr/local/share/ca-certificates/my-ca.crt && update-ca-certificates"
    info "RHEL/Rocky    : cp ${S_OUTDIR}/ca.crt /etc/pki/ca-trust/source/anchors/my-ca.crt && update-ca-trust"
    info "Windows PS    : Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\\LocalMachine\\Root"

    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
}

# ==============================================================================
# Dispatch
# ==============================================================================
run() {
    banner
    echo -e "  ${BOLD}Executing…${R}"
    hr; blank

    case "$S_METHOD" in
        le_nginx)           run_le_nginx          ;;
        le_webroot)         run_le_webroot         ;;
        le_standalone)      run_le_standalone      ;;
        le_wildcard_manual) run_le_wildcard_manual ;;
        le_wildcard_cf)     run_le_wildcard_cf     ;;
        ss_rsa)             run_ss_rsa             ;;
        ss_ecdsa)           run_ss_ecdsa           ;;
        ss_ca)              run_ss_ca              ;;
    esac

    blank; hr
    ok "${BOLD}Done.${R}  Files written to: ${WHITE}${S_OUTDIR}${R}"
    blank
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    require_root
    step_method
    step_format
    step_variables
    step_outdir
    show_summary
    run

    blank
    read -rp "  Press Enter to exit…" _
}

main
