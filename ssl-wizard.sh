#!/usr/bin/env bash
# ==============================================================================
# ssl-wizard.sh — Interactive SSL Certificate Creation Wizard
# ==============================================================================
# Usage  : sudo ./ssl-wizard.sh
# Requires: bash 4+, openssl, acme.sh (auto-installed if missing), socat/nginx
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
# State
# ==============================================================================
S_METHOD=""
S_FORMAT=""
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
S_CF_TOKEN=""
S_PASSPHRASE=""     # yes | no
S_KEYGEN_ALGO=""    # rsa | ecdsa | ed25519 | rand
S_RSA_BITS=""
S_EC_CURVE=""
S_RAND_FORMAT=""
S_RAND_BYTES=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_SH="${HOME}/.acme.sh/acme.sh"

# ==============================================================================
# Navigation signal — steps set this to "back" to trigger re-run of prev step
# ==============================================================================
NAV=""

# ==============================================================================
# Helpers
# ==============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

clear_screen() { printf '\033[2J\033[H'; }

# ask VARNAME "Prompt" ["default"]
# Type "b" to go back — sets NAV=back and returns 1
ask() {
    local -n _ref=$1
    local prompt="$2"
    local default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${R}"
    while true; do
        printf "  %s%s  ${DIM}(b = back)${R}: " "$prompt" "$display_default"
        read -r _ref
        if [[ "${_ref,,}" == "b" ]]; then
            NAV="back"
            return 1
        fi
        [[ -z "$_ref" && -n "$default" ]] && _ref="$default"
        [[ -n "$_ref" ]] && { NAV=""; return 0; }
        warn "Value cannot be empty."
    done
}

# menu_pick VARNAME choices... — sets NAV=back on "b", returns chosen value
menu_pick() {
    local -n _mp_ref=$1; shift
    local max=$#
    while true; do
        printf "  Select [1-%d]  ${DIM}(b = back)${R}: " "$max"
        read -r _mp_ref
        if [[ "${_mp_ref,,}" == "b" ]]; then
            NAV="back"
            return 1
        fi
        if [[ "$_mp_ref" =~ ^[0-9]+$ ]] && (( _mp_ref >= 1 && _mp_ref <= max )); then
            NAV=""
            return 0
        fi
        warn "Invalid choice."
    done
}

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
# DEPENDENCY CHECK
# ==============================================================================
check_deps() {
    banner
    echo -e "  ${BOLD}Checking dependencies…${R}"
    hr; blank

    local missing=()

    # openssl — always required
    if command -v openssl &>/dev/null; then
        ok "openssl        $(openssl version | awk '{print $2}')"
    else
        err "openssl        not found"
        missing+=("openssl")
    fi

    # acme.sh — required for LE methods
    if [[ -f "$ACME_SH" ]]; then
        ok "acme.sh        $("$ACME_SH" --version 2>/dev/null | head -1 || echo 'found')"
    else
        warn "acme.sh        not found"
        blank
        if confirm "Install acme.sh now?"; then
            install_acme
        else
            warn "acme.sh not installed — Let's Encrypt methods will be unavailable."
        fi
    fi

    # socat — required for acme.sh standalone mode
    if command -v socat &>/dev/null; then
        ok "socat          $(socat -V 2>&1 | grep -i version | head -1 | awk '{print $NF}' || echo 'found')"
    else
        warn "socat          not found  ${DIM}(needed for acme.sh standalone mode)${R}"
    fi

    # curl — required for acme.sh
    if command -v curl &>/dev/null; then
        ok "curl           $(curl --version | head -1 | awk '{print $2}')"
    else
        err "curl           not found"
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        blank
        err "Missing required tools: ${missing[*]}"
        err "Install them and re-run the script."
        exit 1
    fi

    blank
    read -rp "  Press Enter to continue…" _
}

# ==============================================================================
# INSTALL ACME.SH
# ==============================================================================
install_acme() {
    blank
    info "Installing acme.sh…"
    if ! command -v curl &>/dev/null; then
        die "curl is required to install acme.sh."
    fi
    curl -fsSL https://get.acme.sh | sh
    # Reload shell env so acme.sh is found
    export PATH="${HOME}/.acme.sh:${PATH}"
    if [[ -f "$ACME_SH" ]]; then
        ok "acme.sh installed to ${HOME}/.acme.sh/"
    else
        die "acme.sh installation failed."
    fi
}

