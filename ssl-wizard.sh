#!/usr/bin/env bash
# ==============================================================================
# ssl-wizard.sh — interactive SSL certificate creation wizard
# ==============================================================================
# Usage      : sudo ./ssl-wizard.sh
# Requires   : bash 4.3+. Everything else (openssl, curl, socat, acme.sh)
#              is installed by the wizard itself on first run.
# Navigation : at any step, 0 + Enter goes one step back.
# Language   : Russian / English. Asked on first run and remembered in
#              ~/.ssl-wizard-lang; override with SSLWIZ_LANG=ru|en.
# ==============================================================================
set -uo pipefail

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
# Language
#   Every user-facing helper takes the text twice: Russian first, English second.
#   With a single argument the text is printed as is (paths, command output).
# ==============================================================================
UI_LANG=""                          # ru | en
LANG_FILE="${HOME}/.ssl-wizard-lang"
MSG=""

# tl "ru" ["en"] — puts the text for the current language into MSG
tl() {
    if (( $# < 2 )) || [[ "$UI_LANG" == "ru" ]]; then
        MSG="$1"
    else
        MSG="$2"
    fi
}

# ==============================================================================
# Logging
# ==============================================================================
info()  { tl "$@"; echo -e "${CYAN}  ●${R} ${MSG}"; }
ok()    { tl "$@"; echo -e "${GREEN}  ✔${R} ${MSG}"; }
warn()  { tl "$@"; echo -e "${YELLOW}  ⚠${R} ${MSG}"; }
err()   { tl "$@"; echo -e "${RED}  ✖${R} ${MSG}" >&2; }
die()   { err "$@"; exit 1; }
blank() { echo ""; }
hr()    { echo -e "${DIM}  $(printf '%.0s─' {1..58})${R}"; }
hint()  { tl "$@"; echo -e "  ${DIM}${MSG}${R}"; }
# pad "text" WIDTH — printf %-Ns counts bytes, not letters, and breaks Cyrillic
pad()   { local n=$(( $2 - ${#1} )); (( n < 0 )) && n=0; printf '%s%*s' "$1" "$n" ""; }
# opt N "ru name" "ru description" ["en name" "en description"]
opt() {
    local name="$2" desc="${3:-}"
    if (( $# >= 5 )) && [[ "$UI_LANG" != "ru" ]]; then
        name="$4"; desc="$5"
    fi
    printf "  ${BLUE}%3s)${R}  %s ${DIM}%s${R}\n" "$1" "$(pad "$name" 24)" "$desc"
}
# okf "ru label" "en label" "value" — aligned "label : value" result line
okf()   { tl "$1" "$2"; ok "$(pad "$MSG" 11): $3"; }

# ==============================================================================
# State
# ==============================================================================
S_METHOD=""
S_FORMAT=""
S_DOMAIN=""
S_WWW=""            # yes | no
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
INSTALL_LOG="/tmp/ssl-wizard-install.log"
CMD_NAME="ssl-wizard"   # command the wizard installs itself under (see install_command)
CMD_TARGET=""           # where the command was installed (set by install_command)

# Auto-renewal and backups. SSLWIZ_DATA moves all of it into one folder.
DATA_DIR="${SSLWIZ_DATA:-/etc/ssl-wizard}"
RENEW_DIR="${DATA_DIR}/renew.d"                 # one <id>.conf per certificate
RENEW_HOOK="${DATA_DIR}/after-renew.sh"         # user's script, run after renewals
RENEW_LOG="/var/log/ssl-wizard-renew.log"
BACKUP_DIR="/var/backups/ssl-wizard"
if [[ -n "${SSLWIZ_DATA:-}" ]]; then
    RENEW_LOG="${DATA_DIR}/renew.log"
    BACKUP_DIR="${DATA_DIR}/backup"
fi
BACKUP_KEEP=30          # how many newest backup sets to keep
CRON_FILE="${SSLWIZ_CRON_FILE:-/etc/cron.d/ssl-wizard}"

declare -A METHOD_RU=(
    [le_standalone]="Let's Encrypt — автономно (порт 80)"
    [le_webroot]="Let's Encrypt — через папку сайта"
    [le_nginx]="Let's Encrypt — через nginx"
    [le_wildcard_manual]="Let's Encrypt — wildcard, DNS вручную"
    [le_wildcard_cf]="Let's Encrypt — wildcard, Cloudflare"
    [ss_simple]="Самоподписанный — быстрый"
    [ss_rsa]="Самоподписанный — RSA"
    [ss_ecdsa]="Самоподписанный — ECDSA"
    [ss_ed25519]="Самоподписанный — Ed25519"
    [ss_ca]="Свой центр сертификации + сертификат"
    [keygen]="Только ключ / случайная строка"
)
declare -A METHOD_EN=(
    [le_standalone]="Let's Encrypt — standalone (port 80)"
    [le_webroot]="Let's Encrypt — via site folder"
    [le_nginx]="Let's Encrypt — via nginx"
    [le_wildcard_manual]="Let's Encrypt — wildcard, manual DNS"
    [le_wildcard_cf]="Let's Encrypt — wildcard, Cloudflare"
    [ss_simple]="Self-signed — quick"
    [ss_rsa]="Self-signed — RSA"
    [ss_ecdsa]="Self-signed — ECDSA"
    [ss_ed25519]="Self-signed — Ed25519"
    [ss_ca]="Own certificate authority + certificate"
    [keygen]="Key / random string only"
)

# ==============================================================================
# Navigation
#   NAV    — a step sets it to "back" when the user enters 0
#   FLOW   — list of steps for the chosen method (see build_flow)
#   STEP_I / STEP_N — current step number and total (for the header)
# ==============================================================================
NAV=""
FLOW=()
STEP_I=1
STEP_N=1
RUN_RC=0

# ==============================================================================
# Helpers
# ==============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || die "Нужны права root. Запустите: sudo $0" \
                             "Root privileges required. Run: sudo $0"
}

clear_screen() { printf '\033[2J\033[H'; }

# pause ["ru" "en"]
pause() {
    local _
    if (( $# == 0 )); then
        tl "Нажмите Enter, чтобы продолжить…" "Press Enter to continue…"
    else
        tl "$@"
    fi
    read -rp "  ${MSG}" _ || exit 0
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# pick VARNAME MAX [exit]
# 0 — back: sets NAV=back and leaves the variable untouched.
# With "exit" as the third argument the prompt says 0 quits the wizard.
pick() {
    local -n __pick_ref=$1
    local max=$2 in zero your
    if [[ "${3:-}" == "exit" ]]; then
        tl "выход" "exit"
    else
        tl "назад" "back"
    fi
    zero="$MSG"
    tl "Ваш выбор" "Your choice"
    your="$MSG"
    while true; do
        printf "  %s [1-%d]  ${DIM}(0 — %s)${R}: " "$your" "$max" "$zero"
        read -r in || exit 0
        in="$(trim "$in")"
        if [[ "$in" == "0" || "$in" == "b" || "$in" == "B" ]]; then
            NAV="back"
            return 0
        fi
        if [[ "$in" =~ ^[0-9]+$ ]] && (( 10#$in >= 1 && 10#$in <= max )); then
            __pick_ref=$((10#$in))
            return 0
        fi
        warn "Введите число от 1 до ${max} или 0." "Enter a number from 1 to ${max}, or 0."
    done
}

# ask VARNAME "ru prompt" "en prompt" ["default"] [validator]
# Enter — take the value in brackets; 0 — back (NAV=back)
ask() {
    local -n __ask_ref=$1
    local default="${4:-}" check="${5:-}" prompt in
    tl "$2" "$3"
    prompt="$MSG"
    [[ -n "$__ask_ref" ]] && default="$__ask_ref"
    while true; do
        if [[ -n "$default" ]]; then
            printf "  %s ${DIM}[%s]${R}: " "$prompt" "$default"
        else
            printf "  %s: " "$prompt"
        fi
        read -r in || exit 0
        in="$(trim "$in")"
        if [[ "$in" == "0" ]]; then
            NAV="back"
            return 0
        fi
        [[ -z "$in" ]] && in="$default"
        if [[ -z "$in" ]]; then
            warn "Поле не может быть пустым." "This field cannot be empty."
            continue
        fi
        if [[ -n "$check" ]] && ! "$check" "$in"; then
            continue
        fi
        __ask_ref="$in"
        return 0
    done
}

# ==============================================================================
# Language selection
# ==============================================================================
choose_lang() {
    local c=""
    clear_screen
    echo ""
    echo -e "  ${BOLD}Язык / Language${R}"
    hr; blank
    opt 1 "Русский" ""
    opt 2 "English" ""
    blank; hr; blank
    while true; do
        printf "  [1-2]: "
        read -r c || exit 0
        c="$(trim "$c")"
        case "$c" in
            1) UI_LANG="ru"; break ;;
            2) UI_LANG="en"; break ;;
        esac
    done
    echo "$UI_LANG" > "$LANG_FILE" 2>/dev/null || true
}

# SSLWIZ_LANG wins, then the remembered choice, otherwise ask.
# load_lang noask — nobody can answer (renewal from cron): fall back to English
load_lang() {
    local saved="" mode="${1:-}"
    case "${SSLWIZ_LANG:-}" in
        ru|en) UI_LANG="$SSLWIZ_LANG"; return 0 ;;
    esac
    if [[ -f "$LANG_FILE" ]]; then
        saved="$(trim "$(cat "$LANG_FILE" 2>/dev/null)")"
    fi
    case "$saved" in
        ru|en) UI_LANG="$saved" ;;
        *)     if [[ "$mode" == "noask" ]]; then UI_LANG="en"; else choose_lang; fi ;;
    esac
}

# ==============================================================================
# Validators — print the reason and return 1 when the value does not fit
# ==============================================================================
is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

v_domain() {
    if [[ ! "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        warn "Только латинские буквы, цифры, точки и дефисы. Пример: example.com" \
             "Latin letters, digits, dots and hyphens only. Example: example.com"
        return 1
    fi
    if [[ "$S_METHOD" == le_* ]]; then
        if is_ip "$1"; then
            warn "Let's Encrypt не выдаёт сертификаты на IP. Нужен домен." \
                 "Let's Encrypt does not issue certificates for IPs. A domain is required."
            return 1
        fi
        if [[ "$1" != *.* ]]; then
            warn "Нужен настоящий домен, например example.com" \
                 "A real domain is required, e.g. example.com"
            return 1
        fi
        if [[ "$1" == www.* ]]; then
            warn "Введите домен без www — его можно добавить на следующем шаге." \
                 "Enter the domain without www — you can add it at the next step."
            return 1
        fi
    fi
    return 0
}

v_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && return 0
    warn "Это не похоже на e-mail. Пример: admin@example.com" \
         "This does not look like an e-mail. Example: admin@example.com"
    return 1
}

v_country() {
    [[ "$1" =~ ^[A-Za-z]{2}$ ]] && return 0
    warn "Нужны ровно 2 латинские буквы. Пример: RU" \
         "Exactly 2 Latin letters are required. Example: US"
    return 1
}

v_days() {
    if [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 36500 )); then
        return 0
    fi
    warn "Введите число дней от 1 до 36500." "Enter a number of days from 1 to 36500."
    return 1
}

v_bytes() {
    if [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 4096 )); then
        return 0
    fi
    warn "Введите число от 1 до 4096." "Enter a number from 1 to 4096."
    return 1
}

v_nosubj() {
    [[ "$1" != */* ]] && return 0
    warn "Символ / здесь использовать нельзя." "The / character is not allowed here."
    return 1
}

# ==============================================================================
# Banner / step header
# ==============================================================================
banner() {
    local title
    tl "Мастер создания SSL-сертификатов" "SSL Certificate Creation Wizard"
    title="$(pad "$MSG" 52)"
    clear_screen
    echo ""
    echo -e "  ${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${R}"
    echo -e "  ${BOLD}${BLUE}║${R}  ${BOLD}${WHITE}${title}${R}${BOLD}${BLUE}║${R}"
    echo -e "  ${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${R}"
    echo ""
}

# screen "ru title" "en title"
screen() {
    local title step of
    tl "$@";          title="$MSG"
    tl "Шаг" "Step";  step="$MSG"
    tl "из" "of";     of="$MSG"
    banner
    if (( STEP_I == 0 )); then
        # screens outside the step-by-step flow (folder scan)
        echo -e "  ${BOLD}${title}${R}"
    elif (( STEP_I == 1 )); then
        echo -e "  ${BOLD}${step} 1${R} — ${title}"
    else
        echo -e "  ${BOLD}${step} ${STEP_I} ${of} ${STEP_N}${R} — ${title}"
    fi
    hr; blank
}

# ==============================================================================
# DEPENDENCIES — on first run everything missing is installed automatically
# ==============================================================================
APT_UPDATED=""
DEPS_CHANGED=""

pkg_install() {
    local pkg="$1"
    {
        echo "=== $(date) — install ${pkg} ==="
        if command -v apt-get &>/dev/null; then
            if [[ -z "$APT_UPDATED" ]]; then
                apt-get update -q
                APT_UPDATED="yes"
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$pkg"
        elif command -v yum &>/dev/null; then
            yum install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm --needed "$pkg"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "$pkg"
        elif command -v zypper &>/dev/null; then
            zypper --non-interactive install "$pkg"
        else
            echo "no supported package manager found"
            return 1
        fi
    } >>"$INSTALL_LOG" 2>&1
}

# ensure_cmd COMMAND [PACKAGE] — present → ok; missing → install and re-check
ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}" label
    label="$(pad "$cmd" 10)"
    if command -v "$cmd" &>/dev/null; then
        ok "${label} установлен" "${label} installed"
        return 0
    fi
    info "${label} не найден — устанавливаю…" "${label} not found — installing…"
    DEPS_CHANGED="yes"
    if pkg_install "$pkg" && command -v "$cmd" &>/dev/null; then
        ok "${label} установлен" "${label} installed"
        return 0
    fi
    err "${label} не удалось установить (подробности: ${INSTALL_LOG})" \
        "${label} could not be installed (details: ${INSTALL_LOG})"
    return 1
}

install_acme() {
    command -v curl &>/dev/null || return 1
    local args=()
    # the acme.sh installer refuses to run without cron — use --force then
    command -v crontab &>/dev/null || args=(--force)
    curl -fsSL https://get.acme.sh | sh -s -- ${args[@]+"${args[@]}"} >>"$INSTALL_LOG" 2>&1
    [[ -f "$ACME_SH" ]] || return 1
    if ! command -v crontab &>/dev/null; then
        warn "cron не найден — автопродление сертификатов работать не будет." \
             "cron not found — automatic certificate renewal will not work."
    fi
    return 0
}

ensure_acme() {
    local label
    label="$(pad "acme.sh" 10)"
    if [[ -f "$ACME_SH" ]]; then
        ok "${label} установлен" "${label} installed"
        return 0
    fi
    info "${label} не найден — устанавливаю…" "${label} not found — installing…"
    DEPS_CHANGED="yes"
    if install_acme; then
        ok "${label} установлен в ${HOME}/.acme.sh/" "${label} installed to ${HOME}/.acme.sh/"
        return 0
    fi
    err "${label} не удалось установить (подробности: ${INSTALL_LOG})" \
        "${label} could not be installed (details: ${INSTALL_LOG})"
    return 1
}

# Puts the wizard on PATH as the "ssl-wizard" command, so it can be started
# from any folder. A copy is used rather than a symlink: the original may be
# moved or deleted. Running a newer script refreshes the copy.
# Set SSLWIZ_NO_PATH=1 to skip.
install_command() {
    [[ -n "${SSLWIZ_NO_PATH:-}" ]] && return 0

    # under sudo PATH is sudo's secure_path, and on some systems it lacks /usr/local/bin
    local dir="/usr/local/bin"
    [[ ":${PATH}:" == *":/usr/local/bin:"* ]] || dir="/usr/bin"
    local target="${dir}/${CMD_NAME}" self existed=""

    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    [[ -n "$self" ]] || self="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
    if [[ "$self" == "$target" ]]; then
        CMD_TARGET="$target"
        return 0
    fi
    [[ -e "$target" ]] && existed="yes"
    if [[ -n "$existed" ]] && cmp -s "$self" "$target" 2>/dev/null; then
        CMD_TARGET="$target"
        return 0
    fi

    if ! install -m 755 "$self" "$target" 2>>"$INSTALL_LOG"; then
        warn "Не удалось добавить команду ${CMD_NAME} в PATH (подробности: ${INSTALL_LOG})" \
             "Could not add the ${CMD_NAME} command to PATH (details: ${INSTALL_LOG})"
        return 0
    fi
    CMD_TARGET="$target"
    if [[ -z "$existed" ]]; then
        DEPS_CHANGED="yes"
        ok "Команда ${CMD_NAME} добавлена в PATH (${target})" \
           "The ${CMD_NAME} command was added to PATH (${target})"
        hint "    Теперь мастер запускается из любой папки: sudo ${CMD_NAME}" \
             "    The wizard now starts from any folder: sudo ${CMD_NAME}"
    fi
}

check_deps() {
    banner
    tl "Проверка компонентов" "Checking components"
    echo -e "  ${BOLD}${MSG}${R}"
    hint "Чего не хватает — мастер установит сам." "Anything missing is installed automatically."
    hr; blank

    local failed=""
    ensure_cmd openssl || failed="yes"
    ensure_cmd curl    || failed="yes"
    ensure_cmd socat   || failed="yes"
    ensure_acme        || failed="yes"
    install_command

    if ! command -v openssl &>/dev/null; then
        blank
        die "Без openssl мастер работать не может. Установите его вручную и запустите снова." \
            "The wizard cannot work without openssl. Install it manually and run again."
    fi

    if [[ -n "$failed" ]]; then
        blank
        warn "Часть компонентов не установлена — некоторые способы Let's Encrypt" \
             "Some components are missing — some Let's Encrypt methods"
        warn "будут недоступны. Самоподписанные сертификаты работают." \
             "will be unavailable. Self-signed certificates still work."
        blank
        pause
    elif [[ -n "$DEPS_CHANGED" ]]; then
        blank
        ok "Все компоненты готовы." "All components are ready."
        blank
        pause
    fi
}

# Check before entering a method: is everything it needs in place
method_ready() {
    if [[ "$S_METHOD" == le_* ]]; then
        if [[ ! -f "$ACME_SH" ]] && ! install_acme; then
            err "Не удалось установить acme.sh (нужен интернет). Лог: ${INSTALL_LOG}" \
                "Could not install acme.sh (internet required). Log: ${INSTALL_LOG}"
            return 1
        fi
    fi
    if [[ "$S_METHOD" == "le_standalone" ]] && ! command -v socat &>/dev/null; then
        if ! pkg_install socat || ! command -v socat &>/dev/null; then
            err "Для этого способа нужен socat, установить его не удалось." \
                "This method needs socat, and it could not be installed."
            return 1
        fi
    fi
    if [[ "$S_METHOD" == "le_nginx" ]] && ! command -v nginx &>/dev/null; then
        err "nginx не установлен. Выберите способ 1 или сначала настройте nginx." \
            "nginx is not installed. Choose method 1 or set up nginx first."
        return 1
    fi
    return 0
}

# ==============================================================================
# STEPS — each step is one screen. 0 → NAV=back → main goes one step back
# ==============================================================================
step_method() {
    local methods=(le_standalone le_webroot le_nginx le_wildcard_manual le_wildcard_cf
                   ss_simple ss_rsa ss_ecdsa ss_ed25519 ss_ca keygen)
    while true; do
        screen "Какой сертификат нужен?" "Which certificate do you need?"

        tl "— бесплатный, браузеры ему доверяют." "— free, trusted by browsers."
        echo -e "  ${BOLD}${CYAN}Let's Encrypt${R} ${DIM}${MSG}${R}"
        hint "Нужен свой домен, направленный на этот сервер. Срок 90 дней." \
             "Needs your own domain pointing to this server. Valid 90 days."
        opt 1 "Автономно"             "порт 80 свободен, веб-сервера нет" \
              "Standalone"            "port 80 is free, no web server running"
        opt 2 "Через папку сайта"     "сайт уже работает, останавливать нельзя" \
              "Via site folder"       "site is already running, cannot be stopped"
        opt 3 "Через nginx"           "nginx установлен, всё сделается само" \
              "Via nginx"             "nginx is installed, fully automatic"
        opt 4 "Wildcard, DNS вручную" "*.домен; запись в DNS добавляете сами" \
              "Wildcard, manual DNS"  "*.domain; you add the DNS record yourself"
        opt 5 "Wildcard, Cloudflare"  "*.домен; автоматически по токену" \
              "Wildcard, Cloudflare"  "*.domain; automatic via API token"
        blank
        tl "— для тестов и внутренней сети." "— for testing and internal networks."
        local ss_desc="$MSG"
        tl "Самоподписанный" "Self-signed"
        echo -e "  ${BOLD}${MAGENTA}${MSG}${R} ${DIM}${ss_desc}${R}"
        hint "Домен не нужен. Браузер покажет предупреждение." \
             "No domain needed. Browsers will show a warning."
        opt 6 "Быстрый"               "всего 3 вопроса" \
              "Quick"                 "just 3 questions"
        opt 7 "RSA"                   "работает везде; не знаете — берите его" \
              "RSA"                   "works everywhere; pick this if unsure"
        opt 8 "ECDSA"                 "быстрее и компактнее, для новых систем" \
              "ECDSA"                 "faster and smaller, for modern systems"
        opt 9 "Ed25519"               "самый новый; браузеры не поддерживают" \
              "Ed25519"               "newest; not supported by browsers"
        opt 10 "Свой центр (CA)"      "без предупреждений на своих компьютерах" \
               "Own authority (CA)"   "no warnings on your own computers"
        blank
        tl "Прочее" "Other"
        echo -e "  ${BOLD}${WHITE}${MSG}${R}"
        opt 11 "Ключ или пароль"      "только ключ или случайная строка" \
               "Key or password"      "a key or a random string only"
        opt 12 "Сканировать папку"    "найти сертификаты и поставить на автопродление" \
               "Scan a folder"        "find certificates and put them on auto-renewal"
        opt 13 "Язык / Language"      "English" \
               "Язык / Language"      "Русский"
        blank; hr; blank

        local c=""
        pick c 13 exit
        [[ "$NAV" == "back" ]] && return 0

        if [[ "$c" == "12" ]]; then
            step_scan
            continue
        fi
        if [[ "$c" == "13" ]]; then
            choose_lang
            continue
        fi

        S_METHOD="${methods[$((c - 1))]}"
        method_ready && return 0
        blank
        pause "Нажмите Enter, чтобы выбрать другой способ…" "Press Enter to choose another method…"
    done
}

step_format() {
    screen "В каком виде сохранить файлы?" "How should the files be saved?"
    opt 1 "Обычный (.crt + .key)" "nginx, Apache — подходит почти всегда" \
          "Regular (.crt + .key)" "nginx, Apache — fits almost always"
    opt 2 "fullchain + privkey"   "те же файлы с именами как у Let's Encrypt" \
          "fullchain + privkey"   "same files, named the Let's Encrypt way"
    opt 3 "PKCS#12 (.p12)"        "один файл для Windows, IIS, Java" \
          "PKCS#12 (.p12)"        "a single file for Windows, IIS, Java"
    blank
    hint "Не знаете — выбирайте 1. Для .p12 файлы .crt и .key тоже сохранятся." \
         "If unsure, choose 1. With .p12 the .crt and .key files are saved too."
    blank; hr; blank

    local c=""
    pick c 3
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_FORMAT="pem"    ;;
        2) S_FORMAT="bundle" ;;
        3) S_FORMAT="p12"    ;;
    esac
}

step_domain() {
    screen "Для какого адреса сертификат?" "Which address is the certificate for?"
    case "$S_METHOD" in
        le_wildcard_*)
            hint "Введите основной домен, например example.com" \
                 "Enter the base domain, e.g. example.com"
            hint "Сертификат подойдёт для него и всех поддоменов (*.example.com)." \
                 "The certificate will cover it and all subdomains (*.example.com)."
            ;;
        le_*)
            hint "Введите домен без www, например example.com" \
                 "Enter the domain without www, e.g. example.com"
            hint "Он уже должен открываться с этого сервера." \
                 "It must already point to this server."
            ;;
        *)
            hint "Домен или IP, по которому открывают сервер." \
                 "The domain or IP used to reach the server."
            hint "Примеры: example.local, 192.168.1.10" \
                 "Examples: example.local, 192.168.1.10"
            ;;
    esac
    hint "0 — назад." "0 — back."
    blank
    ask S_DOMAIN "Домен" "Domain" "" v_domain
}

step_www() {
    screen "Добавить адрес с www?" "Add the www address too?"
    opt 1 "Да"  "сертификат для ${S_DOMAIN} и www.${S_DOMAIN}" \
          "Yes" "certificate for ${S_DOMAIN} and www.${S_DOMAIN}"
    opt 2 "Нет" "только ${S_DOMAIN}" \
          "No"  "${S_DOMAIN} only"
    blank
    hint "«Да» выбирайте, только если www.${S_DOMAIN} тоже ведёт на этот сервер," \
         "Choose Yes only if www.${S_DOMAIN} also points to this server,"
    hint "иначе выпуск завершится ошибкой." \
         "otherwise issuance will fail."
    blank; hr; blank

    local c=""
    pick c 2
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_WWW="yes" ;;
        2) S_WWW="no"  ;;
    esac
}

step_email() {
    screen "Ваш e-mail" "Your e-mail"
    hint "На него Let's Encrypt напомнит, если сертификат скоро истечёт." \
         "Let's Encrypt will use it to warn you before the certificate expires."
    hint "0 — назад." "0 — back."
    blank
    ask S_EMAIL "E-mail" "E-mail" "" v_email
}

step_webroot() {
    screen "Папка сайта" "Site folder"
    hint "Папка, из которой веб-сервер отдаёт файлы сайта." \
         "The folder your web server serves the site files from."
    hint "Мастер положит туда временный файл для проверки домена." \
         "The wizard puts a temporary file there to verify the domain."
    hint "Enter — оставить значение в скобках, 0 — назад." \
         "Enter — keep the value in brackets, 0 — back."
    blank
    ask S_WEBROOT "Путь к папке" "Folder path" "/var/www/html"
}

step_cf_token() {
    screen "Токен Cloudflare" "Cloudflare token"
    hint "Нужен, чтобы мастер сам добавил проверочную запись в DNS." \
         "Lets the wizard add the verification DNS record for you."
    hint "Где взять: Cloudflare → My Profile → API Tokens → Create Token" \
         "Where to get it: Cloudflare → My Profile → API Tokens → Create Token"
    hint "→ шаблон «Edit zone DNS» → выбрать свой домен." \
         "→ \"Edit zone DNS\" template → select your domain."
    hint "Токен нигде не сохраняется. 0 — назад." \
         "The token is not stored anywhere. 0 — back."
    blank
    S_CF_TOKEN=""
    ask S_CF_TOKEN "API-токен" "API token"
}

step_subject() {
    screen "Сведения о владельце" "Owner details"
    hint "Это просто подписи внутри сертификата, на работу не влияют." \
         "These are just labels inside the certificate; they do not affect how it works."
    hint "Не знаете, что писать — жмите Enter. 0 — назад к прошлому вопросу." \
         "If unsure, just press Enter. 0 — back to the previous question."
    blank

    local vars=(S_COUNTRY S_STATE S_CITY S_ORG S_OU)
    local prompts_ru=("Страна (2 буквы)" "Регион" "Город" "Организация" "Отдел")
    local prompts_en=("Country (2 letters)" "State / region" "City" "Organization" "Department")
    local defaults=("RU" "Moscow" "Moscow" "MyCompany" "IT")
    [[ "$UI_LANG" != "ru" ]] && defaults=("US" "New York" "New York" "MyCompany" "IT")
    local checks=(v_country v_nosubj v_nosubj v_nosubj v_nosubj)
    local j=0
    while (( j < ${#vars[@]} )); do
        NAV=""
        ask "${vars[$j]}" "${prompts_ru[$j]}" "${prompts_en[$j]}" "${defaults[$j]}" "${checks[$j]}"
        if [[ "$NAV" == "back" ]]; then
            # from the first question — to the previous step, otherwise — previous question
            (( j == 0 )) && return 0
            j=$((j - 1))
            NAV=""
        else
            j=$((j + 1))
        fi
    done
    S_COUNTRY="${S_COUNTRY^^}"
}

step_days() {
    screen "Срок действия" "Validity period"
    hint "Сколько дней сертификат будет действовать." \
         "How many days the certificate stays valid."
    hint "365 — год. Браузеры не принимают срок больше 398 дней." \
         "365 is one year. Browsers reject anything longer than 398 days."
    hint "Enter — оставить значение в скобках, 0 — назад." \
         "Enter — keep the value in brackets, 0 — back."
    blank
    ask S_DAYS "Дней" "Days" "365" v_days
}

step_rsa_bits() {
    screen "Длина ключа RSA" "RSA key size"
    hint "Чем длиннее ключ, тем надёжнее, но медленнее." \
         "A longer key is stronger but slower."
    blank
    opt 1 "2048 бит"  "быстро и достаточно надёжно — обычный выбор" \
          "2048 bits" "fast and strong enough — the usual choice"
    opt 2 "3072 бит"  "с запасом на будущее" \
          "3072 bits" "extra margin for the future"
    opt 3 "4096 бит"  "максимум защиты, заметно медленнее" \
          "4096 bits" "maximum protection, noticeably slower"
    blank; hr; blank

    local c=""
    pick c 3
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_RSA_BITS="2048" ;;
        2) S_RSA_BITS="3072" ;;
        3) S_RSA_BITS="4096" ;;
    esac
}

step_ec_curve() {
    screen "Кривая ECDSA" "ECDSA curve"
    hint "Кривая определяет стойкость ключа." "The curve determines key strength."
    blank
    opt 1 "P-256" "поддерживается везде — обычный выбор" \
          "P-256" "supported everywhere — the usual choice"
    opt 2 "P-384" "надёжнее, чуть медленнее" \
          "P-384" "stronger, slightly slower"
    opt 3 "P-521" "максимум; поддерживается не везде" \
          "P-521" "maximum; not supported everywhere"
    blank; hr; blank

    local c=""
    pick c 3
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_EC_CURVE="prime256v1" ;;
        2) S_EC_CURVE="secp384r1"  ;;
        3) S_EC_CURVE="secp521r1"  ;;
    esac
}

step_ca_pass() {
    screen "Пароль на ключ центра сертификации" "Password for the CA key"
    hint "Ключом CA подписываются все ваши сертификаты — его стоит беречь." \
         "The CA key signs all your certificates — keep it safe."
    blank
    opt 1 "С паролем"        "безопаснее; пароль спросят при каждом выпуске" \
          "With password"    "safer; asked every time you issue a certificate"
    opt 2 "Без пароля"       "удобнее; годится для тестов" \
          "Without password" "more convenient; fine for testing"
    blank
    hint "Если в папке уже есть ca.key и ca.crt, мастер возьмёт их." \
         "If the folder already has ca.key and ca.crt, the wizard reuses them."
    blank; hr; blank

    local c=""
    pick c 2
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_PASSPHRASE="yes" ;;
        2) S_PASSPHRASE="no"  ;;
    esac
}

step_keygen_algo() {
    screen "Что создать?" "What to create?"
    opt 1 "Ключ RSA"         "классический, работает везде" \
          "RSA key"          "classic, works everywhere"
    opt 2 "Ключ ECDSA"       "современный, короткий и быстрый" \
          "ECDSA key"        "modern, short and fast"
    opt 3 "Ключ Ed25519"     "самый новый, настроек нет" \
          "Ed25519 key"      "newest, nothing to configure"
    opt 4 "Случайная строка" "для паролей, токенов и секретов" \
          "Random string"    "for passwords, tokens and secrets"
    blank; hr; blank

    local c=""
    pick c 4
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_KEYGEN_ALGO="rsa"     ;;
        2) S_KEYGEN_ALGO="ecdsa"   ;;
        3) S_KEYGEN_ALGO="ed25519" ;;
        4) S_KEYGEN_ALGO="rand"    ;;
    esac
}

step_rand_format() {
    screen "Вид случайной строки" "Random string format"
    opt 1 "base64" "буквы, цифры и знаки + / = — строка короче" \
          "base64" "letters, digits and + / = — shorter string"
    opt 2 "hex"    "только цифры и буквы a–f — подходит везде" \
          "hex"    "digits and letters a–f only — works everywhere"
    blank; hr; blank

    local c=""
    pick c 2
    [[ "$NAV" == "back" ]] && return 0
    case "$c" in
        1) S_RAND_FORMAT="base64" ;;
        2) S_RAND_FORMAT="hex"    ;;
    esac
}

step_rand_bytes() {
    screen "Длина случайной строки" "Random string length"
    hint "Сколько случайных байт взять. 32 — хороший пароль или секрет." \
         "How many random bytes to take. 32 makes a good password or secret."
    hint "Enter — оставить значение в скобках, 0 — назад." \
         "Enter — keep the value in brackets, 0 — back."
    blank
    ask S_RAND_BYTES "Байт" "Bytes" "32" v_bytes
}

step_outdir() {
    screen "Куда сохранить файлы?" "Where to save the files?"
    # the current folder, not the script's: the script may be running from PATH
    opt 1 "Текущая папка"       "${PWD}" \
          "Current folder"      "${PWD}"
    opt 2 "Другая папка"        "указать путь вручную" \
          "Another folder"      "enter the path manually"
    blank; hr; blank

    while true; do
        local c=""
        pick c 2
        [[ "$NAV" == "back" ]] && return 0
        if [[ "$c" == "1" ]]; then
            S_OUTDIR="${PWD}"
            return 0
        fi
        blank
        hint "Полный путь, например /etc/ssl/mysite. Папка создастся сама." \
             "Full path, e.g. /etc/ssl/mysite. The folder is created automatically."
        hint "0 — назад к выбору." "0 — back to the choice."
        local dir=""
        ask dir "Путь к папке" "Folder path"
        if [[ "$NAV" == "back" ]]; then
            NAV=""
            blank
            continue
        fi
        S_OUTDIR="${dir%/}"
        [[ -z "$S_OUTDIR" ]] && S_OUTDIR="/"
        return 0
    done
}

in_flow() {
    local s
    for s in "${FLOW[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# row "ru label" "en label" "value"
row() {
    tl "$1" "$2"
    echo -e "  ${DIM}$(pad "$MSG" 13):${R}  ${WHITE}$3${R}"
}

# rowl "ru label" "en label" "ru value" "en value"
rowl() {
    local value
    tl "$3" "$4"; value="$MSG"
    row "$1" "$2" "$value"
}

step_summary() {
    screen "Проверьте данные" "Review your choices"
    if [[ "$UI_LANG" == "ru" ]]; then
        row "Способ" "Method" "${METHOD_RU[$S_METHOD]}"
    else
        row "Способ" "Method" "${METHOD_EN[$S_METHOD]}"
    fi
    if in_flow step_format; then
        case "$S_FORMAT" in
            pem)    row "Файлы" "Files" ".crt + .key" ;;
            bundle) row "Файлы" "Files" "fullchain.pem + privkey.pem" ;;
            p12)    row "Файлы" "Files" ".crt + .key + .p12" ;;
        esac
    fi
    if in_flow step_domain; then
        case "$S_METHOD" in
            le_wildcard_*) rowl "Домен" "Domain" "${S_DOMAIN} и *.${S_DOMAIN}" "${S_DOMAIN} and *.${S_DOMAIN}" ;;
            *)             row  "Домен" "Domain" "${S_DOMAIN}" ;;
        esac
    fi
    if in_flow step_www && [[ "$S_WWW" == "yes" ]]; then
        row "Плюс" "Plus" "www.${S_DOMAIN}"
    fi
    in_flow step_email    && row  "E-mail" "E-mail" "${S_EMAIL}"
    in_flow step_webroot  && row  "Папка сайта" "Site folder" "${S_WEBROOT}"
    in_flow step_cf_token && rowl "Токен" "Token" "введён" "entered"
    if in_flow step_subject; then
        row "Владелец" "Owner" "${S_ORG}, ${S_OU}"
        row "Место" "Location" "${S_COUNTRY}, ${S_STATE}, ${S_CITY}"
    fi
    in_flow step_days     && rowl "Срок" "Validity" "${S_DAYS} дн." "${S_DAYS} days"
    if [[ "$S_METHOD" == "keygen" ]]; then
        case "$S_KEYGEN_ALGO" in
            rsa)     rowl "Создать" "Create" "ключ RSA" "RSA key" ;;
            ecdsa)   rowl "Создать" "Create" "ключ ECDSA" "ECDSA key" ;;
            ed25519) rowl "Создать" "Create" "ключ Ed25519" "Ed25519 key" ;;
            rand)    rowl "Создать" "Create" \
                          "случайную строку, ${S_RAND_BYTES} байт, ${S_RAND_FORMAT}" \
                          "random string, ${S_RAND_BYTES} bytes, ${S_RAND_FORMAT}" ;;
        esac
    fi
    in_flow step_rsa_bits && rowl "Ключ RSA" "RSA key" "${S_RSA_BITS} бит" "${S_RSA_BITS} bits"
    in_flow step_ec_curve && row  "Кривая" "Curve" "${S_EC_CURVE}"
    if in_flow step_ca_pass; then
        if [[ "$S_PASSPHRASE" == "yes" ]]; then
            rowl "Ключ CA" "CA key" "с паролем" "with password"
        else
            rowl "Ключ CA" "CA key" "без пароля" "without password"
        fi
    fi
    row "Папка" "Folder" "${S_OUTDIR}"
    blank; hr; blank
    opt 1 "Создать" "всё верно, начинаем" \
          "Create"  "all correct, go ahead"
    blank

    local c=""
    pick c 1
    return 0
}

# ==============================================================================
# Flow — which steps run, and in what order, for the chosen method.
# Rebuilt before every step: the list depends on the answers given so far.
# ==============================================================================
build_flow() {
    FLOW=(step_method)
    case "$S_METHOD" in
        "") return 0 ;;
        le_standalone|le_nginx)
            FLOW+=(step_format step_domain step_www step_email) ;;
        le_webroot)
            FLOW+=(step_format step_domain step_www step_email step_webroot) ;;
        le_wildcard_manual)
            FLOW+=(step_format step_domain step_email) ;;
        le_wildcard_cf)
            FLOW+=(step_format step_domain step_email step_cf_token) ;;
        ss_simple)
            FLOW+=(step_domain step_rsa_bits step_days) ;;
        ss_rsa)
            FLOW+=(step_format step_domain step_subject step_days step_rsa_bits) ;;
        ss_ecdsa)
            FLOW+=(step_format step_domain step_subject step_days step_ec_curve) ;;
        ss_ed25519)
            FLOW+=(step_format step_domain step_subject step_days) ;;
        ss_ca)
            FLOW+=(step_format step_domain step_subject step_days step_ca_pass) ;;
        keygen)
            FLOW+=(step_keygen_algo)
            case "$S_KEYGEN_ALGO" in
                rsa)   FLOW+=(step_rsa_bits) ;;
                ecdsa) FLOW+=(step_ec_curve) ;;
                rand)  FLOW+=(step_rand_format step_rand_bytes) ;;
            esac
            ;;
    esac
    FLOW+=(step_outdir step_summary)
}

# ==============================================================================
# Output file names — depend on the chosen format
# ==============================================================================
CERT_OUT=""
KEY_OUT=""

set_out_names() {
    if [[ "$S_FORMAT" == "bundle" ]]; then
        CERT_OUT="${S_OUTDIR}/${S_DOMAIN}_fullchain.pem"
        KEY_OUT="${S_OUTDIR}/${S_DOMAIN}_privkey.pem"
    else
        CERT_OUT="${S_OUTDIR}/${S_DOMAIN}.crt"
        KEY_OUT="${S_OUTDIR}/${S_DOMAIN}.key"
    fi
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
utf8               = yes
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
OPENSSLCNF
    # an IP goes into SAN as IP.1, a domain — as DNS entries
    if is_ip "$S_DOMAIN"; then
        echo "IP.1 = ${S_DOMAIN}" >> "${dir}/openssl.cnf"
    else
        cat >> "${dir}/openssl.cnf" <<OPENSSLCNF_DNS
DNS.1 = ${S_DOMAIN}
DNS.2 = www.${S_DOMAIN}
DNS.3 = *.${S_DOMAIN}
OPENSSLCNF_DNS
    fi
}

# ==============================================================================
# PKCS#12 conversion
# ==============================================================================
maybe_convert_p12() {
    local cert="$1" key="$2" note
    [[ "$S_FORMAT" == "p12" ]] || return 0
    info "Собираю файл PKCS#12…" "Building the PKCS#12 file…"
    openssl pkcs12 -export \
        -in    "$cert" \
        -inkey "$key" \
        -out   "${S_OUTDIR}/${S_DOMAIN}.p12" \
        -name  "$S_DOMAIN" \
        -passout pass:
    chmod 600 "${S_OUTDIR}/${S_DOMAIN}.p12"
    tl "(без пароля)" "(no password)"; note="$MSG"
    okf "p12" "p12" "${S_OUTDIR}/${S_DOMAIN}.p12  ${note}"
}

# ==============================================================================
# nginx directives hint
# ==============================================================================
print_nginx_hint() {
    local cert="$1" key="$2"
    blank; hr
    tl "Строки для конфигурации nginx:" "Lines for the nginx configuration:"
    echo -e "  ${BOLD}${MSG}${R}"
    echo -e "  ${DIM}ssl_certificate${R}     ${WHITE}${cert}${R};"
    echo -e "  ${DIM}ssl_certificate_key${R} ${WHITE}${key}${R};"
    hr
}

# ==============================================================================
# Run: acme.sh methods
# ==============================================================================
# acme.sh returns 2 when the certificate exists and is still fresh — not an error
acme() {
    local rc=0
    "$ACME_SH" "$@" --server letsencrypt || rc=$?
    if (( rc != 0 && rc != 2 )); then
        return "$rc"
    fi
    return 0
}

le_domains() {
    LE_DOMAINS=(--domain "${S_DOMAIN}")
    if [[ "$S_WWW" == "yes" ]]; then
        LE_DOMAINS+=(--domain "www.${S_DOMAIN}")
    fi
}

copy_acme_files() {
    local acme_dir="${HOME}/.acme.sh/${S_DOMAIN}_ecc"
    [[ -d "$acme_dir" ]] || acme_dir="${HOME}/.acme.sh/${S_DOMAIN}"
    [[ -d "$acme_dir" ]] || die "Не найдена папка acme.sh с сертификатом: ${acme_dir}" \
                                "acme.sh certificate folder not found: ${acme_dir}"

    local fullchain="${acme_dir}/fullchain.cer"
    local key="${acme_dir}/${S_DOMAIN}.key"
    [[ -f "$fullchain" ]] || fullchain="${acme_dir}/${S_DOMAIN}.cer"
    [[ -f "$fullchain" && -f "$key" ]] || die "Сертификат не был выпущен — смотрите сообщения acme.sh выше." \
                                              "The certificate was not issued — see the acme.sh messages above."

    set_out_names
    cp "${fullchain}" "${CERT_OUT}"
    cp "${key}"       "${KEY_OUT}"
    chmod 600 "${KEY_OUT}"
    okf "сертификат" "certificate" "${CERT_OUT}"
    okf "ключ" "key" "${KEY_OUT}"
    if [[ -f "${acme_dir}/ca.cer" ]]; then
        cp "${acme_dir}/ca.cer" "${S_OUTDIR}/${S_DOMAIN}_chain.pem"
        okf "цепочка" "chain" "${S_OUTDIR}/${S_DOMAIN}_chain.pem"
    fi
    maybe_convert_p12 "${CERT_OUT}" "${KEY_OUT}"
    print_nginx_hint  "${CERT_OUT}" "${KEY_OUT}"
    blank
    info "acme.sh будет продлевать сертификат сам. После продления скопируйте" \
         "acme.sh renews the certificate by itself. After a renewal, copy the"
    info "новые файлы или настройте: acme.sh --install-cert (см. README)." \
         "new files or set up: acme.sh --install-cert (see README)."
}

run_le_standalone() {
    le_domains
    info "Получаю сертификат для ${S_DOMAIN} (порт 80 должен быть свободен)…" \
         "Requesting a certificate for ${S_DOMAIN} (port 80 must be free)…"
    acme --issue --standalone "${LE_DOMAINS[@]}" --accountemail "${S_EMAIL}"
    copy_acme_files
}

run_le_webroot() {
    le_domains
    mkdir -p "${S_WEBROOT}/.well-known/acme-challenge"
    info "Получаю сертификат для ${S_DOMAIN} через папку ${S_WEBROOT}…" \
         "Requesting a certificate for ${S_DOMAIN} via folder ${S_WEBROOT}…"
    acme --issue --webroot "${S_WEBROOT}" "${LE_DOMAINS[@]}" --accountemail "${S_EMAIL}"
    copy_acme_files
}

run_le_nginx() {
    le_domains
    info "Получаю сертификат для ${S_DOMAIN} через nginx…" \
         "Requesting a certificate for ${S_DOMAIN} via nginx…"
    acme --issue --nginx "${LE_DOMAINS[@]}" --accountemail "${S_EMAIL}"
    copy_acme_files
}

run_le_wildcard_manual() {
    info "Запрашиваю проверочные записи для ${S_DOMAIN}…" \
         "Requesting verification records for ${S_DOMAIN}…"
    blank
    # the first run only prints the TXT records and exits with an error — by design
    "$ACME_SH" --issue --dns \
        --domain "${S_DOMAIN}" \
        --domain "*.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}" \
        --server letsencrypt \
        --yes-I-know-dns-manual-mode-enough-go-ahead-please || true
    blank; hr
    warn "Добавьте в DNS домена TXT-записи, показанные выше:" \
         "Add the TXT records shown above to the domain's DNS:"
    info "имя: _acme-challenge.${S_DOMAIN}   значение: строка «TXT value»" \
         "name: _acme-challenge.${S_DOMAIN}   value: the \"TXT value\" string"
    info "Подождите 2–5 минут, пока записи разойдутся." \
         "Wait 2–5 minutes for the records to propagate."
    hr; blank
    pause "Нажмите Enter, когда записи добавлены…" "Press Enter once the records are added…"
    acme --renew \
        --domain "${S_DOMAIN}" \
        --yes-I-know-dns-manual-mode-enough-go-ahead-please
    copy_acme_files
}

run_le_wildcard_cf() {
    info "Получаю wildcard-сертификат для ${S_DOMAIN} через Cloudflare…" \
         "Requesting a wildcard certificate for ${S_DOMAIN} via Cloudflare…"
    export CF_Token="${S_CF_TOKEN}"
    acme --issue --dns dns_cf \
        --domain "${S_DOMAIN}" \
        --domain "*.${S_DOMAIN}" \
        --accountemail "${S_EMAIL}"
    copy_acme_files
}

# ==============================================================================
# Run: simple self-signed — no passphrase (genrsa → CSR → x509)
# ==============================================================================
run_ss_simple() {
    info "1/3 — создаю ключ RSA ${S_RSA_BITS} бит…" \
         "1/3 — generating a ${S_RSA_BITS}-bit RSA key…"
    openssl genrsa -out "${S_OUTDIR}/privkey.pem" "${S_RSA_BITS}"
    chmod 600 "${S_OUTDIR}/privkey.pem"
    okf "ключ" "key" "${S_OUTDIR}/privkey.pem"
    blank

    info "2/3 — создаю запрос на сертификат (CSR)…" \
         "2/3 — creating the certificate signing request (CSR)…"
    openssl req -new \
        -key  "${S_OUTDIR}/privkey.pem" \
        -out  "${S_OUTDIR}/cert.csr" \
        -subj "/CN=${S_DOMAIN}"
    okf "запрос" "request" "${S_OUTDIR}/cert.csr"
    blank

    info "3/3 — подписываю сертификат на ${S_DAYS} дн.…" \
         "3/3 — signing the certificate for ${S_DAYS} days…"
    openssl x509 -req \
        -days    "${S_DAYS}" \
        -in      "${S_OUTDIR}/cert.csr" \
        -signkey "${S_OUTDIR}/privkey.pem" \
        -out     "${S_OUTDIR}/fullchain.pem"
    okf "сертификат" "certificate" "${S_OUTDIR}/fullchain.pem"
    print_nginx_hint "${S_OUTDIR}/fullchain.pem" "${S_OUTDIR}/privkey.pem"
}

# ==============================================================================
# Run: self-signed methods
# ==============================================================================
# gen_key ALGORITHM FILE
gen_key() {
    case "$1" in
        rsa)
            openssl genpkey -algorithm RSA \
                -pkeyopt "rsa_keygen_bits:${S_RSA_BITS}" -out "$2" ;;
        ecdsa)
            openssl genpkey -algorithm EC \
                -pkeyopt "ec_paramgen_curve:${S_EC_CURVE}" -out "$2" ;;
        ed25519)
            openssl genpkey -algorithm Ed25519 -out "$2" ;;
    esac
    chmod 600 "$2"
}

# run_ss ALGORITHM — key + self-signed certificate with SAN
run_ss() {
    set_out_names
    write_openssl_cnf "${S_OUTDIR}"
    info "Создаю ключ и сертификат на ${S_DAYS} дн.…" \
         "Creating the key and a certificate for ${S_DAYS} days…"
    gen_key "$1" "${KEY_OUT}"
    openssl req -x509 -new \
        -key  "${KEY_OUT}" \
        -out  "${CERT_OUT}" \
        -days "${S_DAYS}" \
        -extensions v3_req \
        -config "${S_OUTDIR}/openssl.cnf"
    okf "ключ" "key" "${KEY_OUT}"
    okf "сертификат" "certificate" "${CERT_OUT}"
    maybe_convert_p12 "${CERT_OUT}" "${KEY_OUT}"
    print_nginx_hint  "${CERT_OUT}" "${KEY_OUT}"
}

run_ss_rsa()     { run_ss rsa; }
run_ss_ecdsa()   { run_ss ecdsa; }
run_ss_ed25519() { run_ss ed25519; }

run_ss_ca() {
    set_out_names
    write_openssl_cnf "${S_OUTDIR}"

    if [[ -f "${S_OUTDIR}/ca.key" && -f "${S_OUTDIR}/ca.crt" ]]; then
        info "1/3 — в папке уже есть центр сертификации (ca.key, ca.crt) — использую его." \
             "1/3 — the folder already has a CA (ca.key, ca.crt) — reusing it."
    else
        info "1/3 — создаю центр сертификации (CA)…" \
             "1/3 — creating the certificate authority (CA)…"
        if [[ "$S_PASSPHRASE" == "yes" ]]; then
            warn "Сейчас openssl попросит придумать пароль для ключа CA — запомните его." \
                 "openssl will now ask you to set a password for the CA key — remember it."
            openssl genrsa -aes256 -out "${S_OUTDIR}/ca.key" 4096
        else
            openssl genrsa -out "${S_OUTDIR}/ca.key" 4096
        fi
        chmod 600 "${S_OUTDIR}/ca.key"
        openssl req -x509 -new -nodes -utf8 \
            -key    "${S_OUTDIR}/ca.key" \
            -sha256 -days 3650 \
            -out    "${S_OUTDIR}/ca.crt" \
            -subj   "/C=${S_COUNTRY}/ST=${S_STATE}/L=${S_CITY}/O=${S_ORG} CA/CN=${S_ORG} Root CA"
    fi
    okf "CA" "CA" "${S_OUTDIR}/ca.crt"
    blank

    info "2/3 — создаю ключ сервера и запрос на сертификат…" \
         "2/3 — creating the server key and signing request…"
    openssl genrsa -out "${KEY_OUT}" 4096
    chmod 600 "${KEY_OUT}"
    openssl req -new \
        -key    "${KEY_OUT}" \
        -out    "${S_OUTDIR}/${S_DOMAIN}.csr" \
        -config "${S_OUTDIR}/openssl.cnf"
    okf "запрос" "request" "${S_OUTDIR}/${S_DOMAIN}.csr"
    blank

    info "3/3 — подписываю сертификат своим CA…" \
         "3/3 — signing the certificate with your CA…"
    local signed="${S_OUTDIR}/${S_DOMAIN}.crt"
    openssl x509 -req \
        -in         "${S_OUTDIR}/${S_DOMAIN}.csr" \
        -CA         "${S_OUTDIR}/ca.crt" \
        -CAkey      "${S_OUTDIR}/ca.key" \
        -CAcreateserial \
        -out        "${signed}" \
        -days       "${S_DAYS}" \
        -sha256 \
        -extensions v3_req \
        -extfile    "${S_OUTDIR}/openssl.cnf"
    if [[ "$S_FORMAT" == "bundle" ]]; then
        # fullchain = server certificate + CA certificate
        cat "${signed}" "${S_OUTDIR}/ca.crt" > "${CERT_OUT}"
        rm -f "${signed}"
    fi
    okf "ключ" "key" "${KEY_OUT}"
    okf "сертификат" "certificate" "${CERT_OUT}"
    maybe_convert_p12 "${CERT_OUT}" "${KEY_OUT}"
    print_nginx_hint  "${CERT_OUT}" "${KEY_OUT}"

    blank
    warn "Чтобы не было предупреждений, установите ${S_OUTDIR}/ca.crt на свои компьютеры:" \
         "To get rid of browser warnings, install ${S_OUTDIR}/ca.crt on your computers:"
    info "Debian/Ubuntu : cp ca.crt /usr/local/share/ca-certificates/my-ca.crt && update-ca-certificates"
    info "RHEL/Rocky    : cp ca.crt /etc/pki/ca-trust/source/anchors/my-ca.crt && update-ca-trust"
    info "Windows       : Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\\\\LocalMachine\\\\Root"
    info "macOS         : sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt"
}

# ==============================================================================
# Run: key generator
# ==============================================================================
run_keygen() {
    local outfile=""

    case "$S_KEYGEN_ALGO" in
        rsa)     outfile="${S_OUTDIR}/key_rsa${S_RSA_BITS}.pem" ;;
        ecdsa)   outfile="${S_OUTDIR}/key_ecdsa_${S_EC_CURVE}.pem" ;;
        ed25519) outfile="${S_OUTDIR}/key_ed25519.pem" ;;
        rand)    outfile="${S_OUTDIR}/rand_${S_RAND_BYTES}bytes.${S_RAND_FORMAT}" ;;
    esac

    if [[ "$S_KEYGEN_ALGO" == "rand" ]]; then
        local rand_val
        if [[ "$S_RAND_FORMAT" == "base64" ]]; then
            rand_val=$(openssl rand -base64 "${S_RAND_BYTES}")
        else
            rand_val=$(openssl rand -hex "${S_RAND_BYTES}")
        fi
        echo "$rand_val" > "${outfile}"
        chmod 600 "${outfile}"
        echo -e "  ${BOLD}${GREEN}${rand_val}${R}"
        blank
        ok "Сохранено: ${outfile}" "Saved: ${outfile}"
        return 0
    fi

    info "Создаю ключ…" "Generating the key…"
    gen_key "$S_KEYGEN_ALGO" "${outfile}"
    ok "Закрытый ключ: ${outfile}" "Private key: ${outfile}"
    blank
    info "Открытый ключ:" "Public key:"
    openssl pkey -in "${outfile}" -pubout
}

# ==============================================================================
# Backups — files are copied to BACKUP_DIR before the wizard overwrites them
# ==============================================================================
BACKUP_SET=""           # folder of the current backup set (one per certificate)

# backup_files PATH... — copies the files that exist into
# BACKUP_DIR/<date_time>/<full path>; the set folder goes to BACKUP_SET
backup_files() {
    local p stamp n=1
    for p in "$@"; do
        [[ -n "$p" && -f "$p" ]] || continue
        if [[ -z "$BACKUP_SET" ]]; then
            mkdir -p "$BACKUP_DIR"
            chmod 700 "$BACKUP_DIR"      # backups hold private keys
            stamp="$(date +%Y-%m-%d_%H%M%S)"
            BACKUP_SET="${BACKUP_DIR}/${stamp}"
            while [[ -e "$BACKUP_SET" ]]; do
                n=$((n + 1))
                BACKUP_SET="${BACKUP_DIR}/${stamp}_${n}"
            done
            mkdir -p "$BACKUP_SET"
            remove_old_backups
        fi
        p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
        mkdir -p "${BACKUP_SET}$(dirname "$p")"
        cp -p "$p" "${BACKUP_SET}${p}"
    done
    return 0
}

# Keeps only the newest BACKUP_KEEP backup sets
remove_old_backups() {
    local sets=() s i=0
    mapfile -t sets < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    for s in ${sets[@]+"${sets[@]}"}; do
        i=$((i + 1))
        if (( i > BACKUP_KEEP )); then rm -rf -- "$s"; fi
    done
    return 0
}

# Files in the output folder that the chosen method may overwrite
wizard_targets() {
    local f name
    [[ -d "$S_OUTDIR" ]] || return 0
    for f in "$S_OUTDIR"/*; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        case "$name" in
            openssl.cnf|privkey.pem|cert.csr|fullchain.pem|ca.crt|ca.key|ca.srl|key_*.pem|rand_*)
                echo "$f" ;;
            *)
                if [[ -n "$S_DOMAIN" && ( "$name" == "${S_DOMAIN}."* || "$name" == "${S_DOMAIN}_"* ) ]]; then
                    echo "$f"
                fi ;;
        esac
    done
    return 0
}

# ==============================================================================
# Certificate helpers shared by the folder scan and the renewal
# ==============================================================================
# cert_epoch FILE start|end — validity bound of the first certificate, in seconds
cert_epoch() {
    local d
    if [[ "$2" == "start" ]]; then
        d="$(openssl x509 -in "$1" -noout -startdate 2>/dev/null)" || return 1
    else
        d="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null)" || return 1
    fi
    date -d "${d#*=}" +%s
}

# days_left FILE — whole days until the first certificate expires (negative: expired)
days_left() {
    local end now diff
    end="$(cert_epoch "$1" end)" || return 1
    now="$(date +%s)"
    diff=$((end - now))
    if (( diff < 0 )); then
        echo $(( (diff - 86399) / 86400 ))
    else
        echo $(( diff / 86400 ))
    fi
}

# renew_threshold VALIDITY_DAYS — renew when a third of the validity is left,
# but not earlier than 30 days before expiry
renew_threshold() {
    local t=$(( $1 / 3 ))
    if (( t < 1 )); then t=1; fi
    if (( t > 30 )); then t=30; fi
    echo "$t"
}

# key_label FILE — "RSA 2048", "ECDSA P-256", "Ed25519"
key_label() {
    local t curve
    t="$(openssl x509 -in "$1" -noout -text 2>/dev/null)"
    if grep -q 'rsaEncryption' <<< "$t"; then
        echo "RSA $(grep -o 'Public-Key: ([0-9]*' <<< "$t" | grep -o '[0-9]*$')"
    elif grep -q 'id-ecPublicKey' <<< "$t"; then
        curve="$(grep -o 'NIST CURVE: P-[0-9]*' <<< "$t" | cut -d' ' -f3)"
        echo "ECDSA${curve:+ $curve}"
    elif grep -qi 'ED25519' <<< "$t"; then
        echo "Ed25519"
    else
        echo "?"
    fi
}

# Public key of a certificate file (first certificate) or of a private key, one line
cert_spki() { openssl x509 -in "$1" -noout -pubkey 2>/dev/null | grep -v -- '-----' | tr -d '\n'; }
key_spki()  { openssl pkey -in "$1" -pubout -passin pass: 2>/dev/null | grep -v -- '-----' | tr -d '\n'; }

# rdn_value "CN=a,O=b" CN — one attribute of an RFC 2253 name
rdn_value() { sed -n "s/^\(.*,\)\{0,1\}$2=\([^,]*\).*/\2/p" <<< "$1"; }

# ==============================================================================
# Auto-renewal entries — RENEW_DIR/<id>.conf, shell assignments written with %q:
#   E_TYPE=self|ca|acme  E_NAME  E_DAYS (validity)  E_KEY (private key, reused)
#   E_OUTPUTS=("leaf:/path" "fullchain:/path")  E_P12=(...)
#   E_CA_CERT E_CA_KEY (ca)
#   E_DOMAINS=(...) E_ACME_MODE=existing|standalone|webroot|cloudflare
#   E_WEBROOT E_CF_TOKEN (acme)
# ==============================================================================
reset_entry() {
    E_TYPE=""; E_NAME=""; E_DAYS=0; E_KEY=""
    E_OUTPUTS=(); E_P12=(); E_DOMAINS=()
    E_CA_CERT=""; E_CA_KEY=""
    E_ACME_MODE=""; E_WEBROOT=""; E_CF_TOKEN=""
}
reset_entry

# q_array NAME VALUE... — one array assignment, safe to source back
q_array() {
    local name="$1" v
    shift
    printf '%s=(' "$name"
    for v in "$@"; do printf ' %q' "$v"; done
    printf ' )\n'
}

# Files every saved entry writes to, one per line
entry_paths() {
    local f
    for f in "$RENEW_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        ( reset_entry; source "$f"; for o in ${E_OUTPUTS[@]+"${E_OUTPUTS[@]}"}; do echo "${o#*:}"; done )
    done
    return 0
}

# save_entry — writes E_* to RENEW_DIR; an entry writing to the same files is
# replaced. The file name goes to LAST_CONF
LAST_CONF=""
save_entry() {
    local f o p id
    mkdir -p "$RENEW_DIR"
    chmod 700 "$DATA_DIR" "$RENEW_DIR"
    for f in "$RENEW_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        while IFS= read -r p; do
            for o in "${E_OUTPUTS[@]}"; do
                if [[ "${o#*:}" == "$p" ]]; then
                    rm -f -- "$f"
                    continue 3
                fi
            done
        done < <( reset_entry; source "$f"; for o in ${E_OUTPUTS[@]+"${E_OUTPUTS[@]}"}; do echo "${o#*:}"; done )
    done

    id="$(printf '%s' "${E_OUTPUTS[0]#*:}" | openssl dgst -sha256 -r | cut -c1-16)"
    LAST_CONF="${RENEW_DIR}/${id}.conf"
    {
        echo "# ssl-wizard auto-renewal entry"
        printf 'E_TYPE=%q\nE_NAME=%q\nE_DAYS=%q\nE_KEY=%q\n' "$E_TYPE" "$E_NAME" "$E_DAYS" "$E_KEY"
        printf 'E_CA_CERT=%q\nE_CA_KEY=%q\n' "$E_CA_CERT" "$E_CA_KEY"
        printf 'E_ACME_MODE=%q\nE_WEBROOT=%q\nE_CF_TOKEN=%q\n' "$E_ACME_MODE" "$E_WEBROOT" "$E_CF_TOKEN"
        q_array E_OUTPUTS "${E_OUTPUTS[@]}"
        q_array E_P12     ${E_P12[@]+"${E_P12[@]}"}
        q_array E_DOMAINS ${E_DOMAINS[@]+"${E_DOMAINS[@]}"}
    } > "$LAST_CONF"
    chmod 600 "$LAST_CONF"
}

# register_renew_task — daily "ssl-wizard --renew" via cron, or a systemd timer
# where there is no cron. RENEW_SCHED gets "cron" / "systemd"
RENEW_SCHED=""
register_renew_task() {
    local cmd="$CMD_TARGET"
    [[ -n "$cmd" ]] || cmd="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"

    if [[ -d "$(dirname "$CRON_FILE")" ]] &&
       { [[ -n "${SSLWIZ_CRON_FILE:-}" ]] || command -v cron &>/dev/null || command -v crond &>/dev/null; }; then
        {
            echo "# ssl-wizard: daily certificate renewal"
            echo "SHELL=/bin/bash"
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            printf '30 3 * * * root %q --renew >/dev/null 2>&1\n' "$cmd"
        } > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        RENEW_SCHED="cron"
        return 0
    fi

    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/ssl-wizard-renew.service <<UNIT
[Unit]
Description=ssl-wizard certificate renewal

[Service]
Type=oneshot
Environment=HOME=${HOME}
ExecStart=${cmd} --renew
UNIT
        cat > /etc/systemd/system/ssl-wizard-renew.timer <<UNIT
[Unit]
Description=Daily ssl-wizard certificate renewal

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload &>/dev/null
        systemctl enable --now ssl-wizard-renew.timer &>/dev/null || return 1
        RENEW_SCHED="systemd"
        return 0
    fi
    return 1
}

# ==============================================================================
# Renewal — "ssl-wizard --renew" and "renew now" after a scan
# ==============================================================================
RENEW_ECHO=""           # also print log lines (renewing from the menu)
RENEW_RENEWED=0
RENEW_FAILED=0

renew_log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RENEW_LOG"
    if [[ -n "$RENEW_ECHO" ]]; then info "$1"; fi
    return 0
}

# write_outputs NEW_LEAF [CHAIN] — puts the renewed certificate into every file
# of the entry and keeps each file's form: a single certificate stays single; a
# chain file gets the new leaf on top, then CHAIN or whatever was below before
write_outputs() {
    local new="$1" chain="${2:-}" o kind path full="" p paths=()
    for o in "${E_OUTPUTS[@]}"; do paths+=("${o#*:}"); done
    backup_files "${paths[@]}" ${E_P12[@]+"${E_P12[@]}"}

    for o in "${E_OUTPUTS[@]}"; do
        kind="${o%%:*}"
        path="${o#*:}"
        if [[ "$kind" == "fullchain" ]]; then
            [[ -n "$full" ]] || full="$path"
            if [[ -n "$chain" ]]; then
                cat "$new" "$chain" > "${path}.sslwiz-tmp"
            else
                { cat "$new"; awk '/-----BEGIN CERTIFICATE-----/ { n++ } n > 1' "$path"; } > "${path}.sslwiz-tmp"
            fi
        else
            cat "$new" > "${path}.sslwiz-tmp"
        fi
        # cat into the old file keeps its owner and permissions
        cat "${path}.sslwiz-tmp" > "$path"
        rm -f "${path}.sslwiz-tmp"
    done

    [[ -n "$full" ]] || full="${paths[0]}"
    for p in ${E_P12[@]+"${E_P12[@]}"}; do
        openssl pkcs12 -export -in "$full" -inkey "$E_KEY" -out "${p}.sslwiz-tmp" -name "$E_NAME" -passout pass:
        cat "${p}.sslwiz-tmp" > "$p"
        rm -f "${p}.sslwiz-tmp"
        chmod 600 "$p"
    done
}

# acme_renew_entry TMPDIR — a Let's Encrypt certificate from acme.sh, requested
# with the existing key. ACME_LEAF / ACME_CHAIN get the new files
acme_renew_entry() {
    local tmp="$1" d0="${E_DOMAINS[0]}" args=() san="" d dir best=""
    if [[ ! -f "$ACME_SH" ]] && ! install_acme; then
        die "acme.sh не установлен" "acme.sh is not installed"
    fi

    if [[ "$E_ACME_MODE" == "existing" ]]; then
        # acme.sh already manages this certificate with this key
        args=(--renew --domain "$d0" --force)
        if [[ -d "${HOME}/.acme.sh/${d0}_ecc" ]]; then args+=(--ecc); fi
    else
        for d in "${E_DOMAINS[@]}"; do san+="${san:+,}DNS:${d}"; done
        openssl req -new -key "$E_KEY" -subj "/CN=${d0}" -addext "subjectAltName=${san}" -out "${tmp}/req.csr"
        args=(--signcsr --csr "${tmp}/req.csr" --force)
        case "$E_ACME_MODE" in
            standalone) args+=(--standalone) ;;
            webroot)    args+=(--webroot "$E_WEBROOT") ;;
            cloudflare) export CF_Token="$E_CF_TOKEN"; args+=(--dns dns_cf) ;;
        esac
    fi
    acme "${args[@]}"

    # acme.sh keeps EC certificates in <domain>_ecc, RSA ones in <domain>
    for dir in "${HOME}/.acme.sh/${d0}_ecc" "${HOME}/.acme.sh/${d0}"; do
        [[ -f "${dir}/${d0}.cer" ]] || continue
        if [[ -z "$best" || "${dir}/${d0}.cer" -nt "${best}/${d0}.cer" ]]; then best="$dir"; fi
    done
    [[ -n "$best" ]] || die "acme.sh не выдал сертификат" "acme.sh did not issue a certificate"
    ACME_LEAF="${best}/${d0}.cer"
    ACME_CHAIN="${best}/ca.cer"
}

# renew_entry RESULT_FILE — renews the loaded entry (E_*) if it is due.
# Runs under set -e in a subshell; RESULT_FILE gets: state / where / backup set
renew_entry() {
    local result="$1" first="${E_OUTPUTS[0]#*:}" left tmp new chain="" args=()
    left="$(days_left "$first")"
    if (( left > $(renew_threshold "$E_DAYS") )); then
        printf 'skipped\n%s\n' "$left" > "$result"
        return 0
    fi

    tmp="$(mktemp -d)"
    if [[ "$E_TYPE" == "acme" ]]; then
        acme_renew_entry "$tmp"
        new="$ACME_LEAF"
        chain="$ACME_CHAIN"
    else
        # self-signed and own-CA certificates are re-signed as they are: subject,
        # SAN and other extensions, key and validity length all stay the same
        openssl x509 -in "$first" -out "${tmp}/leaf.pem"
        args=(x509 -in "${tmp}/leaf.pem" -days "$E_DAYS" -set_serial "0x$(openssl rand -hex 16)" -out "${tmp}/new.pem")
        if [[ "$E_TYPE" == "ca" ]]; then
            args+=(-CA "$E_CA_CERT" -CAkey "$E_CA_KEY")
        else
            args+=(-signkey "$E_KEY")
        fi
        if ! openssl "${args[@]}" 2>"${tmp}/err"; then
            cat "${tmp}/err" >&2
            rm -rf "$tmp"
            return 1
        fi
        new="${tmp}/new.pem"
    fi
    write_outputs "$new" "$chain"
    rm -rf "$tmp"
    printf 'renewed\n%s\n%s\n' "$first" "$BACKUP_SET" > "$result"
}

# run_renew CONF... — renews every due entry; counts go to RENEW_RENEWED / RENEW_FAILED
run_renew() {
    local f name rc out errf res=()
    RENEW_RENEWED=0
    RENEW_FAILED=0
    mkdir -p "$(dirname "$RENEW_LOG")"
    out="$(mktemp)"
    errf="$(mktemp)"
    for f in "$@"; do
        name="$( reset_entry; source "$f"; echo "$E_NAME" )"
        : > "$out"
        ( set -e; reset_entry; source "$f"; BACKUP_SET=""; renew_entry "$out" ) 2>"$errf"
        rc=$?
        if (( rc != 0 )); then
            RENEW_FAILED=$((RENEW_FAILED + 1))
            tl "ошибка" "error"
            renew_log "${name}: ${MSG} - $(tail -n 3 "$errf" | tr '\n' ' ')"
            continue
        fi
        mapfile -t res < "$out"
        if [[ "${res[0]:-}" == "renewed" ]]; then
            RENEW_RENEWED=$((RENEW_RENEWED + 1))
            tl "продлён, файлы обновлены" "renewed, files updated"
            renew_log "${name}: ${MSG} - ${res[1]:-}"
            if [[ -n "${res[2]:-}" ]]; then
                tl "старые файлы сохранены в" "old files saved to"
                renew_log "${name}: ${MSG} ${res[2]}"
            fi
        else
            tl "продлевать ещё рано (осталось ${res[1]:-?} дн.)" "not due for renewal yet (${res[1]:-?} days left)"
            renew_log "${name}: ${MSG}"
        fi
    done
    rm -f "$out" "$errf"

    # user's own script after a renewal, e.g. reloading nginx
    if (( RENEW_RENEWED > 0 )) && [[ -f "$RENEW_HOOK" ]]; then
        if bash "$RENEW_HOOK" >> "$RENEW_LOG" 2>&1; then
            tl "выполнен" "done"
            renew_log "after-renew.sh: ${MSG}"
        else
            RENEW_FAILED=$((RENEW_FAILED + 1))
            tl "ошибка" "error"
            renew_log "after-renew.sh: ${MSG}"
        fi
    fi
    return 0
}

# --renew mode: every saved entry
run_renew_mode() {
    local confs=()
    mkdir -p "$(dirname "$RENEW_LOG")"
    if ! command -v openssl &>/dev/null; then
        renew_log "openssl not found"
        return 1
    fi
    mapfile -t confs < <(find "$RENEW_DIR" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)
    if (( ${#confs[@]} == 0 )); then
        tl "сертификатов для продления нет" "no certificates to renew"
        renew_log "$MSG"
        return 0
    fi
    run_renew "${confs[@]}"
    (( RENEW_FAILED == 0 ))
}

# ==============================================================================
# Folder scan — finds certificates, shows when they expire and puts them on
# auto-renewal: the same files under the same names, the same kind of certificate
# ==============================================================================
# Results, one index per certificate found (K_ORDER: indexes by days left)
K_N=0
K_ORDER=()
K_NAME=(); K_TYPE=(); K_STATUS=(); K_REASON=(); K_KEYLBL=(); K_ISSUER=(); K_CANAME=()
K_END=(); K_LEFT=(); K_DAYS=(); K_KEY=(); K_OUTPUTS=(); K_P12=(); K_DOMAINS=()
K_CACERT=(); K_CAKEY=(); K_MODE=(); K_WEBROOT=(); K_CFTOKEN=()

v_dir() {
    [[ -d "$1" ]] && return 0
    warn "Такой папки нет." "No such folder."
    return 1
}

# scan_folder ROOT all|one — fills K_* with every server certificate found
# (in subfolders too with "all"); the wizard's own backups are skipped
scan_folder() {
    local root="$1" depth="$2" f i k n spki info fp kind name start end ca issuer_name
    local files=() depth_args=() c_path=() c_count=() c_fp=() c_subj=() c_iss=() c_spki=() c_isca=() c_dns=()
    local -A keys=() cas=() signers=() managed=() seen=()

    K_N=0; K_ORDER=()
    K_NAME=(); K_TYPE=(); K_STATUS=(); K_REASON=(); K_KEYLBL=(); K_ISSUER=(); K_CANAME=()
    K_END=(); K_LEFT=(); K_DAYS=(); K_KEY=(); K_OUTPUTS=(); K_P12=(); K_DOMAINS=()
    K_CACERT=(); K_CAKEY=(); K_MODE=(); K_WEBROOT=(); K_CFTOKEN=()

    while IFS= read -r f; do
        [[ -n "$f" ]] && managed["$f"]=1
    done < <(entry_paths)

    if [[ "$depth" == "one" ]]; then depth_args=(-maxdepth 1); fi
    mapfile -t files < <(find "$root" ${depth_args[@]+"${depth_args[@]}"} -type f \
                             \( -name '*.crt' -o -name '*.cer' -o -name '*.pem' -o -name '*.key' \) \
                             -size -1024k 2>/dev/null | grep -v -F "${BACKUP_DIR}/" | sort)

    for f in ${files[@]+"${files[@]}"}; do
        # a password-protected key cannot be used unattended, so it is not paired
        if grep -q 'PRIVATE KEY-----' "$f" && ! grep -q 'ENCRYPTED' "$f"; then
            spki="$(key_spki "$f")"
            if [[ -n "$spki" && -z "${keys[$spki]:-}" ]]; then keys["$spki"]="$f"; fi
        fi
        grep -q 'BEGIN CERTIFICATE' "$f" || continue
        info="$(openssl x509 -in "$f" -noout -fingerprint -sha256 -subject -issuer -nameopt RFC2253 \
                    -ext basicConstraints,subjectAltName 2>/dev/null)" || continue
        c_path+=("$f")
        c_count+=("$(grep -c 'BEGIN CERTIFICATE' "$f")")
        c_fp+=("$(sed -n 's/^.*Fingerprint=//p' <<< "$info")")
        c_subj+=("$(sed -n 's/^subject=//p' <<< "$info")")
        c_iss+=("$(sed -n 's/^issuer=//p' <<< "$info")")
        if grep -q 'CA:TRUE' <<< "$info"; then c_isca+=(1); else c_isca+=(0); fi
        c_dns+=("$(grep -o 'DNS:[^,[:space:]]*' <<< "$info" | cut -c5- | tr '\n' ' ' | sed 's/ $//')")
        c_spki+=("$(cert_spki "$f")")
    done

    # Authorities rather than server certificates: an intermediate (CA, not
    # self-signed) or a root that signed something here. A self-signed CA:TRUE
    # certificate that signed nothing is a server certificate — "openssl req
    # -x509" marks them CA:TRUE by default.
    n=${#c_path[@]}
    for ((i = 0; i < n; i++)); do
        if [[ "${c_subj[i]}" != "${c_iss[i]}" ]]; then signers["${c_iss[i]}"]=1; fi
        if [[ "${c_isca[i]}" == 1 ]] && { [[ -z "${cas[${c_subj[i]}]:-}" ]] || [[ "${c_count[i]}" == 1 ]]; }; then
            cas["${c_subj[i]}"]=$i
        fi
    done

    for ((i = 0; i < n; i++)); do
        if [[ "${c_isca[i]}" == 1 ]] &&
           { [[ "${c_subj[i]}" != "${c_iss[i]}" ]] || [[ -n "${signers[${c_subj[i]}]:-}" ]]; }; then
            continue
        fi
        if (( c_count[i] > 1 )); then kind="fullchain"; else kind="leaf"; fi
        fp="${c_fp[i]}"
        # the same certificate may sit in several files (cert.pem, fullchain.pem...)
        if [[ -n "${seen[$fp]:-}" ]]; then
            k=${seen[$fp]}
            K_OUTPUTS[k]+=$'\n'"${kind}:${c_path[i]}"
            continue
        fi
        k=$K_N
        seen["$fp"]=$k
        K_N=$((K_N + 1))

        name="$(rdn_value "${c_subj[i]}" CN)"
        if [[ -z "$name" ]]; then name="${c_dns[i]%% *}"; fi
        issuer_name="$(rdn_value "${c_iss[i]}" CN)"
        if [[ -z "$issuer_name" ]]; then issuer_name="$(rdn_value "${c_iss[i]}" O)"; fi
        start="$(cert_epoch "${c_path[i]}" start)"
        end="$(cert_epoch "${c_path[i]}" end)"

        K_NAME[k]="$name"
        K_TYPE[k]="other"; K_STATUS[k]="ok"; K_REASON[k]=""
        K_KEYLBL[k]="$(key_label "${c_path[i]}")"
        K_ISSUER[k]="$issuer_name"; K_CANAME[k]=""
        K_END[k]="$(date -d "@${end}" +%Y-%m-%d)"
        K_LEFT[k]="$(days_left "${c_path[i]}")"
        K_DAYS[k]=$(( (end - start + 43200) / 86400 ))
        K_KEY[k]=""
        if [[ -n "${c_spki[i]}" ]]; then K_KEY[k]="${keys[${c_spki[i]}]:-}"; fi
        K_OUTPUTS[k]="${kind}:${c_path[i]}"
        K_P12[k]=""
        K_DOMAINS[k]="${c_dns[i]}"
        K_CACERT[k]=""; K_CAKEY[k]=""
        K_MODE[k]=""; K_WEBROOT[k]=""; K_CFTOKEN[k]=""

        if [[ "${c_iss[i]}" == *"O=Let's Encrypt"* ]]; then
            K_TYPE[k]="acme"
        elif [[ "${c_subj[i]}" == "${c_iss[i]}" ]]; then
            K_TYPE[k]="self"
        elif [[ -n "${cas[${c_iss[i]}]:-}" ]]; then
            ca=${cas[${c_iss[i]}]}
            K_TYPE[k]="ca"
            K_CANAME[k]="$(rdn_value "${c_subj[ca]}" CN)"
            K_CACERT[k]="${c_path[ca]}"
            if [[ -n "${c_spki[ca]}" ]]; then K_CAKEY[k]="${keys[${c_spki[ca]}]:-}"; fi
        fi
    done

    for ((k = 0; k < K_N; k++)); do
        scan_status "$k"
    done
    mapfile -t K_ORDER < <(for ((k = 0; k < K_N; k++)); do echo "${K_LEFT[k]} $k"; done | sort -n | cut -d' ' -f2)
    return 0
}

# scan_status K — can the wizard renew certificate K; also finds .p12 files and
# whether acme.sh already manages a Let's Encrypt certificate with this key
scan_status() {
    local k=$1 o path base ext p d0 dir doms=()
    while IFS= read -r o; do
        path="${o#*:}"
        if [[ -n "${managed[$path]:-}" ]]; then K_STATUS[k]="managed"; fi
        # a .p12/.pfx next to the certificate, same name, no password: rebuilt too
        base="${path%.*}"
        for ext in p12 pfx; do
            p="${base}.${ext}"
            if [[ -f "$p" && $'\n'"${K_P12[k]}"$'\n' != *$'\n'"$p"$'\n'* ]] &&
               openssl pkcs12 -in "$p" -passin pass: -noout &>/dev/null; then
                K_P12[k]+="${K_P12[k]:+$'\n'}${p}"
            fi
        done
    done <<< "${K_OUTPUTS[k]}"
    [[ "${K_STATUS[k]}" == "managed" ]] && return 0

    if [[ "${K_TYPE[k]}" == "other" ]]; then
        tl "выдан '${K_ISSUER[k]}' — такой центр мастер продлевать не умеет" \
           "issued by '${K_ISSUER[k]}' — the wizard cannot renew certificates from it"
    elif [[ -z "${K_KEY[k]}" ]]; then
        tl "закрытый ключ не найден в папке или защищён паролем" \
           "private key not found in the folder, or it has a password"
    elif [[ "${K_TYPE[k]}" == "ca" && -z "${K_CAKEY[k]}" ]]; then
        tl "ключ центра сертификации не найден в папке или защищён паролем" \
           "the CA key is not in the folder, or it has a password"
    elif [[ "${K_TYPE[k]}" == "acme" && -z "${K_DOMAINS[k]}" ]]; then
        tl "в сертификате нет доменов" "the certificate lists no domains"
    else
        if [[ "${K_TYPE[k]}" == "acme" ]]; then
            read -ra doms <<< "${K_DOMAINS[k]}"
            d0="${doms[0]}"
            for dir in "${HOME}/.acme.sh/${d0}_ecc" "${HOME}/.acme.sh/${d0}"; do
                if [[ -f "${dir}/${d0}.key" && "$(key_spki "${dir}/${d0}.key")" == "$(key_spki "${K_KEY[k]}")" ]]; then
                    K_MODE[k]="existing"
                fi
            done
        fi
        return 0
    fi
    K_STATUS[k]="skip"
    K_REASON[k]="$MSG"
}

type_label() {
    local k=$1
    case "${K_TYPE[k]}" in
        acme) MSG="Let's Encrypt" ;;
        self) tl "самоподписанный" "self-signed" ;;
        ca)   tl "подписан CA '${K_CANAME[k]}'" "signed by CA '${K_CANAME[k]}'" ;;
        *)    tl "выдан '${K_ISSUER[k]}'" "issued by '${K_ISSUER[k]}'" ;;
    esac
    echo "${K_KEYLBL[k]}, ${MSG}"
}

show_scan_results() {
    local root="${1%/}" k i=0 color when files o path
    for k in ${K_ORDER[@]+"${K_ORDER[@]}"}; do
        i=$((i + 1))
        if (( K_LEFT[k] < 0 )); then
            tl "истёк ${K_END[k]}" "expired on ${K_END[k]}"
            color="$RED"
        else
            tl "действует до ${K_END[k]}, осталось ${K_LEFT[k]} дн." "valid until ${K_END[k]}, days left: ${K_LEFT[k]}"
            if (( K_LEFT[k] <= 30 )); then color="$YELLOW"; else color="$GREEN"; fi
        fi
        when="$MSG"
        files=""
        while IFS= read -r o; do
            [[ -n "$o" ]] || continue
            path="${o#*:}"
            files+="${files:+, }${path#"${root}/"}"
        done <<< "${K_OUTPUTS[k]}"$'\n'"${K_P12[k]}"

        printf "  ${BLUE}%3s)${R}  %s ${DIM}%s${R}\n" "$i" "$(pad "${K_NAME[k]}" 30)" "$(type_label "$k")"
        echo -e "        ${color}${when}${R}"
        echo -e "        ${DIM}${files}${R}"
        case "${K_STATUS[k]}" in
            ok)      tl "будет продлеваться" "will be renewed"
                     if [[ "${K_MODE[k]}" == "existing" ]]; then
                         tl "будет продлеваться (уже есть в acme.sh)" "will be renewed (already known to acme.sh)"
                     fi
                     echo -e "        ${GREEN}✔ ${MSG}${R}" ;;
            managed) tl "уже в автопродлении" "already on auto-renewal"
                     echo -e "        ${DIM}✔ ${MSG}${R}" ;;
            *)       echo -e "        ${YELLOW}⚠ ${K_REASON[k]}${R}" ;;
        esac
        blank
    done
}

# ask_acme_method K — how Let's Encrypt should check the domain of certificate K.
# Sets K_MODE (+ K_WEBROOT / K_CFTOKEN) or K_STATUS=skip; 0 — NAV=back
ask_acme_method() {
    local k=$1 wildcard="" choices=() c d doms=()
    read -ra doms <<< "${K_DOMAINS[k]}"
    for d in "${doms[@]}"; do
        if [[ "$d" == \** ]]; then wildcard="yes"; fi
    done
    while true; do
        screen "Проверка домена: ${K_NAME[k]}" "Domain check: ${K_NAME[k]}"
        row "Домены" "Domains" "${K_DOMAINS[k]// /, }"
        blank
        hint "При каждом продлении Let's Encrypt проверяет, что домен ваш. Как это делать?" \
             "On every renewal Let's Encrypt checks that the domain is yours. How?"
        blank
        choices=()
        if [[ -z "$wildcard" ]]; then
            choices+=(standalone)
            opt "${#choices[@]}" "Автономно"         "порт 80 свободен, веб-сервера нет" \
                                 "Standalone"        "port 80 is free, no web server"
            choices+=(webroot)
            opt "${#choices[@]}" "Через папку сайта" "сайт работает, файлы отдаются из папки" \
                                 "Via site folder"   "the site runs and serves files from a folder"
        fi
        choices+=(cloudflare)
        opt "${#choices[@]}" "Cloudflare"    "DNS-запись по API-токену" \
                             "Cloudflare"    "DNS record via API token"
        choices+=(skip)
        opt "${#choices[@]}" "Не продлевать" "пропустить этот сертификат" \
                             "Do not renew"  "skip this certificate"
        if [[ -n "$wildcard" ]]; then
            blank
            hint "Для wildcard (*.домен) подходит только проверка через DNS." \
                 "A wildcard (*.domain) can only be checked via DNS."
        fi
        blank; hr; blank

        c=""
        pick c "${#choices[@]}"
        [[ "$NAV" == "back" ]] && return 0
        case "${choices[$((c - 1))]}" in
            skip)
                K_STATUS[k]="skip"
                return 0 ;;
            standalone)
                if ! command -v socat &>/dev/null && ! { pkg_install socat && command -v socat &>/dev/null; }; then
                    blank
                    err "Для этого способа нужен socat, установить его не удалось." \
                        "This method needs socat, and it could not be installed."
                    blank
                    pause
                    continue
                fi
                K_MODE[k]="standalone"
                return 0 ;;
            webroot)
                blank
                S_SCAN_WEBROOT=""
                ask S_SCAN_WEBROOT "Папка сайта" "Site folder" "/var/www/html" v_dir
                if [[ "$NAV" == "back" ]]; then NAV=""; continue; fi
                K_MODE[k]="webroot"
                K_WEBROOT[k]="$S_SCAN_WEBROOT"
                return 0 ;;
            cloudflare)
                blank
                hint "Токен: Cloudflare → My Profile → API Tokens → шаблон «Edit zone DNS»." \
                     "Token: Cloudflare → My Profile → API Tokens → \"Edit zone DNS\" template."
                S_SCAN_TOKEN=""
                ask S_SCAN_TOKEN "API-токен" "API token"
                if [[ "$NAV" == "back" ]]; then NAV=""; continue; fi
                K_MODE[k]="cloudflare"
                K_CFTOKEN[k]="$S_SCAN_TOKEN"
                S_SCAN_TOKEN=""
                return 0 ;;
        esac
    done
}

# E_* from scan result K
entry_from_scan() {
    local k=$1
    reset_entry
    E_TYPE="${K_TYPE[k]}"
    E_NAME="${K_NAME[k]}"
    E_DAYS="${K_DAYS[k]}"
    E_KEY="${K_KEY[k]}"
    mapfile -t E_OUTPUTS <<< "${K_OUTPUTS[k]}"
    if [[ -n "${K_P12[k]}" ]]; then mapfile -t E_P12 <<< "${K_P12[k]}"; fi
    E_CA_CERT="${K_CACERT[k]}"
    E_CA_KEY="${K_CAKEY[k]}"
    if [[ "$E_TYPE" == "acme" ]]; then
        read -ra E_DOMAINS <<< "${K_DOMAINS[k]}"
        E_ACME_MODE="${K_MODE[k]}"
        E_WEBROOT="${K_WEBROOT[k]}"
        E_CF_TOKEN="${K_CFTOKEN[k]}"
    fi
}

S_SCAN_DIR=""
S_SCAN_WEBROOT=""
S_SCAN_TOKEN=""

# Menu item "Scan a folder": folder -> depth -> results -> domain checks -> add -> renew now
step_scan() {
    local saved_step=$STEP_I root depth c j k ready=() acme_q=() confs=() due=()
    STEP_I=0
    while true; do
        screen "Сканирование папки" "Scan a folder"
        hint "Мастер найдёт сертификаты, покажет их срок и поставит на автопродление:" \
             "The wizard finds certificates, shows their expiry and puts them on auto-renewal:"
        hint "те же файлы с теми же именами, такой же сертификат." \
             "the same files under the same names, the same certificate."
        hint "Enter — текущая папка, 0 — назад." "Enter — current folder, 0 — back."
        blank
        NAV=""
        ask S_SCAN_DIR "Путь к папке" "Folder path" "$PWD" v_dir
        if [[ "$NAV" == "back" ]]; then break; fi
        root="$(cd "$S_SCAN_DIR" && pwd)"

        blank
        opt 1 "С подпапками"      "эта папка и все вложенные" \
              "With subfolders"   "this folder and everything inside it"
        opt 2 "Только эта папка"  "без вложенных папок" \
              "This folder only"  "no subfolders"
        blank
        depth=""
        pick depth 2
        if [[ "$NAV" == "back" ]]; then NAV=""; continue; fi

        screen "Найденные сертификаты" "Certificates found"
        info "Папка: ${root}" "Folder: ${root}"
        if [[ "$depth" == "1" ]]; then info "Вместе с подпапками" "Including subfolders"; fi
        blank
        if [[ "$depth" == "1" ]]; then scan_folder "$root" all; else scan_folder "$root" one; fi
        if (( K_N == 0 )); then
            warn "Сертификатов не найдено (ищутся файлы .crt, .cer, .pem)." \
                 "No certificates found (looking for .crt, .cer, .pem files)."
            blank
            pause
            continue
        fi
        show_scan_results "$root"
        ready=()
        for ((k = 0; k < K_N; k++)); do
            if [[ "${K_STATUS[k]}" == "ok" ]]; then ready+=("$k"); fi
        done
        hr; blank
        if (( ${#ready[@]} == 0 )); then
            hint "Добавлять в автопродление нечего." "Nothing to add to auto-renewal."
            blank
            pause "Нажмите Enter, чтобы вернуться…" "Press Enter to go back…"
            continue
        fi
        opt 1 "Добавить в автопродление" "сертификатов: ${#ready[@]}" \
              "Add to auto-renewal"      "certificates: ${#ready[@]}"
        blank
        c=""
        pick c 1
        if [[ "$NAV" == "back" ]]; then NAV=""; continue; fi

        # Let's Encrypt needs to know how to check each domain; 0 goes to the previous one
        acme_q=()
        for k in "${ready[@]}"; do
            if [[ "${K_TYPE[k]}" == "acme" && "${K_MODE[k]}" != "existing" ]]; then acme_q+=("$k"); fi
        done
        j=0
        while (( j < ${#acme_q[@]} )); do
            NAV=""
            ask_acme_method "${acme_q[j]}"
            if [[ "$NAV" == "back" ]]; then
                if (( j == 0 )); then break; fi
                j=$((j - 1))
            else
                j=$((j + 1))
            fi
        done
        if [[ "$NAV" == "back" ]]; then NAV=""; continue; fi

        screen "Автопродление" "Auto-renewal"
        confs=()
        due=()
        for k in "${ready[@]}"; do
            [[ "${K_STATUS[k]}" == "ok" ]] || continue
            entry_from_scan "$k"
            save_entry
            confs+=("$LAST_CONF")
            if (( K_LEFT[k] <= $(renew_threshold "${K_DAYS[k]}") )); then due+=("$LAST_CONF"); fi
        done
        if (( ${#confs[@]} == 0 )); then
            hint "Все сертификаты пропущены." "All certificates were skipped."
            blank
            pause
            break
        fi
        ok "Добавлено в автопродление: ${#confs[@]}" "Added to auto-renewal: ${#confs[@]}"
        if register_renew_task; then
            ok "Проверка срока — каждый день в 03:30 (${RENEW_SCHED}), обновляются те же файлы." \
               "Expiry is checked every day at 03:30 (${RENEW_SCHED}); the same files are updated."
        else
            warn "Не удалось настроить ежедневный запуск: нет ни cron, ни systemd." \
                 "Could not schedule the daily run: neither cron nor systemd found."
            warn "Добавьте в планировщик: ${CMD_TARGET:-$0} --renew" \
                 "Add this to your scheduler: ${CMD_TARGET:-$0} --renew"
        fi
        blank

        if (( ${#due[@]} > 0 )); then
            warn "Срок истёк или скоро истечёт: ${#due[@]}. Продлить сейчас?" \
                 "Expired or expiring soon: ${#due[@]}. Renew now?"
            opt 1 "Да"  "продлить сейчас" \
                  "Yes" "renew now"
            opt 2 "Нет" "продлит ежедневная проверка" \
                  "No"  "the daily check will do it"
            blank
            c=""
            pick c 2
            if [[ "$NAV" != "back" && "$c" == "1" ]]; then
                blank
                RENEW_ECHO="yes"
                run_renew "${due[@]}"
                RENEW_ECHO=""
                blank
                if (( RENEW_FAILED == 0 )); then
                    ok "Продлено: ${RENEW_RENEWED}" "Renewed: ${RENEW_RENEWED}"
                else
                    err "Ошибок: ${RENEW_FAILED}. Подробности — выше и в ${RENEW_LOG}" \
                        "Errors: ${RENEW_FAILED}. Details above and in ${RENEW_LOG}"
                fi
            fi
            NAV=""
            blank
        fi
        pause "Нажмите Enter, чтобы вернуться в меню…" "Press Enter to return to the menu…"
        break
    done
    STEP_I=$saved_step
    NAV=""
}

# ==============================================================================
# Execute — runs the chosen method. A failure does not kill the wizard: set -e
# is active only inside the subshell, and the exit code lands in RUN_RC.
# ==============================================================================
run_selected() {
    mkdir -p "${S_OUTDIR}"

    local targets=()
    mapfile -t targets < <(wizard_targets)
    BACKUP_SET=""
    if (( ${#targets[@]} > 0 )); then
        backup_files "${targets[@]}"
        info "Файлы, которые будут перезаписаны, сохранены в: ${BACKUP_SET}" \
             "Files about to be overwritten were saved to: ${BACKUP_SET}"
        blank
    fi

    case "$S_METHOD" in
        le_standalone)      run_le_standalone      ;;
        le_webroot)         run_le_webroot         ;;
        le_nginx)           run_le_nginx           ;;
        le_wildcard_manual) run_le_wildcard_manual ;;
        le_wildcard_cf)     run_le_wildcard_cf     ;;
        ss_simple)          run_ss_simple          ;;
        ss_rsa)             run_ss_rsa             ;;
        ss_ecdsa)           run_ss_ecdsa           ;;
        ss_ed25519)         run_ss_ed25519         ;;
        ss_ca)              run_ss_ca              ;;
        keygen)             run_keygen             ;;
    esac
}

execute() {
    banner
    tl "Выполняю…" "Working…"
    echo -e "  ${BOLD}${MSG}${R}"
    hr; blank

    ( set -e; run_selected )
    RUN_RC=$?

    blank; hr
    if (( RUN_RC == 0 )); then
        ok "${BOLD}Готово.${R}  Файлы в папке: ${WHITE}${S_OUTDIR}${R}" \
           "${BOLD}Done.${R}  Files are in: ${WHITE}${S_OUTDIR}${R}"
    else
        err "${BOLD}Не получилось.${R} Причина — в сообщениях выше." \
            "${BOLD}It did not work.${R} The reason is in the messages above."
    fi
    blank
}

# ==============================================================================
# Main — walk through FLOW; "back" decreases the step number by one
# ==============================================================================
main() {
    # ssl-wizard --renew — what cron / the systemd timer runs every day
    if [[ "${1:-}" == "--renew" ]]; then
        load_lang noask
        require_root
        run_renew_mode
        exit $?
    fi

    load_lang
    require_root
    check_deps

    local i=0 c
    while true; do
        build_flow
        STEP_I=$((i + 1))
        STEP_N=${#FLOW[@]}
        NAV=""
        "${FLOW[$i]}"

        if [[ "$NAV" == "back" ]]; then
            if (( i == 0 )); then
                blank; info "Выход." "Bye."
                exit 0
            fi
            i=$((i - 1))
            continue
        fi

        i=$((i + 1))
        build_flow
        (( i < ${#FLOW[@]} )) && continue

        execute

        if (( RUN_RC == 0 )); then
            opt 1 "Создать ещё один"   "вернуться к выбору способа" \
                  "Create another"     "back to the method choice"
        else
            opt 1 "Исправить данные"   "вернуться к проверке данных" \
                  "Fix the details"    "back to the review screen"
            opt 2 "Начать заново"      "вернуться к выбору способа" \
                  "Start over"         "back to the method choice"
        fi
        blank
        c=""
        NAV=""
        if (( RUN_RC == 0 )); then
            pick c 1 exit
        else
            pick c 2 exit
        fi
        if [[ "$NAV" == "back" ]]; then
            exit 0
        fi
        if (( RUN_RC != 0 )) && [[ "$c" == "1" ]]; then
            i=$(( ${#FLOW[@]} - 1 ))
        else
            i=0
        fi
    done
}

# run only when executed, not when sourced (lets tests load the functions)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