# ==============================================================================
# STEP 1 — Method
# ==============================================================================
step_method() {
    while true; do
        banner
        echo -e "  ${BOLD}Step 1 of 5${R} — Certificate method"
        hr; blank

        echo -e "  ${BOLD}${CYAN}Let's Encrypt  ${DIM}(free, publicly trusted, 90 days)${R}"
        echo -e "  ${BLUE}  1)${R}  Standalone            ${DIM}— acme.sh binds port 80 directly${R}"
        echo -e "  ${BLUE}  2)${R}  Webroot               ${DIM}— nginx stays running, serves challenge${R}"
        echo -e "  ${BLUE}  3)${R}  nginx mode            ${DIM}— acme.sh reloads nginx automatically${R}"
        echo -e "  ${BLUE}  4)${R}  Wildcard — manual DNS ${DIM}— add TXT record manually in DNS${R}"
        echo -e "  ${BLUE}  5)${R}  Wildcard — Cloudflare ${DIM}— automated via Cloudflare API token${R}"
        blank
        echo -e "  ${BOLD}${MAGENTA}Self-signed  ${DIM}(openssl — dev / internal use)${R}"
        echo -e "  ${BLUE}  6)${R}  Simple — no passphrase ${DIM}— genrsa → CSR → x509, minimal steps${R}"
        echo -e "  ${BLUE}  7)${R}  RSA                    ${DIM}— choose key size: 2048 / 3072 / 4096${R}"
        echo -e "  ${BLUE}  8)${R}  ECDSA                  ${DIM}— choose curve: P-256 / P-384 / P-521${R}"
        echo -e "  ${BLUE}  9)${R}  Ed25519                ${DIM}— modern, fixed key size${R}"
        echo -e "  ${BLUE} 10)${R}  Local CA + signed      ${DIM}— install CA once, trust all internal certs${R}"
        blank
        echo -e "  ${BOLD}${WHITE}Utilities${R}"
        echo -e "  ${BLUE} 11)${R}  Generate key / random  ${DIM}— RSA / ECDSA / Ed25519 / random bytes${R}"
        blank
        echo -e "  ${RED}  0)${R}  Exit"
        blank; hr; blank

        local choice
        printf "  Select [0-11]: "
        read -r choice
        case "$choice" in
            1)  S_METHOD="le_standalone";      return 0 ;;
            2)  S_METHOD="le_webroot";         return 0 ;;
            3)  S_METHOD="le_nginx";           return 0 ;;
            4)  S_METHOD="le_wildcard_manual"; return 0 ;;
            5)  S_METHOD="le_wildcard_cf";     return 0 ;;
            6)  S_METHOD="ss_simple";          return 0 ;;
            7)  S_METHOD="ss_rsa";             return 0 ;;
            8)  S_METHOD="ss_ecdsa";           return 0 ;;
            9)  S_METHOD="ss_ed25519";         return 0 ;;
            10) S_METHOD="ss_ca";              return 0 ;;
            11) S_METHOD="keygen";             return 0 ;;
            0)  info "Exiting."; exit 0 ;;
            *)  warn "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# STEP 2 — Output format  (skip for keygen)
# ==============================================================================
step_format() {
    [[ "$S_METHOD" == "keygen" || "$S_METHOD" == "ss_simple" ]] && return 0
    while true; do
        banner
        echo -e "  ${BOLD}Step 2 of 5${R} — Output file format"
        hr; blank

        echo -e "  ${BLUE}  1)${R}  PEM        ${DIM}— .crt + .key  (standard for nginx / Apache)${R}"
        echo -e "  ${BLUE}  2)${R}  PEM bundle ${DIM}— fullchain.pem + privkey.pem${R}"
        echo -e "  ${BLUE}  3)${R}  PKCS#12    ${DIM}— .p12  (Java, Windows, load balancers)${R}"
        blank
        [[ "$S_METHOD" == le_* ]] && \
            warn "acme.sh always outputs PEM. Format choice affects file naming only."
        blank; hr; blank

        local c
        printf "  Select [1-3]  ${DIM}(b = back)${R}: "
        read -r c
        case "$c" in
            b|B) NAV="back"; return 1 ;;
            1) S_FORMAT="pem";    NAV=""; return 0 ;;
            2) S_FORMAT="bundle"; NAV=""; return 0 ;;
            3) S_FORMAT="p12";    NAV=""; return 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# STEP 3 — Variables
# ==============================================================================
step_variables() {
    [[ "$S_METHOD" == "keygen" || "$S_METHOD" == "ss_simple" ]] && return 0
    while true; do
        banner
        echo -e "  ${BOLD}Step 3 of 5${R} — Certificate details"
        hr; blank

        ask S_DOMAIN "Domain or IP address" || return 1

        if [[ "$S_METHOD" == le_* ]]; then
            ask S_EMAIL "Contact email (for acme.sh account)" || return 1
        fi

        if [[ "$S_METHOD" == ss_* ]]; then
            ask S_COUNTRY "Country code (2 letters)" "RU"  || return 1
            ask S_STATE   "State / Region"           "Moscow" || return 1
            ask S_CITY    "City"                     "Moscow" || return 1
            ask S_ORG     "Organisation name"        || return 1
            ask S_OU      "Department / Unit"        "IT" || return 1
            ask S_DAYS    "Validity in days"         "398" || return 1
        fi

        if [[ "$S_METHOD" == ss_rsa ]]; then
            banner
            echo -e "  ${BOLD}Step 3 of 5${R} — RSA key size"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  2048 bits  ${DIM}— fast, minimum recommended${R}"
            echo -e "  ${BLUE}  2)${R}  3072 bits  ${DIM}— balanced${R}"
            echo -e "  ${BLUE}  3)${R}  4096 bits  ${DIM}— strongest, slower${R}"
            blank; hr; blank
            local rc
            menu_pick rc "2048" "3072" "4096" || return 1
            case "$rc" in
                1) S_RSA_BITS="2048" ;;
                2) S_RSA_BITS="3072" ;;
                3) S_RSA_BITS="4096" ;;
            esac
        fi

        if [[ "$S_METHOD" == ss_ecdsa ]]; then
            banner
            echo -e "  ${BOLD}Step 3 of 5${R} — ECDSA curve"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  P-256  ${DIM}— fastest, widely supported${R}"
            echo -e "  ${BLUE}  2)${R}  P-384  ${DIM}— stronger, recommended${R}"
            echo -e "  ${BLUE}  3)${R}  P-521  ${DIM}— strongest${R}"
            blank; hr; blank
            local ec
            menu_pick ec "P-256" "P-384" "P-521" || return 1
            case "$ec" in
                1) S_EC_CURVE="prime256v1" ;;
                2) S_EC_CURVE="secp384r1"  ;;
                3) S_EC_CURVE="secp521r1"  ;;
            esac
        fi

        if [[ "$S_METHOD" == "le_webroot" ]]; then
            ask S_WEBROOT "Webroot path (served by nginx)" "/var/www/letsencrypt" || return 1
        fi

        if [[ "$S_METHOD" == "le_wildcard_cf" ]]; then
            ask S_CF_TOKEN "Cloudflare API token" || return 1
        fi

        # Passphrase option for self-signed CA key
        if [[ "$S_METHOD" == "ss_ca" ]]; then
            banner
            echo -e "  ${BOLD}Step 3 of 5${R} — CA key passphrase"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  With passphrase    ${DIM}— more secure, required on every signing${R}"
            echo -e "  ${BLUE}  2)${R}  Without passphrase ${DIM}— convenient, less secure${R}"
            blank; hr; blank
            local pp
            menu_pick pp "with" "without" || return 1
            case "$pp" in
                1) S_PASSPHRASE="yes" ;;
                2) S_PASSPHRASE="no"  ;;
            esac
        fi

        return 0
    done
}

# ==============================================================================
# STEP 3 (ss_simple) — Simple self-signed parameters: RSA bits + validity
# STEP 3 (keygen)   — Key generator parameters
# Unified dispatcher called from main
# ==============================================================================
step_simple_or_keygen_params() {
    if [[ "$S_METHOD" == "ss_simple" ]]; then
        # -- RSA key size -------------------------------------------------------
        while true; do
            banner
            echo -e "  ${BOLD}Step 3 of 5${R} — Simple self-signed: RSA key size"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  2048 bits  ${DIM}— fast, minimum recommended${R}"
            echo -e "  ${BLUE}  2)${R}  3072 bits  ${DIM}— balanced${R}"
            echo -e "  ${BLUE}  3)${R}  4096 bits  ${DIM}— strongest, slower${R}"
            blank; hr; blank
            local rs
            menu_pick rs "2048" "3072" "4096" || { NAV="back"; return 1; }
            case "$rs" in
                1) S_RSA_BITS="2048"; break ;;
                2) S_RSA_BITS="3072"; break ;;
                3) S_RSA_BITS="4096"; break ;;
            esac
        done

        # -- Domain / IP --------------------------------------------------------
        banner
        echo -e "  ${BOLD}Step 3 of 5${R} — Simple self-signed: domain / IP"
        hr; blank
        ask S_DOMAIN "Domain or IP address" || { NAV="back"; return 1; }

        # -- Validity -----------------------------------------------------------
        ask S_DAYS "Validity in days" "365" || { NAV="back"; return 1; }

        NAV=""
        return 0
    fi

    # Delegate to keygen flow
    step_keygen_params
}

step_keygen_params() {
    while true; do
        banner
        echo -e "  ${BOLD}Key Generator${R} — algorithm"
        hr; blank
        echo -e "  ${BLUE}  1)${R}  RSA          ${DIM}— choose key size${R}"
        echo -e "  ${BLUE}  2)${R}  ECDSA        ${DIM}— choose curve${R}"
        echo -e "  ${BLUE}  3)${R}  Ed25519      ${DIM}— modern, fixed size${R}"
        echo -e "  ${BLUE}  4)${R}  Random bytes ${DIM}— openssl rand (base64 / hex)${R}"
        blank; hr; blank

        local algo
        menu_pick algo "rsa" "ecdsa" "ed25519" "rand" || { NAV="back"; return 1; }
        case "$algo" in
            1) S_KEYGEN_ALGO="rsa"     ;;
            2) S_KEYGEN_ALGO="ecdsa"   ;;
            3) S_KEYGEN_ALGO="ed25519" ;;
            4) S_KEYGEN_ALGO="rand"    ;;
        esac

        if [[ "$S_KEYGEN_ALGO" == "rsa" ]]; then
            banner
            echo -e "  ${BOLD}Key Generator${R} — RSA key size"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  2048 bits"
            echo -e "  ${BLUE}  2)${R}  3072 bits"
            echo -e "  ${BLUE}  3)${R}  4096 bits"
            blank; hr; blank
            local rs
            menu_pick rs "2048" "3072" "4096" || continue
            case "$rs" in
                1) S_RSA_BITS="2048" ;;
                2) S_RSA_BITS="3072" ;;
                3) S_RSA_BITS="4096" ;;
            esac
        fi

        if [[ "$S_KEYGEN_ALGO" == "ecdsa" ]]; then
            banner
            echo -e "  ${BOLD}Key Generator${R} — ECDSA curve"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  P-256  ${DIM}(prime256v1)${R}"
            echo -e "  ${BLUE}  2)${R}  P-384  ${DIM}(secp384r1)${R}"
            echo -e "  ${BLUE}  3)${R}  P-521  ${DIM}(secp521r1)${R}"
            blank; hr; blank
            local ec
            menu_pick ec "P-256" "P-384" "P-521" || continue
            case "$ec" in
                1) S_EC_CURVE="prime256v1" ;;
                2) S_EC_CURVE="secp384r1"  ;;
                3) S_EC_CURVE="secp521r1"  ;;
            esac
        fi

        if [[ "$S_KEYGEN_ALGO" == "rand" ]]; then
            banner
            echo -e "  ${BOLD}Key Generator${R} — random bytes format"
            hr; blank
            echo -e "  ${BLUE}  1)${R}  base64  ${DIM}— URL-safe printable string${R}"
            echo -e "  ${BLUE}  2)${R}  hex     ${DIM}— hexadecimal string${R}"
            blank; hr; blank
            local rf
            menu_pick rf "base64" "hex" || continue
            case "$rf" in
                1) S_RAND_FORMAT="base64" ;;
                2) S_RAND_FORMAT="hex"    ;;
            esac
            ask S_RAND_BYTES "Number of random bytes" "48" || continue
        fi

        return 0
    done
}

# ==============================================================================
# STEP 4 — Output directory
# ==============================================================================
step_outdir() {
    while true; do
        banner
        echo -e "  ${BOLD}Step 4 of 5${R} — Output directory"
        hr; blank
        echo -e "  ${BLUE}  1)${R}  Same directory as this script  ${DIM}(${SCRIPT_DIR})${R}"
        echo -e "  ${BLUE}  2)${R}  Custom path"
        blank; hr; blank

        local c
        printf "  Select [1-2]  ${DIM}(b = back)${R}: "
        read -r c
        case "$c" in
            b|B) NAV="back"; return 1 ;;
            1) S_OUTDIR="${SCRIPT_DIR}"; break ;;
            2)
                ask S_OUTDIR "Enter full output path" || return 1
                break
                ;;
            *) warn "Invalid choice." ;;
        esac
    done
    mkdir -p "${S_OUTDIR}"
    NAV=""
    return 0
}

# ==============================================================================
# STEP 5 — Summary + confirm
# ==============================================================================
step_summary() {
    banner
    echo -e "  ${BOLD}Step 5 of 5${R} — Summary"
    hr; blank
    echo -e "  ${DIM}Method    :${R}  ${WHITE}${S_METHOD}${R}"
    [[ -n "$S_FORMAT"   ]] && echo -e "  ${DIM}Format    :${R}  ${WHITE}${S_FORMAT}${R}"
    [[ -n "$S_DOMAIN"   ]] && echo -e "  ${DIM}Domain/IP :${R}  ${WHITE}${S_DOMAIN}${R}"
    [[ -n "$S_EMAIL"    ]] && echo -e "  ${DIM}Email     :${R}  ${WHITE}${S_EMAIL}${R}"
    [[ -n "$S_COUNTRY"  ]] && echo -e "  ${DIM}Country   :${R}  ${WHITE}${S_COUNTRY}${R}"
    [[ -n "$S_ORG"      ]] && echo -e "  ${DIM}Org       :${R}  ${WHITE}${S_ORG}${R}"
    [[ -n "$S_DAYS"     ]] && echo -e "  ${DIM}Validity  :${R}  ${WHITE}${S_DAYS} days${R}"
    [[ -n "$S_RSA_BITS" ]] && echo -e "  ${DIM}RSA bits  :${R}  ${WHITE}${S_RSA_BITS}${R}"
    [[ -n "$S_EC_CURVE" ]] && echo -e "  ${DIM}EC curve  :${R}  ${WHITE}${S_EC_CURVE}${R}"
    [[ "$S_METHOD" == "ss_ca" ]] && \
        echo -e "  ${DIM}Passphrase:${R}  ${WHITE}${S_PASSPHRASE}${R}"
    echo -e "  ${DIM}Output    :${R}  ${WHITE}${S_OUTDIR}${R}"
    blank; hr; blank

    while true; do
        printf "  Proceed? [y/N]  ${DIM}(b = back)${R}: "
        read -r ans
        case "${ans,,}" in
            y) return 0 ;;
            b) NAV="back"; return 1 ;;
            *) return 1 ;;
        esac
    done
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
    # If domain looks like an IP, replace DNS entries with IP entry
    if [[ "$S_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cat > "${dir}/openssl.cnf" <<OPENSSLCNF_IP
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
IP.1 = ${S_DOMAIN}
OPENSSLCNF_IP
    fi
}

# ==============================================================================
# PKCS#12 conversion
# ==============================================================================
maybe_convert_p12() {
    local cert="$1" key="$2" out="$3"
    [[ "$S_FORMAT" != "p12" ]] && return 0
    info "Converting to PKCS#12…"
    openssl pkcs12 -export \
        -in    "$cert" \
        -inkey "$key" \
        -out   "${out}/${S_DOMAIN}.p12" \
        -name  "$S_DOMAIN" \
        -passout pass:
    ok "PKCS#12 : ${out}/${S_DOMAIN}.p12  (no password)"
}

# ==============================================================================
# Copy acme.sh files to output dir
# ==============================================================================
copy_acme_files() {
    local acme_dir="${HOME}/.acme.sh/${S_DOMAIN}_ecc"
    [[ -d "$acme_dir" ]] || acme_dir="${HOME}/.acme.sh/${S_DOMAIN}"
    [[ -d "$acme_dir" ]] || { warn "acme.sh output dir not found — skipping copy."; return; }

    local fullchain="${acme_dir}/fullchain.cer"
    local key="${acme_dir}/${S_DOMAIN}.key"

    [[ -f "$fullchain" ]] || fullchain="${acme_dir}/${S_DOMAIN}.cer"

    cp "${fullchain}"                   "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem"
    cp "${key}"                         "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    [[ -f "${acme_dir}/ca.cer" ]] && \
        cp "${acme_dir}/ca.cer"         "${S_OUTDIR}/${S_DOMAIN}_chain.pem"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    ok "fullchain : ${S_OUTDIR}/${S_DOMAIN}_fullchain.pem"
    ok "key       : ${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
                      "${S_OUTDIR}/${S_DOMAIN}_privkey.pem" \
                      "${S_OUTDIR}"
}

# ==============================================================================
# nginx directives hint
# ==============================================================================
print_nginx_hint() {
    local cert="$1" key="$2"
    blank; hr
    echo -e "  ${BOLD}nginx directives:${R}"
    echo -e "  ${DIM}ssl_certificate${R}     ${WHITE}${cert}${R};"
    echo -e "  ${DIM}ssl_certificate_key${R} ${WHITE}${key}${R};"
    hr
}

# ==============================================================================
# Run: acme.sh methods
# ==============================================================================
run_le_standalone() {
    [[ -f "$ACME_SH" ]] || die "acme.sh not found. Run the wizard again and install it."
    command -v socat &>/dev/null || die "socat is required for standalone mode. Install: apt install socat"
    info "Issuing certificate via acme.sh standalone for: ${S_DOMAIN}"
    "$ACME_SH" --issue \
        --standalone \
        --domain "${S_DOMAIN}" \
        --domain "www.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}"
    copy_acme_files
    print_nginx_hint \
        "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
        "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
}

run_le_webroot() {
    [[ -f "$ACME_SH" ]] || die "acme.sh not found."
    mkdir -p "${S_WEBROOT}/.well-known/acme-challenge"
    info "Issuing certificate via acme.sh webroot for: ${S_DOMAIN}"
    "$ACME_SH" --issue \
        --webroot "${S_WEBROOT}" \
        --domain  "${S_DOMAIN}" \
        --domain  "www.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}"
    copy_acme_files
    print_nginx_hint \
        "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
        "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
}

run_le_nginx() {
    [[ -f "$ACME_SH" ]] || die "acme.sh not found."
    command -v nginx &>/dev/null || die "nginx is not installed."
    info "Issuing certificate via acme.sh nginx mode for: ${S_DOMAIN}"
    "$ACME_SH" --issue \
        --nginx \
        --domain "${S_DOMAIN}" \
        --domain "www.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}"
    copy_acme_files
    print_nginx_hint \
        "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
        "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
}

run_le_wildcard_manual() {
    [[ -f "$ACME_SH" ]] || die "acme.sh not found."
    warn "You will be prompted to add a DNS TXT record."
    warn "Record name : _acme-challenge.${S_DOMAIN}"
    blank
    confirm "Ready?" || die "Aborted."
    "$ACME_SH" --issue \
        --dns \
        --domain "${S_DOMAIN}" \
        --domain "*.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}" \
        --yes-I-know-dns-manual-mode-enough-go-ahead-please
    blank
    warn "Add the TXT record shown above to your DNS, then run:"
    info "$ACME_SH --renew --domain ${S_DOMAIN} --yes-I-know-dns-manual-mode-enough-go-ahead-please"
}

run_le_wildcard_cf() {
    [[ -f "$ACME_SH" ]] || die "acme.sh not found."
    info "Issuing wildcard certificate via Cloudflare DNS for: *.${S_DOMAIN}"
    export CF_Token="${S_CF_TOKEN}"
    "$ACME_SH" --issue \
        --dns dns_cf \
        --domain "${S_DOMAIN}" \
        --domain "*.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}"
    copy_acme_files
    print_nginx_hint \
        "${S_OUTDIR}/${S_DOMAIN}_fullchain.pem" \
        "${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
}

# ==============================================================================
# Run: simple self-signed — no passphrase (genrsa → CSR → x509)
# ==============================================================================
run_ss_simple() {
    info "Step 1/3 — Generating RSA ${S_RSA_BITS} private key (no passphrase)…"
    openssl genrsa         -out "${S_OUTDIR}/privkey.pem"         "${S_RSA_BITS}"
    chmod 600 "${S_OUTDIR}/privkey.pem"
    ok "key  : ${S_OUTDIR}/privkey.pem"
    blank

    info "Step 2/3 — Generating Certificate Signing Request (CSR)…"
    openssl req -new         -key "${S_OUTDIR}/privkey.pem"         -out "${S_OUTDIR}/cert.csr"         -subj "/CN=${S_DOMAIN}"
    ok "CSR  : ${S_OUTDIR}/cert.csr"
    blank

    info "Step 3/3 — Self-signing certificate (${S_DAYS} days)…"
    openssl x509 -req         -days   "${S_DAYS}"         -in     "${S_OUTDIR}/cert.csr"         -signkey "${S_OUTDIR}/privkey.pem"         -out    "${S_OUTDIR}/fullchain.pem"
    ok "cert : ${S_OUTDIR}/fullchain.pem"
    print_nginx_hint "${S_OUTDIR}/fullchain.pem"                      "${S_OUTDIR}/privkey.pem"
}

# ==============================================================================
# Run: self-signed methods
# ==============================================================================
run_ss_rsa() {
    write_openssl_cnf "${S_OUTDIR}"
    info "Generating RSA ${S_RSA_BITS} self-signed certificate (${S_DAYS} days)…"
    openssl req -x509 \
        -newkey "rsa:${S_RSA_BITS}" \
        -keyout "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out    "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days   "${S_DAYS}" \
        -nodes \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "key  : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "cert : ${S_OUTDIR}/${S_DOMAIN}.crt"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
    print_nginx_hint "${S_OUTDIR}/${S_DOMAIN}.crt" \
                     "${S_OUTDIR}/${S_DOMAIN}.key"
}

run_ss_ecdsa() {
    write_openssl_cnf "${S_OUTDIR}"
    info "Generating ECDSA ${S_EC_CURVE} self-signed certificate (${S_DAYS} days)…"
    openssl ecparam -name "${S_EC_CURVE}" -genkey -noout \
        -out "${S_OUTDIR}/${S_DOMAIN}.key"
    openssl req -x509 \
        -key  "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out  "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days "${S_DAYS}" \
        -subj "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "key  : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "cert : ${S_OUTDIR}/${S_DOMAIN}.crt"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
    print_nginx_hint "${S_OUTDIR}/${S_DOMAIN}.crt" \
                     "${S_OUTDIR}/${S_DOMAIN}.key"
}

run_ss_ed25519() {
    write_openssl_cnf "${S_OUTDIR}"
    info "Generating Ed25519 self-signed certificate (${S_DAYS} days)…"
    openssl genpkey -algorithm Ed25519 \
        -out "${S_OUTDIR}/${S_DOMAIN}.key"
    openssl req -x509 \
        -key  "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out  "${S_OUTDIR}/${S_DOMAIN}.crt" \
        -days "${S_DAYS}" \
        -subj "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.key"
    ok "key  : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "cert : ${S_OUTDIR}/${S_DOMAIN}.crt"
    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
    print_nginx_hint "${S_OUTDIR}/${S_DOMAIN}.crt" \
                     "${S_OUTDIR}/${S_DOMAIN}.key"
}

run_ss_ca() {
    write_openssl_cnf "${S_OUTDIR}"
    blank
    info "Step 1/3 — Creating root CA key and certificate…"

    if [[ "$S_PASSPHRASE" == "yes" ]]; then
        warn "You will be prompted for a CA key passphrase — remember it."
        openssl genrsa -aes256 -out "${S_OUTDIR}/ca.key" 4096
    else
        info "Generating CA key without passphrase…"
        openssl genrsa -out "${S_OUTDIR}/ca.key" 4096
    fi

    openssl req -x509 -new -nodes \
        -key    "${S_OUTDIR}/ca.key" \
        -sha256 -days 3650 \
        -out    "${S_OUTDIR}/ca.crt" \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG} CA/CN=${S_ORG} Root CA"
    ok "CA cert : ${S_OUTDIR}/ca.crt"
    blank

    info "Step 2/3 — Generating server key and CSR…"
    openssl genrsa -out "${S_OUTDIR}/${S_DOMAIN}.key" 4096
    openssl req -new \
        -key    "${S_OUTDIR}/${S_DOMAIN}.key" \
        -out    "${S_OUTDIR}/${S_DOMAIN}.csr" \
        -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG}/OU=${S_OU}/CN=${S_DOMAIN}" \
        -config "${S_OUTDIR}/openssl.cnf"
    ok "CSR : ${S_OUTDIR}/${S_DOMAIN}.csr"
    blank

    info "Step 3/3 — Signing certificate with local CA…"
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
    ok "key  : ${S_OUTDIR}/${S_DOMAIN}.key"
    ok "cert : ${S_OUTDIR}/${S_DOMAIN}.crt"
    blank

    warn "Distribute ${S_OUTDIR}/ca.crt to client trust stores."
    info "Debian/Ubuntu : cp ${S_OUTDIR}/ca.crt /usr/local/share/ca-certificates/my-ca.crt && update-ca-certificates"
    info "RHEL/Rocky    : cp ${S_OUTDIR}/ca.crt /etc/pki/ca-trust/source/anchors/my-ca.crt && update-ca-trust"
    info "Windows PS    : Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\\LocalMachine\\Root"

    maybe_convert_p12 "${S_OUTDIR}/${S_DOMAIN}.crt" \
                      "${S_OUTDIR}/${S_DOMAIN}.key" \
                      "${S_OUTDIR}"
    print_nginx_hint "${S_OUTDIR}/${S_DOMAIN}.crt" \
                     "${S_OUTDIR}/${S_DOMAIN}.key"
}

# ==============================================================================
# Run: key generator
# ==============================================================================
run_keygen() {
    banner
    echo -e "  ${BOLD}Generating key…${R}"
    hr; blank

    local outfile=""

    case "$S_KEYGEN_ALGO" in
        rsa)
            outfile="${S_OUTDIR}/key_rsa${S_RSA_BITS}.pem"
            info "RSA ${S_RSA_BITS} → ${outfile}"
            openssl genpkey -algorithm RSA \
                -pkeyopt "rsa_keygen_bits:${S_RSA_BITS}" \
                -out "${outfile}"
            chmod 600 "${outfile}"
            ok "Saved: ${outfile}"
            blank
            info "Public key:"
            openssl rsa -in "${outfile}" -pubout 2>/dev/null
            ;;
        ecdsa)
            outfile="${S_OUTDIR}/key_ecdsa_${S_EC_CURVE}.pem"
            info "ECDSA ${S_EC_CURVE} → ${outfile}"
            openssl genpkey -algorithm EC \
                -pkeyopt "ec_paramgen_curve:${S_EC_CURVE}" \
                -out "${outfile}"
            chmod 600 "${outfile}"
            ok "Saved: ${outfile}"
            blank
            info "Public key:"
            openssl pkey -in "${outfile}" -pubout 2>/dev/null
            ;;
        ed25519)
            outfile="${S_OUTDIR}/key_ed25519.pem"
            info "Ed25519 → ${outfile}"
            openssl genpkey -algorithm Ed25519 -out "${outfile}"
            chmod 600 "${outfile}"
            ok "Saved: ${outfile}"
            blank
            info "Public key:"
            openssl pkey -in "${outfile}" -pubout 2>/dev/null
            ;;
        rand)
            outfile="${S_OUTDIR}/rand_${S_RAND_BYTES}bytes.${S_RAND_FORMAT}"
            info "Random ${S_RAND_BYTES} bytes (${S_RAND_FORMAT}) → ${outfile}"
            local rand_val
            if [[ "$S_RAND_FORMAT" == "base64" ]]; then
                rand_val=$(openssl rand -base64 "${S_RAND_BYTES}")
            else
                rand_val=$(openssl rand -hex "${S_RAND_BYTES}")
            fi
            echo "$rand_val" > "${outfile}"
            chmod 600 "${outfile}"
            blank
            echo -e "  ${BOLD}${GREEN}${rand_val}${R}"
            blank
            ok "Saved: ${outfile}"
            ;;
    esac
}

# ==============================================================================
# Main flow with back navigation
# ==============================================================================
main() {
    require_root
    check_deps

    while true; do
        # Step 1 — method (no back from here)
        step_method

        # Step 2 — format
        step_format
        [[ "$NAV" == "back" ]] && continue

        # Step 3 — variables or keygen/simple params
        if [[ "$S_METHOD" == "keygen" || "$S_METHOD" == "ss_simple" ]]; then
            step_simple_or_keygen_params
            [[ "$NAV" == "back" ]] && continue
        else
            step_variables
            [[ "$NAV" == "back" ]] && continue
        fi

        # Step 4 — output directory
        step_outdir
        [[ "$NAV" == "back" ]] && continue

        # Step 5 — summary + confirm
        step_summary
        [[ "$NAV" == "back" ]] && continue

        # Execute
        banner
        echo -e "  ${BOLD}Executing…${R}"
        hr; blank

        case "$S_METHOD" in
            le_standalone)      run_le_standalone      ;;
            le_webroot)         run_le_webroot          ;;
            le_nginx)           run_le_nginx            ;;
            le_wildcard_manual) run_le_wildcard_manual  ;;
            le_wildcard_cf)     run_le_wildcard_cf      ;;
            ss_simple)          run_ss_simple           ;;
            ss_rsa)             run_ss_rsa              ;;
            ss_ecdsa)           run_ss_ecdsa            ;;
            ss_ed25519)         run_ss_ed25519          ;;
            ss_ca)              run_ss_ca               ;;
            keygen)             run_keygen              ;;
        esac

        blank; hr
        ok "${BOLD}Done.${R}  Output: ${WHITE}${S_OUTDIR}${R}"
        blank
        read -rp "  Press Enter to exit…" _
        exit 0
    done
}

main
