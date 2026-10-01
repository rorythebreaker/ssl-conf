#Requires -Version 5.1
# ==============================================================================
# ssl-wizard.ps1 - interactive SSL certificate creation wizard (Windows)
# ==============================================================================
# Usage      : ssl-wizard.cmd  (double-click)
#              or: powershell -ExecutionPolicy Bypass -File ssl-wizard.ps1
# Requires   : Windows PowerShell 5.1+. OpenSSL and the Posh-ACME module are
#              downloaded by the wizard on first run into %LOCALAPPDATA%\ssl-wizard
#              (no administrator rights needed for that).
# Navigation : at any step, 0 + Enter goes one step back.
# Language   : Russian / English. Asked on first run and remembered in
#              lang.txt; override with -Lang ru|en or SSLWIZ_LANG.
# Renewal    : Let's Encrypt certificates are renewed by a scheduled task
#              that runs this same script with -Renew.
# ==============================================================================
param(
    [switch]$Renew,         # no questions: renew certificates and exit
    [string]$HomeDir,       # components folder (default %LOCALAPPDATA%\ssl-wizard)
    [string]$Lang           # ru | en
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ==============================================================================
# Components - what is installed on first run, and from where
# ==============================================================================
# The components folder can be overridden with -HomeDir or SSLWIZ_HOME
$script:HomeDir = if ($HomeDir) { $HomeDir } elseif ($env:SSLWIZ_HOME) { $env:SSLWIZ_HOME } else { Join-Path $env:LOCALAPPDATA 'ssl-wizard' }
$script:HomeDir = $script:HomeDir.TrimEnd('\')

# Auto-renewal: scheduled task, list of certificates and log
$script:SelfPath  = $PSCommandPath
$script:RenewTask = 'ssl-wizard-renew'
$script:RenewList = Join-Path $script:HomeDir 'renew.json'
$script:RenewLog  = Join-Path $script:HomeDir 'renew.log'
$script:RenewHook = Join-Path $script:HomeDir 'after-renew.ps1'

# Backups: files are copied here before the wizard overwrites them
$script:BackupDir  = Join-Path $script:HomeDir 'backup'
$script:BackupKeep = 30         # how many newest backup sets to keep
$script:BackupSet  = $null      # folder of the current backup set

# Command the wizard installs itself under on PATH (see Install-Command)
$script:CmdName = 'ssl-wizard'

# Portable OpenSSL build (zip, no installer); integrity is checked by SHA-256
$script:OpenSslUrl    = 'https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.6.0.zip'
$script:OpenSslSha256 = 'C1C831E8BCCE7D6C204D6813AAFB87C0D44DD88841AB31105185B55CDEC1D759'
$script:PoshAcmeUrl   = 'https://www.powershellgallery.com/api/v2/package/Posh-ACME'

$script:OpenSsl  = $null    # full path to openssl.exe
$script:PoshAcme = $null    # module name or path for Import-Module

# ==============================================================================
# Language
#   L 'ru text' 'en text' returns the text for the current language.
# ==============================================================================
$script:UiLang   = ''       # ru | en (not $script:Lang: that is the -Lang parameter)
$script:LangFile = Join-Path $script:HomeDir 'lang.txt'

function L([string]$Ru, [string]$En) {
    if ($script:UiLang -eq 'ru') { return $Ru }
    return $En
}

# ==============================================================================
# State
# ==============================================================================
$script:S = @{
    Method = ''; Format = ''; Domain = ''; Www = ''; Email = ''
    Country = ''; State = ''; City = ''; Org = ''; OU = ''
    Days = ''; OutDir = ''; Webroot = ''; CfToken = ''
    Passphrase = ''     # yes | no
    KeygenAlgo = ''     # rsa | ecdsa | ed25519 | rand
    RsaBits = ''; EcCurve = ''; RandFormat = ''; RandBytes = ''
}

$script:MethodRu = @{
    le_standalone      = "Let's Encrypt - автономно (порт 80)"
    le_webroot         = "Let's Encrypt - через папку сайта"
    le_wildcard_manual = "Let's Encrypt - wildcard, DNS вручную"
    le_wildcard_cf     = "Let's Encrypt - wildcard, Cloudflare"
    ss_simple          = 'Самоподписанный - быстрый'
    ss_rsa             = 'Самоподписанный - RSA'
    ss_ecdsa           = 'Самоподписанный - ECDSA'
    ss_ed25519         = 'Самоподписанный - Ed25519'
    ss_ca              = 'Свой центр сертификации + сертификат'
    keygen             = 'Только ключ / случайная строка'
}
$script:MethodEn = @{
    le_standalone      = "Let's Encrypt - standalone (port 80)"
    le_webroot         = "Let's Encrypt - via site folder"
    le_wildcard_manual = "Let's Encrypt - wildcard, manual DNS"
    le_wildcard_cf     = "Let's Encrypt - wildcard, Cloudflare"
    ss_simple          = 'Self-signed - quick'
    ss_rsa             = 'Self-signed - RSA'
    ss_ecdsa           = 'Self-signed - ECDSA'
    ss_ed25519         = 'Self-signed - Ed25519'
    ss_ca              = 'Own certificate authority + certificate'
    keygen             = 'Key / random string only'
}

# ==============================================================================
# Navigation
#   Nav   - a step sets it to 'back' when the user enters 0
#   Flow  - list of steps for the chosen method (see Build-Flow)
#   StepI / StepN - current step number and total (for the header)
# ==============================================================================
$script:Nav   = ''
$script:Flow  = @()
$script:StepI = 1
$script:StepN = 1
$script:RunOk = $true
$script:RenewEcho   = $false    # also print renewal log lines (renewing from the menu)
$script:RenewResult = @{}       # counts from the last Invoke-RenewalCore

# ==============================================================================
# Logging
# ==============================================================================
function Info([string]$Text)  { Write-Host '  * ' -ForegroundColor Cyan   -NoNewline; Write-Host $Text }
function Ok([string]$Text)    { Write-Host '  + ' -ForegroundColor Green  -NoNewline; Write-Host $Text }
function Warn([string]$Text)  { Write-Host '  ! ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Err([string]$Text)   { Write-Host '  x ' -ForegroundColor Red    -NoNewline; Write-Host $Text }
function Blank                { Write-Host '' }
function Hr                   { Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray }
function Hint([string]$Text)  { Write-Host "  $Text" -ForegroundColor DarkGray }

# Opt N 'name' 'description'
function Opt([string]$Num, [string]$Name, [string]$Desc = '') {
    Write-Host ('  {0,3})  ' -f $Num) -ForegroundColor Blue -NoNewline
    Write-Host ($Name.PadRight(24) + ' ') -NoNewline
    Write-Host $Desc -ForegroundColor DarkGray
}

function Row([string]$Name, [string]$Value) {
    Write-Host ('  ' + $Name.PadRight(13) + ':  ') -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor White
}

# OkF 'label' 'value' - aligned "label : value" result line
function OkF([string]$Label, [string]$Value) { Ok ($Label.PadRight(11) + ": $Value") }

# ==============================================================================
# Helpers
# ==============================================================================
function Read-Line {
    $line = [Console]::ReadLine()
    if ($null -eq $line) { exit 0 }     # input closed
    return $line.Trim()
}

function Pause-Wizard([string]$Text = '') {
    if (-not $Text) { $Text = L 'Нажмите Enter, чтобы продолжить...' 'Press Enter to continue...' }
    Write-Host "  $Text" -NoNewline
    [void](Read-Line)
}

# Read-Pick MAX [-Exit] - returns the number; 0 - back (Nav = back).
# With -Exit the prompt says 0 quits the wizard.
function Read-Pick([int]$Max, [switch]$Exit) {
    $zero = if ($Exit) { L 'выход' 'exit' } else { L 'назад' 'back' }
    $your = L 'Ваш выбор' 'Your choice'
    while ($true) {
        Write-Host "  $your [1-$Max]  " -NoNewline
        Write-Host "(0 - $zero)" -ForegroundColor DarkGray -NoNewline
        Write-Host ': ' -NoNewline
        $in = Read-Line
        if ($in -eq '0' -or $in -eq 'b') {
            $script:Nav = 'back'
            return 0
        }
        $n = 0
        if ([int]::TryParse($in, [ref]$n) -and $n -ge 1 -and $n -le $Max) {
            return $n
        }
        Warn (L "Введите число от 1 до $Max или 0." "Enter a number from 1 to $Max, or 0.")
    }
}

# Read-Answer KEY 'prompt' ['default'] [check]
# Enter - take the value in brackets; 0 - back (Nav = back).
# Check - a block returning the error text or $null.
# Reads a line without echoing it (passwords, tokens). Redirected input - plain read
function Read-Secret {
    if ([Console]::IsInputRedirected) { return Read-Line }
    $chars = New-Object Text.StringBuilder
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { break }
        if ($k.Key -eq 'Backspace') {
            if ($chars.Length -gt 0) { [void]$chars.Remove($chars.Length - 1, 1) }
            continue
        }
        [void]$chars.Append($k.KeyChar)
    }
    Write-Host ''
    return $chars.ToString().Trim()
}

# With $script:AskSecret the input is not echoed and the default is shown as ***
$script:AskSecret = $false
function Read-Answer([string]$Key, [string]$Prompt, [string]$Default = '', [scriptblock]$Check = $null) {
    if ($script:S[$Key]) { $Default = $script:S[$Key] }
    while ($true) {
        Write-Host "  $Prompt" -NoNewline
        if ($Default) {
            $shown = if ($script:AskSecret) { '***' } else { $Default }
            Write-Host " [$shown]" -ForegroundColor DarkGray -NoNewline
        }
        Write-Host ': ' -NoNewline
        $in = if ($script:AskSecret) { Read-Secret } else { Read-Line }
        if ($in -eq '0') {
            $script:Nav = 'back'
            return
        }
        if (-not $in) { $in = $Default }
        if (-not $in) {
            Warn (L 'Поле не может быть пустым.' 'This field cannot be empty.')
            continue
        }
        if ($Check) {
            $problem = & $Check $in
            if ($problem) {
                Warn $problem
                continue
            }
        }
        $script:S[$Key] = $in
        return
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Ip([string]$Value) { return $Value -match '^\d+\.\d+\.\d+\.\d+$' }

# ==============================================================================
# Language selection
# ==============================================================================
function Choose-Lang {
    try { Clear-Host } catch { }
    Blank
    Write-Host '  Язык / Language' -ForegroundColor White
    Hr; Blank
    Opt 1 'Русский'
    Opt 2 'English'
    Blank; Hr; Blank
    while ($true) {
        Write-Host '  [1-2]: ' -NoNewline
        $in = Read-Line
        if ($in -eq '1') { $script:UiLang = 'ru'; break }
        if ($in -eq '2') { $script:UiLang = 'en'; break }
    }
    try {
        New-Item -ItemType Directory -Force -Path $script:HomeDir | Out-Null
        [IO.File]::WriteAllText($script:LangFile, $script:UiLang)
    } catch { }
}

# -Lang wins, then SSLWIZ_LANG, then the remembered choice, otherwise ask.
# In -Renew mode nobody can answer, so the fallback is English.
function Load-Lang([string]$Requested, [bool]$CanAsk) {
    $saved = ''
    if (Test-Path -LiteralPath $script:LangFile) {
        try { $saved = [IO.File]::ReadAllText($script:LangFile).Trim() } catch { }
    }
    foreach ($candidate in $Requested, $env:SSLWIZ_LANG, $saved) {
        if ($candidate -eq 'ru' -or $candidate -eq 'en') {
            $script:UiLang = $candidate.ToLower()
            return
        }
    }
    if ($CanAsk) { Choose-Lang } else { $script:UiLang = 'en' }
}

# ==============================================================================
# Validators - return the error text or $null
# ==============================================================================
$script:CheckDomain = {
    param($v)
    if ($v -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        return (L 'Только латинские буквы, цифры, точки и дефисы. Пример: example.com' `
                  'Latin letters, digits, dots and hyphens only. Example: example.com')
    }
    if ($script:S.Method -like 'le_*') {
        if (Test-Ip $v) {
            return (L "Let's Encrypt не выдаёт сертификаты на IP. Нужен домен." `
                      "Let's Encrypt does not issue certificates for IPs. A domain is required.")
        }
        if ($v -notlike '*.*') {
            return (L 'Нужен настоящий домен, например example.com' 'A real domain is required, e.g. example.com')
        }
        if ($v -like 'www.*') {
            return (L 'Введите домен без www - его можно добавить на следующем шаге.' `
                      'Enter the domain without www - you can add it at the next step.')
        }
    }
    return $null
}

$script:CheckEmail = {
    param($v)
    if ($v -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        return (L 'Это не похоже на e-mail. Пример: admin@example.com' `
                  'This does not look like an e-mail. Example: admin@example.com')
    }
    return $null
}

$script:CheckCountry = {
    param($v)
    if ($v -notmatch '^[A-Za-z]{2}$') {
        return (L 'Нужны ровно 2 латинские буквы. Пример: RU' 'Exactly 2 Latin letters are required. Example: US')
    }
    return $null
}

$script:CheckDays = {
    param($v)
    $n = 0
    if (-not ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 36500)) {
        return (L 'Введите число дней от 1 до 36500.' 'Enter a number of days from 1 to 36500.')
    }
    return $null
}

$script:CheckBytes = {
    param($v)
    $n = 0
    if (-not ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 4096)) {
        return (L 'Введите число от 1 до 4096.' 'Enter a number from 1 to 4096.')
    }
    return $null
}

# ==============================================================================
# Banner / step header
# ==============================================================================
function Banner {
    $title = (L 'Мастер создания SSL-сертификатов' 'SSL Certificate Creation Wizard').PadRight(52)
    try { Clear-Host } catch { }
    Blank
    Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Blue
    Write-Host '  ║' -ForegroundColor Blue -NoNewline
    Write-Host "  $title" -ForegroundColor White -NoNewline
    Write-Host '║' -ForegroundColor Blue
    Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Blue
    Blank
}

# Screen 'step title'
function Screen([string]$Title) {
    $step = L 'Шаг' 'Step'
    $of   = L 'из' 'of'
    Banner
    if ($script:StepI -eq 0) {
        # screens outside the step-by-step flow (folder scan)
        Write-Host "  $Title" -ForegroundColor White
    } elseif ($script:StepI -eq 1) {
        Write-Host "  $step 1 - $Title" -ForegroundColor White
    } else {
        Write-Host "  $step $($script:StepI) $of $($script:StepN) - $Title" -ForegroundColor White
    }
    Hr; Blank
}

# ==============================================================================
# COMPONENTS - on first run everything missing is installed automatically
# ==============================================================================
function Find-OpenSsl {
    $candidates = @(
        (Join-Path $script:HomeDir 'openssl\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'FireDaemon OpenSSL 3\bin\openssl.exe')
    )
    $inPath = Get-Command openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inPath) { return $inPath.Source }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-ArchDir {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { return 'x86' }
    }
}

# Downloads the zip and extracts only the needed architecture from it.
# Files are deleted via .NET: Remove-Item fails on short paths like C:\Users\NAME~1
function Install-OpenSsl {
    $zip    = Join-Path $env:TEMP 'ssl-wizard-openssl.zip'
    $target = Join-Path $script:HomeDir 'openssl'
    $arch   = Get-ArchDir

    Invoke-WebRequest -Uri $script:OpenSslUrl -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($hash -ne $script:OpenSslSha256) {
        [IO.File]::Delete($zip)
        throw (L 'скачанный файл OpenSSL повреждён (не совпала контрольная сумма)' `
                 'the downloaded OpenSSL file is corrupted (checksum mismatch)')
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name.EndsWith('/')) { continue }
            # <arch>/bin/... -> openssl/bin/...,  ssl/... -> openssl/ssl/...
            if ($name.StartsWith("$arch/bin/") -or $name.StartsWith("$arch/lib/ossl-modules/")) {
                $rel = $name.Substring($arch.Length + 1)
            } elseif ($name.StartsWith('ssl/')) {
                $rel = $name
            } else {
                continue
            }
            $dest = Join-Path $target $rel.Replace('/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    } finally {
        $archive.Dispose()
    }
    [IO.File]::Delete($zip)
}

# The portable build has to be told where its configuration and modules live
function Set-OpenSslEnv {
    $root = Split-Path (Split-Path $script:OpenSsl -Parent) -Parent
    if (-not $root.StartsWith($script:HomeDir, [StringComparison]::OrdinalIgnoreCase)) { return }
    $cnf = Join-Path $root 'ssl\openssl.cnf'
    $mod = Join-Path $root 'lib\ossl-modules'
    if (Test-Path -LiteralPath $cnf) { $env:OPENSSL_CONF    = $cnf }
    if (Test-Path -LiteralPath $mod) { $env:OPENSSL_MODULES = $mod }
}

function Find-PoshAcme {
    if (Get-Module -ListAvailable -Name Posh-ACME) { return 'Posh-ACME' }
    $local = Join-Path $script:HomeDir 'modules\Posh-ACME\Posh-ACME.psd1'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

# A PowerShell Gallery package is a plain zip; unpack it without Install-Module
# so there is no dependency on the NuGet provider or administrator rights
function Install-PoshAcme {
    $zip    = Join-Path $env:TEMP 'ssl-wizard-posh-acme.zip'
    $target = Join-Path $script:HomeDir 'modules\Posh-ACME'
    Invoke-WebRequest -Uri $script:PoshAcmeUrl -OutFile $zip -UseBasicParsing
    if (Test-Path -LiteralPath $target) { [IO.Directory]::Delete($target, $true) }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
    [IO.File]::Delete($zip)
    if (-not (Test-Path -LiteralPath (Join-Path $target 'Posh-ACME.psd1'))) {
        throw (L 'в скачанном пакете нет модуля Posh-ACME' 'the downloaded package does not contain the Posh-ACME module')
    }
}

$script:DepsChanged = $false
$script:DepsError   = ''

# Puts the wizard on the user's PATH as the "ssl-wizard" command, so it can be
# started from any folder. PATH gets <HomeDir>\bin with a small launcher that
# runs a copy of this script; running a newer script refreshes the copy.
# Set SSLWIZ_NO_PATH=1 to skip. Returns $true when PATH was changed.
function Install-Command {
    if ($env:SSLWIZ_NO_PATH) { return $false }

    $bin  = Join-Path $script:HomeDir 'bin'
    $copy = Join-Path $script:HomeDir 'ssl-wizard.ps1'
    $shim = Join-Path $bin "$($script:CmdName).cmd"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null

    if ($script:SelfPath -ne $copy) {
        $same = (Test-Path -LiteralPath $copy) -and
                ((Get-FileHash -LiteralPath $copy).Hash -eq (Get-FileHash -LiteralPath $script:SelfPath).Hash)
        if (-not $same) { Copy-Item -LiteralPath $script:SelfPath -Destination $copy -Force }
    }
    $launcher = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\ssl-wizard.ps1`" %*`r`n"
    [IO.File]::WriteAllText($shim, $launcher, [Text.Encoding]::ASCII)

    # read and write the raw registry value: going through
    # [Environment]::GetEnvironmentVariable would expand %VARS% inside PATH for good
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($current -split ';' | Where-Object { $_ })
        if ($entries | Where-Object { $_.TrimEnd('\') -ieq $bin }) { return $false }
        $kind = if ($current) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue('Path', (($entries + $bin) -join ';'), $kind)
    } finally {
        $key.Close()
    }
    $env:Path = $env:Path.TrimEnd(';') + ';' + $bin

    # a registry write alone is not seen by running programs; setting and removing
    # a dummy variable makes Windows broadcast the "environment changed" message
    [Environment]::SetEnvironmentVariable('SSLWIZ_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('SSLWIZ_PATH_REFRESH', $null, 'User')
    return $true
}

# Ensure-Component 'name' {find} {install} - present -> ok; missing -> install
function Ensure-Component([string]$Name, [scriptblock]$Find, [scriptblock]$Install) {
    $label = $Name.PadRight(10)
    $found = & $Find
    if ($found) {
        Ok (L "$label установлен" "$label installed")
        return $found
    }
    Info (L "$label не найден - скачиваю и устанавливаю..." "$label not found - downloading and installing...")
    $script:DepsChanged = $true
    $script:DepsError   = L 'нет подключения к интернету?' 'no internet connection?'
    try {
        & $Install | Out-Null
        $found = & $Find
    } catch {
        $found = $null
        $script:DepsError = $_.Exception.Message
    }
    if ($found) {
        Ok (L "$label установлен в $($script:HomeDir)" "$label installed to $($script:HomeDir)")
        return $found
    }
    Err (L "$label не удалось установить: $($script:DepsError)" "$label could not be installed: $($script:DepsError)")
    return $null
}

function Check-Deps {
    Banner
    Write-Host ('  ' + (L 'Проверка компонентов' 'Checking components')) -ForegroundColor White
    Hint (L 'Чего не хватает - мастер установит сам.' 'Anything missing is installed automatically.')
    Hr; Blank

    $script:OpenSsl  = Ensure-Component 'OpenSSL'   { Find-OpenSsl }  { Install-OpenSsl }
    $script:PoshAcme = Ensure-Component 'Posh-ACME' { Find-PoshAcme } { Install-PoshAcme }

    if (-not $script:OpenSsl) {
        Blank
        Err (L 'Без OpenSSL мастер работать не может. Проверьте интернет и запустите снова.' `
               'The wizard cannot work without OpenSSL. Check your internet connection and run again.')
        Blank
        Pause-Wizard (L 'Нажмите Enter для выхода...' 'Press Enter to exit...')
        exit 1
    }
    Set-OpenSslEnv

    try {
        if (Install-Command) {
            $script:DepsChanged = $true
            $bin = Join-Path $script:HomeDir 'bin'
            Ok (L "Команда $($script:CmdName) добавлена в PATH ($bin)" `
                  "The $($script:CmdName) command was added to PATH ($bin)")
            Hint (L "    Откройте новое окно терминала - мастер запускается из любой папки: $($script:CmdName)" `
                    "    Open a new terminal window - the wizard starts from any folder: $($script:CmdName)")
        }
    } catch {
        Warn (L "Не удалось добавить команду $($script:CmdName) в PATH: $($_.Exception.Message)" `
                "Could not add the $($script:CmdName) command to PATH: $($_.Exception.Message)")
    }

    if (-not $script:PoshAcme) {
        Blank
        Warn (L "Posh-ACME не установлен - способы Let's Encrypt будут недоступны." `
                "Posh-ACME is not installed - Let's Encrypt methods will be unavailable.")
        Warn (L 'Самоподписанные сертификаты работают.' 'Self-signed certificates still work.')
        Blank
        Pause-Wizard
    } elseif ($script:DepsChanged) {
        Blank
        Ok (L 'Все компоненты готовы.' 'All components are ready.')
        Blank
        Pause-Wizard
    }
}

# Check before entering a method: is everything it needs in place
function Test-MethodReady {
    if ($script:S.Method -like 'le_*' -and -not $script:PoshAcme) {
        $script:PoshAcme = Ensure-Component 'Posh-ACME' { Find-PoshAcme } { Install-PoshAcme }
        if (-not $script:PoshAcme) { return $false }
    }
    if ($script:S.Method -eq 'le_standalone' -and -not (Test-Admin)) {
        Err (L 'Для этого способа нужны права администратора (порт 80).' `
               'This method needs administrator rights (port 80).')
        Err (L 'Запустите мастер от имени администратора или выберите другой способ.' `
               'Run the wizard as administrator or choose another method.')
        return $false
    }
    return $true
}

# ==============================================================================
# STEPS - each step is one screen. 0 -> Nav = back -> Main goes one step back
# ==============================================================================
function Step-Method {
    $methods = @('le_standalone', 'le_webroot', 'le_wildcard_manual', 'le_wildcard_cf',
                 'ss_simple', 'ss_rsa', 'ss_ecdsa', 'ss_ed25519', 'ss_ca', 'keygen')
    while ($true) {
        Screen (L 'Какой сертификат нужен?' 'Which certificate do you need?')

        Write-Host "  Let's Encrypt" -ForegroundColor Cyan -NoNewline
        Hint (L '- бесплатный, браузеры ему доверяют.' '- free, trusted by browsers.')
        Hint (L 'Нужен свой домен, направленный на этот компьютер. Срок 90 дней.' `
                'Needs your own domain pointing to this computer. Valid 90 days.')
        Opt 1 (L 'Автономно' 'Standalone') `
              (L 'порт 80 свободен, веб-сервера нет' 'port 80 is free, no web server running')
        Opt 2 (L 'Через папку сайта' 'Via site folder') `
              (L 'сайт уже работает, останавливать нельзя' 'site is already running, cannot be stopped')
        Opt 3 (L 'Wildcard, DNS вручную' 'Wildcard, manual DNS') `
              (L '*.домен; запись в DNS добавляете сами' '*.domain; you add the DNS record yourself')
        Opt 4 'Wildcard, Cloudflare' `
              (L '*.домен; автоматически по токену' '*.domain; automatic via API token')
        Blank
        Write-Host ('  ' + (L 'Самоподписанный' 'Self-signed')) -ForegroundColor Magenta -NoNewline
        Hint (L '- для тестов и внутренней сети.' '- for testing and internal networks.')
        Hint (L 'Домен не нужен. Браузер покажет предупреждение.' 'No domain needed. Browsers will show a warning.')
        Opt 5 (L 'Быстрый' 'Quick') `
              (L 'всего 3 вопроса' 'just 3 questions')
        Opt 6 'RSA' `
              (L 'работает везде; не знаете - берите его' 'works everywhere; pick this if unsure')
        Opt 7 'ECDSA' `
              (L 'быстрее и компактнее, для новых систем' 'faster and smaller, for modern systems')
        Opt 8 'Ed25519' `
              (L 'самый новый; браузеры не поддерживают' 'newest; not supported by browsers')
        Opt 9 (L 'Свой центр (CA)' 'Own authority (CA)') `
              (L 'без предупреждений на своих компьютерах' 'no warnings on your own computers')
        Blank
        Write-Host ('  ' + (L 'Прочее' 'Other')) -ForegroundColor White
        Opt 10 (L 'Ключ или пароль' 'Key or password') `
               (L 'только ключ или случайная строка' 'a key or a random string only')
        Opt 11 (L 'Сканировать папку' 'Scan a folder') `
               (L 'найти сертификаты и поставить на автопродление' 'find certificates and put them on auto-renewal')
        Opt 12 (L 'Настройки' 'Settings') `
               (L 'автоисправление порта 80, уведомления' 'port 80 auto-fix, notifications')
        Opt 13 'Язык / Language' (L 'English' 'Русский')
        Blank; Hr; Blank

        $c = Read-Pick 13 -Exit
        if ($script:Nav -eq 'back') { return }

        if ($c -eq 11) {
            Step-Scan
            continue
        }
        if ($c -eq 12) {
            Step-Settings
            continue
        }
        if ($c -eq 13) {
            Choose-Lang
            continue
        }

        $script:S.Method = $methods[$c - 1]
        if (Test-MethodReady) { return }
        Blank
        Pause-Wizard (L 'Нажмите Enter, чтобы выбрать другой способ...' 'Press Enter to choose another method...')
    }
}

function Step-Format {
    Screen (L 'В каком виде сохранить файлы?' 'How should the files be saved?')
    Opt 1 (L 'Обычный (.crt + .key)' 'Regular (.crt + .key)') `
          (L 'nginx, Apache - подходит почти всегда' 'nginx, Apache - fits almost always')
    Opt 2 'fullchain + privkey' `
          (L "те же файлы с именами как у Let's Encrypt" "same files, named the Let's Encrypt way")
    Opt 3 'PKCS#12 (.p12)' `
          (L 'один файл для Windows, IIS, Java' 'a single file for Windows, IIS, Java')
    Blank
    Hint (L 'Не знаете - выбирайте 1. Для .p12 файлы .crt и .key тоже сохранятся.' `
            'If unsure, choose 1. With .p12 the .crt and .key files are saved too.')
    Blank; Hr; Blank

    $c = Read-Pick 3
    if ($script:Nav -eq 'back') { return }
    $script:S.Format = @('pem', 'bundle', 'p12')[$c - 1]
}

function Step-Domain {
    Screen (L 'Для какого адреса сертификат?' 'Which address is the certificate for?')
    if ($script:S.Method -like 'le_wildcard_*') {
        Hint (L 'Введите основной домен, например example.com' 'Enter the base domain, e.g. example.com')
        Hint (L 'Сертификат подойдёт для него и всех поддоменов (*.example.com).' `
                'The certificate will cover it and all subdomains (*.example.com).')
    } elseif ($script:S.Method -like 'le_*') {
        Hint (L 'Введите домен без www, например example.com' 'Enter the domain without www, e.g. example.com')
        Hint (L 'Он уже должен открываться с этого компьютера.' 'It must already point to this computer.')
    } else {
        Hint (L 'Домен или IP, по которому открывают сервер.' 'The domain or IP used to reach the server.')
        Hint (L 'Примеры: example.local, 192.168.1.10' 'Examples: example.local, 192.168.1.10')
    }
    Hint (L '0 - назад.' '0 - back.')
    Blank
    Read-Answer 'Domain' (L 'Домен' 'Domain') '' $script:CheckDomain
}

function Step-Www {
    $d = $script:S.Domain
    Screen (L 'Добавить адрес с www?' 'Add the www address too?')
    Opt 1 (L 'Да' 'Yes') (L "сертификат для $d и www.$d" "certificate for $d and www.$d")
    Opt 2 (L 'Нет' 'No')  (L "только $d" "$d only")
    Blank
    Hint (L "'Да' выбирайте, только если www.$d тоже ведёт на этот компьютер," `
            "Choose Yes only if www.$d also points to this computer,")
    Hint (L 'иначе выпуск завершится ошибкой.' 'otherwise issuance will fail.')
    Blank; Hr; Blank

    $c = Read-Pick 2
    if ($script:Nav -eq 'back') { return }
    $script:S.Www = @('yes', 'no')[$c - 1]
}

function Step-Email {
    Screen (L 'Ваш e-mail' 'Your e-mail')
    Hint (L "На него Let's Encrypt напомнит, если сертификат скоро истечёт." `
            "Let's Encrypt will use it to warn you before the certificate expires.")
    Hint (L '0 - назад.' '0 - back.')
    Blank
    Read-Answer 'Email' 'E-mail' '' $script:CheckEmail
}

function Step-Webroot {
    Screen (L 'Папка сайта' 'Site folder')
    Hint (L 'Папка, из которой веб-сервер отдаёт файлы сайта.' 'The folder your web server serves the site files from.')
    Hint (L 'Мастер положит туда временный файл для проверки домена.' `
            'The wizard puts a temporary file there to verify the domain.')
    Hint (L 'Enter - оставить значение в скобках, 0 - назад.' 'Enter - keep the value in brackets, 0 - back.')
    Blank
    Read-Answer 'Webroot' (L 'Путь к папке' 'Folder path') 'C:\inetpub\wwwroot'
}

function Step-CfToken {
    Screen (L 'Токен Cloudflare' 'Cloudflare token')
    Hint (L 'Нужен, чтобы мастер сам добавил проверочную запись в DNS.' `
            'Lets the wizard add the verification DNS record for you.')
    Hint (L 'Где взять: Cloudflare -> My Profile -> API Tokens -> Create Token' `
            'Where to get it: Cloudflare -> My Profile -> API Tokens -> Create Token')
    Hint (L "-> шаблон 'Edit zone DNS' -> выбрать свой домен." "-> 'Edit zone DNS' template -> select your domain.")
    Hint (L '0 - назад.' '0 - back.')
    Blank
    $script:S.CfToken = ''
    Read-Answer 'CfToken' (L 'API-токен' 'API token')
}

function Step-Subject {
    Screen (L 'Сведения о владельце' 'Owner details')
    Hint (L 'Это просто подписи внутри сертификата, на работу не влияют.' `
            'These are just labels inside the certificate; they do not affect how it works.')
    Hint (L 'Не знаете, что писать - жмите Enter. 0 - назад к прошлому вопросу.' `
            'If unsure, just press Enter. 0 - back to the previous question.')
    Blank

    $fields = @(
        @{ Key = 'Country'; Prompt = (L 'Страна (2 буквы)' 'Country (2 letters)'); Default = (L 'RU' 'US');             Check = $script:CheckCountry },
        @{ Key = 'State';   Prompt = (L 'Регион' 'State / region');                Default = (L 'Moscow' 'New York'); Check = $null },
        @{ Key = 'City';    Prompt = (L 'Город' 'City');                           Default = (L 'Moscow' 'New York'); Check = $null },
        @{ Key = 'Org';     Prompt = (L 'Организация' 'Organization');             Default = 'MyCompany'; Check = $null },
        @{ Key = 'OU';      Prompt = (L 'Отдел' 'Department');                     Default = 'IT';        Check = $null }
    )
    $j = 0
    while ($j -lt $fields.Count) {
        $f = $fields[$j]
        $script:Nav = ''
        Read-Answer $f.Key $f.Prompt $f.Default $f.Check
        if ($script:Nav -eq 'back') {
            # from the first question - to the previous step, otherwise - previous question
            if ($j -eq 0) { return }
            $j--
            $script:Nav = ''
        } else {
            $j++
        }
    }
    $script:S.Country = $script:S.Country.ToUpper()
}

function Step-Days {
    Screen (L 'Срок действия' 'Validity period')
    Hint (L 'Сколько дней сертификат будет действовать.' 'How many days the certificate stays valid.')
    Hint (L '365 - год. Браузеры не принимают срок больше 398 дней.' `
            '365 is one year. Browsers reject anything longer than 398 days.')
    Hint (L 'Enter - оставить значение в скобках, 0 - назад.' 'Enter - keep the value in brackets, 0 - back.')
    Blank
    Read-Answer 'Days' (L 'Дней' 'Days') '365' $script:CheckDays
}

function Step-RsaBits {
    Screen (L 'Длина ключа RSA' 'RSA key size')
    Hint (L 'Чем длиннее ключ, тем надёжнее, но медленнее.' 'A longer key is stronger but slower.')
    Blank
    Opt 1 (L '2048 бит' '2048 bits') `
          (L 'быстро и достаточно надёжно - обычный выбор' 'fast and strong enough - the usual choice')
    Opt 2 (L '3072 бит' '3072 bits') `
          (L 'с запасом на будущее' 'extra margin for the future')
    Opt 3 (L '4096 бит' '4096 bits') `
          (L 'максимум защиты, заметно медленнее' 'maximum protection, noticeably slower')
    Blank; Hr; Blank

    $c = Read-Pick 3
    if ($script:Nav -eq 'back') { return }
    $script:S.RsaBits = @('2048', '3072', '4096')[$c - 1]
}

function Step-EcCurve {
    Screen (L 'Кривая ECDSA' 'ECDSA curve')
    Hint (L 'Кривая определяет стойкость ключа.' 'The curve determines key strength.')
    Blank
    Opt 1 'P-256' (L 'поддерживается везде - обычный выбор' 'supported everywhere - the usual choice')
    Opt 2 'P-384' (L 'надёжнее, чуть медленнее' 'stronger, slightly slower')
    Opt 3 'P-521' (L 'максимум; поддерживается не везде' 'maximum; not supported everywhere')
    Blank; Hr; Blank

    $c = Read-Pick 3
    if ($script:Nav -eq 'back') { return }
    $script:S.EcCurve = @('prime256v1', 'secp384r1', 'secp521r1')[$c - 1]
}

function Step-CaPass {
    Screen (L 'Пароль на ключ центра сертификации' 'Password for the CA key')
    Hint (L 'Ключом CA подписываются все ваши сертификаты - его стоит беречь.' `
            'The CA key signs all your certificates - keep it safe.')
    Blank
    Opt 1 (L 'С паролем' 'With password') `
          (L 'безопаснее; пароль спросят при каждом выпуске' 'safer; asked every time you issue a certificate')
    Opt 2 (L 'Без пароля' 'Without password') `
          (L 'удобнее; годится для тестов' 'more convenient; fine for testing')
    Blank
    Hint (L 'Если в папке уже есть ca.key и ca.crt, мастер возьмёт их.' `
            'If the folder already has ca.key and ca.crt, the wizard reuses them.')
    Blank; Hr; Blank

    $c = Read-Pick 2
    if ($script:Nav -eq 'back') { return }
    $script:S.Passphrase = @('yes', 'no')[$c - 1]
}

function Step-KeygenAlgo {
    Screen (L 'Что создать?' 'What to create?')
    Opt 1 (L 'Ключ RSA' 'RSA key')              (L 'классический, работает везде' 'classic, works everywhere')
    Opt 2 (L 'Ключ ECDSA' 'ECDSA key')          (L 'современный, короткий и быстрый' 'modern, short and fast')
    Opt 3 (L 'Ключ Ed25519' 'Ed25519 key')      (L 'самый новый, настроек нет' 'newest, nothing to configure')
    Opt 4 (L 'Случайная строка' 'Random string') (L 'для паролей, токенов и секретов' 'for passwords, tokens and secrets')
    Blank; Hr; Blank

    $c = Read-Pick 4
    if ($script:Nav -eq 'back') { return }
    $script:S.KeygenAlgo = @('rsa', 'ecdsa', 'ed25519', 'rand')[$c - 1]
}

function Step-RandFormat {
    Screen (L 'Вид случайной строки' 'Random string format')
    Opt 1 'base64' (L 'буквы, цифры и знаки + / = - строка короче' 'letters, digits and + / = - shorter string')
    Opt 2 'hex'    (L 'только цифры и буквы a-f - подходит везде' 'digits and letters a-f only - works everywhere')
    Blank; Hr; Blank

    $c = Read-Pick 2
    if ($script:Nav -eq 'back') { return }
    $script:S.RandFormat = @('base64', 'hex')[$c - 1]
}

function Step-RandBytes {
    Screen (L 'Длина случайной строки' 'Random string length')
    Hint (L 'Сколько случайных байт взять. 32 - хороший пароль или секрет.' `
            'How many random bytes to take. 32 makes a good password or secret.')
    Hint (L 'Enter - оставить значение в скобках, 0 - назад.' 'Enter - keep the value in brackets, 0 - back.')
    Blank
    Read-Answer 'RandBytes' (L 'Байт' 'Bytes') '32' $script:CheckBytes
}

function Step-OutDir {
    Screen (L 'Куда сохранить файлы?' 'Where to save the files?')
    # the current folder, not the script's: the script may be running from PATH
    $here = (Get-Location).ProviderPath
    Opt 1 (L 'Текущая папка' 'Current folder') $here
    Opt 2 (L 'Другая папка' 'Another folder') (L 'указать путь вручную' 'enter the path manually')
    Blank; Hr; Blank

    while ($true) {
        $c = Read-Pick 2
        if ($script:Nav -eq 'back') { return }
        if ($c -eq 1) {
            $script:S.OutDir = $here
            return
        }
        Blank
        Hint (L 'Полный путь, например C:\ssl\mysite. Папка создастся сама.' `
                'Full path, e.g. C:\ssl\mysite. The folder is created automatically.')
        Hint (L '0 - назад к выбору.' '0 - back to the choice.')
        $script:S.CustomDir = ''
        Read-Answer 'CustomDir' (L 'Путь к папке' 'Folder path')
        if ($script:Nav -eq 'back') {
            $script:Nav = ''
            Blank
            continue
        }
        $script:S.OutDir = $script:S.CustomDir.Trim('"').TrimEnd('\')
        return
    }
}

function Test-InFlow([string]$Step) { return $script:Flow -contains $Step }

function Step-Summary {
    $s = $script:S
    Screen (L 'Проверьте данные' 'Review your choices')
    Row (L 'Способ' 'Method') (L $script:MethodRu[$s.Method] $script:MethodEn[$s.Method])
    if (Test-InFlow 'Step-Format') {
        $files = L 'Файлы' 'Files'
        switch ($s.Format) {
            'pem'    { Row $files '.crt + .key' }
            'bundle' { Row $files 'fullchain.pem + privkey.pem' }
            'p12'    { Row $files '.crt + .key + .p12' }
        }
    }
    if (Test-InFlow 'Step-Domain') {
        if ($s.Method -like 'le_wildcard_*') {
            Row (L 'Домен' 'Domain') (L "$($s.Domain) и *.$($s.Domain)" "$($s.Domain) and *.$($s.Domain)")
        } else {
            Row (L 'Домен' 'Domain') $s.Domain
        }
    }
    if ((Test-InFlow 'Step-Www') -and $s.Www -eq 'yes') { Row (L 'Плюс' 'Plus') "www.$($s.Domain)" }
    if (Test-InFlow 'Step-Email')   { Row 'E-mail' $s.Email }
    if (Test-InFlow 'Step-Webroot') { Row (L 'Папка сайта' 'Site folder') $s.Webroot }
    if (Test-InFlow 'Step-CfToken') { Row (L 'Токен' 'Token') (L 'введён' 'entered') }
    if (Test-InFlow 'Step-Subject') {
        Row (L 'Владелец' 'Owner') "$($s.Org), $($s.OU)"
        Row (L 'Место' 'Location') "$($s.Country), $($s.State), $($s.City)"
    }
    if (Test-InFlow 'Step-Days') { Row (L 'Срок' 'Validity') (L "$($s.Days) дн." "$($s.Days) days") }
    if ($s.Method -eq 'keygen') {
        $create = L 'Создать' 'Create'
        switch ($s.KeygenAlgo) {
            'rsa'     { Row $create (L 'ключ RSA' 'RSA key') }
            'ecdsa'   { Row $create (L 'ключ ECDSA' 'ECDSA key') }
            'ed25519' { Row $create (L 'ключ Ed25519' 'Ed25519 key') }
            'rand'    { Row $create (L "случайную строку, $($s.RandBytes) байт, $($s.RandFormat)" `
                                       "random string, $($s.RandBytes) bytes, $($s.RandFormat)") }
        }
    }
    if (Test-InFlow 'Step-RsaBits') { Row (L 'Ключ RSA' 'RSA key') (L "$($s.RsaBits) бит" "$($s.RsaBits) bits") }
    if (Test-InFlow 'Step-EcCurve') { Row (L 'Кривая' 'Curve') $s.EcCurve }
    if (Test-InFlow 'Step-CaPass') {
        if ($s.Passphrase -eq 'yes') { Row (L 'Ключ CA' 'CA key') (L 'с паролем' 'with password') }
        else                         { Row (L 'Ключ CA' 'CA key') (L 'без пароля' 'without password') }
    }
    Row (L 'Папка' 'Folder') $s.OutDir
    Blank; Hr; Blank
    Opt 1 (L 'Создать' 'Create') (L 'всё верно, начинаем' 'all correct, go ahead')
    Blank

    [void](Read-Pick 1)
}

# ==============================================================================
# Flow - which steps run, and in what order, for the chosen method.
# Rebuilt before every step: the list depends on the answers given so far.
# ==============================================================================
function Build-Flow {
    $flow = @('Step-Method')
    switch ($script:S.Method) {
        ''                   { $script:Flow = $flow; return }
        'le_standalone'      { $flow += 'Step-Format', 'Step-Domain', 'Step-Www', 'Step-Email' }
        'le_webroot'         { $flow += 'Step-Format', 'Step-Domain', 'Step-Www', 'Step-Email', 'Step-Webroot' }
        'le_wildcard_manual' { $flow += 'Step-Format', 'Step-Domain', 'Step-Email' }
        'le_wildcard_cf'     { $flow += 'Step-Format', 'Step-Domain', 'Step-Email', 'Step-CfToken' }
        'ss_simple'          { $flow += 'Step-Domain', 'Step-RsaBits', 'Step-Days' }
        'ss_rsa'             { $flow += 'Step-Format', 'Step-Domain', 'Step-Subject', 'Step-Days', 'Step-RsaBits' }
        'ss_ecdsa'           { $flow += 'Step-Format', 'Step-Domain', 'Step-Subject', 'Step-Days', 'Step-EcCurve' }
        'ss_ed25519'         { $flow += 'Step-Format', 'Step-Domain', 'Step-Subject', 'Step-Days' }
        'ss_ca'              { $flow += 'Step-Format', 'Step-Domain', 'Step-Subject', 'Step-Days', 'Step-CaPass' }
        'keygen' {
            $flow += 'Step-KeygenAlgo'
            switch ($script:S.KeygenAlgo) {
                'rsa'   { $flow += 'Step-RsaBits' }
                'ecdsa' { $flow += 'Step-EcCurve' }
                'rand'  { $flow += 'Step-RandFormat', 'Step-RandBytes' }
            }
        }
    }
    $flow += 'Step-OutDir', 'Step-Summary'
    $script:Flow = $flow
}

# ==============================================================================
# OpenSSL / file helpers
# ==============================================================================
function Invoke-OpenSsl([string[]]$Arguments) {
    & $script:OpenSsl @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw (L "openssl завершился с ошибкой (код $LASTEXITCODE)" "openssl failed (exit code $LASTEXITCODE)")
    }
}

# Text files for openssl - UTF-8 without BOM
function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# chmod 600 equivalent: key access only for the owner, administrators and SYSTEM
function Protect-File([string]$Path) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${me}:F" '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
}

# Backup-Files PATHS - copies the files that exist into backup\<date_time>\ under
# their full path (C:\ssl\a.crt -> backup\2026-10-01_033000\C\ssl\a.crt).
# Returns the backup set folder, or '' when there was nothing to copy.
function Backup-Files([string[]]$Paths) {
    $existing = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
                  ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
    if ($existing.Count -eq 0) { return '' }

    if (-not $script:BackupSet) {
        if (-not (Test-Path -LiteralPath $script:BackupDir)) {
            New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
            # backups hold private keys: owner, administrators and SYSTEM only
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            & icacls.exe $script:BackupDir /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $set   = Join-Path $script:BackupDir $stamp
        $n = 1
        while (Test-Path -LiteralPath $set) { $n++; $set = Join-Path $script:BackupDir "${stamp}_$n" }
        New-Item -ItemType Directory -Force -Path $set | Out-Null
        $script:BackupSet = $set
        Remove-OldBackups
    }

    foreach ($path in $existing) {
        # C:\dir\file -> C\dir\file,  \\server\share\file -> UNC\server\share\file
        $rel  = if ($path.StartsWith('\\')) { 'UNC\' + $path.Substring(2) } else { $path -replace '^([A-Za-z]):', '$1' }
        $dest = Join-Path $script:BackupSet $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item -LiteralPath $path -Destination $dest -Force
    }
    return $script:BackupSet
}

# Keeps only the newest $BackupKeep backup sets
function Remove-OldBackups {
    $sets = @(Get-ChildItem -LiteralPath $script:BackupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($old in @($sets | Select-Object -Skip $script:BackupKeep)) {
        [IO.Directory]::Delete($old.FullName, $true)
    }
}

# Files in the output folder that the chosen method may overwrite
function Get-WizardTargets {
    $s = $script:S
    if (-not (Test-Path -LiteralPath $s.OutDir)) { return @() }
    $fixed = @('openssl.cnf', 'privkey.pem', 'cert.csr', 'fullchain.pem', 'ca.crt', 'ca.key', 'ca.srl')
    return @(Get-ChildItem -LiteralPath $s.OutDir -File | Where-Object {
        $fixed -contains $_.Name -or $_.Name -like 'key_*.pem' -or $_.Name -like 'rand_*' -or
        ($s.Domain -and ($_.Name.StartsWith("$($s.Domain).") -or $_.Name.StartsWith("$($s.Domain)_")))
    } | ForEach-Object { $_.FullName })
}

# Output file names depend on the chosen format
function Set-OutNames {
    $s = $script:S
    if ($s.Format -eq 'bundle') {
        $script:CertOut = Join-Path $s.OutDir "$($s.Domain)_fullchain.pem"
        $script:KeyOut  = Join-Path $s.OutDir "$($s.Domain)_privkey.pem"
    } else {
        $script:CertOut = Join-Path $s.OutDir "$($s.Domain).crt"
        $script:KeyOut  = Join-Path $s.OutDir "$($s.Domain).key"
    }
}

function Write-OpenSslCnf {
    $s = $script:S
    # an IP goes into SAN as IP.1, a domain - as DNS entries
    if (Test-Ip $s.Domain) {
        $alt = "IP.1 = $($s.Domain)"
    } else {
        $alt = "DNS.1 = $($s.Domain)`nDNS.2 = www.$($s.Domain)`nDNS.3 = *.$($s.Domain)"
    }
    $cnf = @"
[req]
default_bits       = 4096
default_md         = sha256
prompt             = no
utf8               = yes
distinguished_name = req_distinguished_name
req_extensions     = v3_req
x509_extensions    = v3_req

[req_distinguished_name]
C  = $($s.Country)
ST = $($s.State)
L  = $($s.City)
O  = $($s.Org)
OU = $($s.OU)
CN = $($s.Domain)

[v3_req]
basicConstraints   = CA:FALSE
keyUsage           = digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth
subjectAltName     = @alt_names

[alt_names]
$alt
"@
    $path = Join-Path $s.OutDir 'openssl.cnf'
    Write-Text $path $cnf
    return $path
}

function New-P12([string]$Cert, [string]$Key, [string]$P12, [string]$Name) {
    Invoke-OpenSsl @('pkcs12', '-export', '-in', $Cert, '-inkey', $Key, '-out', $P12, '-name', $Name, '-passout', 'pass:')
    Protect-File $P12
}

function Convert-ToP12([string]$Cert, [string]$Key) {
    $s = $script:S
    if ($s.Format -ne 'p12') { return }
    Info (L 'Собираю файл PKCS#12...' 'Building the PKCS#12 file...')
    $p12 = Join-Path $s.OutDir "$($s.Domain).p12"
    New-P12 $Cert $Key $p12 $s.Domain
    OkF 'p12' ("$p12  " + (L '(без пароля)' '(no password)'))
}

function Write-UsageHint([string]$Cert, [string]$Key) {
    Blank; Hr
    Write-Host ('  ' + (L 'Строки для конфигурации nginx:' 'Lines for the nginx configuration:')) -ForegroundColor White
    Write-Host "  ssl_certificate     $($Cert.Replace('\', '/'));"
    Write-Host "  ssl_certificate_key $($Key.Replace('\', '/'));"
    if ($script:S.Format -eq 'p12') {
        Hint (L 'Для IIS: импортируйте .p12 через диспетчер IIS -> Сертификаты сервера.' `
                'For IIS: import the .p12 via IIS Manager -> Server Certificates.')
    }
    Hr
}

# New-Key ALGORITHM FILE
function New-Key([string]$Algo, [string]$Path) {
    $s = $script:S
    switch ($Algo) {
        'rsa'     { Invoke-OpenSsl @('genpkey', '-algorithm', 'RSA', '-pkeyopt', "rsa_keygen_bits:$($s.RsaBits)", '-out', $Path) }
        'ecdsa'   { Invoke-OpenSsl @('genpkey', '-algorithm', 'EC', '-pkeyopt', "ec_paramgen_curve:$($s.EcCurve)", '-out', $Path) }
        'ed25519' { Invoke-OpenSsl @('genpkey', '-algorithm', 'Ed25519', '-out', $Path) }
    }
    Protect-File $Path
}

# ==============================================================================
# Run: Let's Encrypt (Posh-ACME)
# ==============================================================================
function Invoke-LetsEncrypt([string]$Plugin, [hashtable]$PluginArgs, [string[]]$Domains) {
    $s = $script:S
    Import-Module $script:PoshAcme
    Set-PAServer LE_PROD

    $params = @{
        Domain    = $Domains
        Contact   = $s.Email
        AcceptTOS = $true
        Plugin    = $Plugin
    }
    if ($PluginArgs.Count -gt 0) { $params.PluginArgs = $PluginArgs }

    if ($Plugin -eq 'WebSelfHost') {
        $cert = Invoke-WithPort80 { New-PACertificate @params }
    } else {
        $cert = New-PACertificate @params
    }
    # the certificate exists and is still fresh - New-PACertificate returns nothing
    if (-not $cert) { $cert = Get-PACertificate -MainDomain $Domains[0] }
    if (-not $cert) {
        throw (L 'сертификат не был выпущен - смотрите сообщения выше' `
                 'the certificate was not issued - see the messages above')
    }

    Set-OutNames
    $files = @{
        Domain  = $Domains[0]
        CertOut = $script:CertOut
        KeyOut  = $script:KeyOut
        Chain   = Join-Path $s.OutDir "$($s.Domain)_chain.pem"
        P12     = if ($s.Format -eq 'p12') { Join-Path $s.OutDir "$($s.Domain).p12" } else { '' }
    }
    Save-CertFiles $cert $files
    OkF (L 'сертификат' 'certificate') $files.CertOut
    OkF (L 'ключ' 'key') $files.KeyOut
    if (Test-Path -LiteralPath $files.Chain) { OkF (L 'цепочка' 'chain') $files.Chain }
    if ($files.P12)                          { OkF 'p12' ("$($files.P12)  " + (L '(без пароля)' '(no password)')) }
    Write-UsageHint $script:CertOut $script:KeyOut
    Blank

    if ($Plugin -eq 'Manual') {
        Warn (L 'Автопродление для этого способа невозможно: TXT-запись нужно' `
                'Auto-renewal is not possible for this method: the TXT record has to')
        Warn (L 'добавлять вручную. Раз в 2 месяца запускайте мастер ещё раз.' `
                'be added by hand. Run the wizard again every 2 months.')
        return
    }
    try {
        Register-Renewal $files
        Ok (L 'Автопродление включено: задача планировщика проверяет срок каждый день' `
              'Auto-renewal is on: a scheduled task checks the expiry date every day')
        Ok (L 'и сама обновляет файлы в этой папке (подробности в README).' `
              'and updates the files in this folder by itself (details in README).')
    } catch {
        Warn (L "Автопродление включить не удалось: $($_.Exception.Message)" `
                "Auto-renewal could not be enabled: $($_.Exception.Message)")
        Warn (L 'Раз в 2 месяца запускайте мастер ещё раз с теми же данными.' `
                'Run the wizard again with the same details every 2 months.')
    }
}

# ==============================================================================
# Auto-renewal - a scheduled task runs this script with -Renew once a day
# ==============================================================================
# Save-CertFiles CERT FILES - copies the issued certificate from the Posh-ACME
# store to the user's folder. Files: Domain, CertOut, KeyOut, Chain, P12
function Save-CertFiles($Cert, $Files) {
    [void](Backup-Files @($Files.CertOut, $Files.KeyOut, $Files.Chain, $Files.P12))
    Copy-Item -LiteralPath $Cert.FullChainFile -Destination $Files.CertOut -Force
    Copy-Item -LiteralPath $Cert.KeyFile       -Destination $Files.KeyOut  -Force
    Protect-File $Files.KeyOut
    if ($Cert.ChainFile -and (Test-Path -LiteralPath $Cert.ChainFile)) {
        Copy-Item -LiteralPath $Cert.ChainFile -Destination $Files.Chain -Force
    }
    if ($Files.P12) { New-P12 $Files.CertOut $Files.KeyOut $Files.P12 $Files.Domain }
}

function Read-RenewList {
    if (-not (Test-Path -LiteralPath $script:RenewList)) { return @() }
    $items = [IO.File]::ReadAllText($script:RenewList) | ConvertFrom-Json
    return @($items)
}

# All files an entry writes to: wizard entries have CertOut, scanned ones Outputs
function Get-EntryPaths($Entry) {
    $paths = @()
    if ($Entry.CertOut) { $paths += $Entry.CertOut }
    foreach ($o in @($Entry.Outputs)) {
        if ($o -and $o.Path) { $paths += $o.Path }
    }
    return $paths
}

# Add-RenewEntries ENTRIES - remembers where renewed certificates go and registers
# the scheduled task. An entry writing to the same files replaces the old one.
function Add-RenewEntries([object[]]$Entries) {
    $newPaths = @($Entries | ForEach-Object { Get-EntryPaths $_ })
    $list = @(Read-RenewList | Where-Object {
        $oldPaths = @(Get-EntryPaths $_)
        -not ($oldPaths | Where-Object { $newPaths -contains $_ })
    })
    $list += $Entries
    Write-Text $script:RenewList (ConvertTo-Json -InputObject $list -Depth 6)
    Register-RenewTask
}

# Entry for a certificate the wizard has just issued via Posh-ACME
function Register-Renewal($Files) {
    Add-RenewEntries @([pscustomobject]$Files)
}

function Register-RenewTask {
    # the task runs a copy of the script from the components folder: the original may be moved
    $copy = Join-Path $script:HomeDir 'ssl-wizard.ps1'
    if ($script:SelfPath -ne $copy) { Copy-Item -LiteralPath $script:SelfPath -Destination $copy -Force }

    # a regular user cannot, and should not, modify an elevated task
    $admin = Test-Admin
    if (-not $admin -and (Get-ScheduledTask -TaskName $script:RenewTask -ErrorAction SilentlyContinue)) { return }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$copy`" -Renew -HomeDir `"$($script:HomeDir)`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Daily -At '03:30'
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                     -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    # Posh-ACME keeps the account and tokens in the user profile, so the task runs
    # as that user; port 80 (the Standalone method) needs administrator rights
    $level     = if ($admin) { 'Highest' } else { 'Limited' }
    $me        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel $level
    Register-ScheduledTask -TaskName $script:RenewTask -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}

function Write-RenewLog([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    [IO.File]::AppendAllText($script:RenewLog, "$line`r`n", (New-Object Text.UTF8Encoding($false)))
    if ($script:RenewEcho) { Info $Text }
}

# ==============================================================================
# Settings - <HomeDir>\settings.json. Tokens and passwords are encrypted for the
# current Windows user (DPAPI): the renewal task runs as that user and can read them
# ==============================================================================
$script:SettingsFile = Join-Path $script:HomeDir 'settings.json'
$script:Cfg = @{
    FixStop      = $false   # may stop the service holding port 80 during a Standalone check
    FixFirewall  = $false   # may open port 80 in Windows Firewall during a Standalone check
    TgToken      = ''; TgChat = ''
    MailHost     = ''; MailPort = ''; MailSecurity = ''     # starttls | none
    MailUser     = ''; MailPass = ''; MailFrom = ''; MailTo = ''
    WebhookUrl   = ''
}
$script:CfgSecret = @('TgToken', 'MailPass', 'WebhookUrl')

function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    return ConvertFrom-SecureString (ConvertTo-SecureString $Text -AsPlainText -Force)
}

function Unprotect-Text([string]$Enc) {
    if (-not $Enc) { return '' }
    $secure = ConvertTo-SecureString $Enc
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
    try {
        $saved = [IO.File]::ReadAllText($script:SettingsFile) | ConvertFrom-Json
        foreach ($key in @($script:Cfg.Keys)) {
            if ($script:CfgSecret -contains $key) {
                $enc = $saved."${key}Enc"
                if ($enc) { $script:Cfg[$key] = Unprotect-Text $enc }
            } elseif ($null -ne $saved.$key) {
                $script:Cfg[$key] = $saved.$key
            }
        }
    } catch {
        Warn (L "Не удалось прочитать настройки: $($_.Exception.Message)" "Could not read the settings: $($_.Exception.Message)")
    }
}

function Save-Settings {
    $out = [ordered]@{}
    foreach ($key in @($script:Cfg.Keys | Sort-Object)) {
        if ($script:CfgSecret -contains $key) { $out["${key}Enc"] = Protect-Text $script:Cfg[$key] }
        else                                  { $out[$key] = $script:Cfg[$key] }
    }
    New-Item -ItemType Directory -Force -Path $script:HomeDir | Out-Null
    Write-Text $script:SettingsFile (ConvertTo-Json -InputObject $out)
}

# ==============================================================================
# Notifications - Telegram, e-mail, webhook; sent when an automatic renewal fails
# ==============================================================================
function Test-NotifyConfigured {
    $c = $script:Cfg
    return [bool](($c.TgToken -and $c.TgChat) -or ($c.MailHost -and $c.MailTo) -or $c.WebhookUrl)
}

# JSON as UTF-8 bytes: Invoke-RestMethod in PowerShell 5.1 would otherwise mangle non-ASCII text
function Send-Json([string]$Url, $Object) {
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Compress))
    [void](Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 -UseBasicParsing)
}

function Send-Telegram([string]$Text) {
    Send-Json "https://api.telegram.org/bot$($script:Cfg.TgToken)/sendMessage" @{ chat_id = $script:Cfg.TgChat; text = $Text }
}

# .NET SmtpClient: STARTTLS (EnableSsl) or no encryption; it cannot do SSL on port 465
function Send-Mail([string]$Subject, [string]$Body) {
    $c = $script:Cfg
    $msg = New-Object Net.Mail.MailMessage
    $msg.From = $c.MailFrom
    foreach ($to in ($c.MailTo -split ',')) { if ($to.Trim()) { $msg.To.Add($to.Trim()) } }
    $msg.Subject = $Subject
    $msg.SubjectEncoding = [Text.Encoding]::UTF8
    $msg.Body = $Body
    $msg.BodyEncoding = [Text.Encoding]::UTF8
    $port = if ($c.MailPort) { [int]$c.MailPort } elseif ($c.MailSecurity -eq 'starttls') { 587 } else { 25 }
    $smtp = New-Object Net.Mail.SmtpClient($c.MailHost, $port)
    $smtp.EnableSsl = $c.MailSecurity -eq 'starttls'
    $smtp.Timeout = 30000
    if ($c.MailUser) { $smtp.Credentials = New-Object Net.NetworkCredential($c.MailUser, $c.MailPass) }
    try { $smtp.Send($msg) } finally { $msg.Dispose(); $smtp.Dispose() }
}

# Webhook: "text" suits Slack/Mattermost, "content" Discord
function Send-Webhook([string]$Subject, [string]$Text) {
    Send-Json $script:Cfg.WebhookUrl ([ordered]@{
        event = 'renewal_failed'; host = $env:COMPUTERNAME; subject = $Subject
        text = "$Subject`n`n$Text"; content = "$Subject`n`n$Text"
    })
}

# Send-Notification SUBJECT TEXT - every configured channel; returns "channel: ok/error" lines
function Send-Notification([string]$Subject, [string]$Text) {
    $c = $script:Cfg
    $result = @()
    $channels = @()
    if ($c.TgToken -and $c.TgChat)  { $channels += @{ Name = 'Telegram'; Do = { Send-Telegram "$Subject`n`n$Text" } } }
    if ($c.MailHost -and $c.MailTo) { $channels += @{ Name = 'E-mail';   Do = { Send-Mail $Subject $Text } } }
    if ($c.WebhookUrl)              { $channels += @{ Name = 'Webhook';  Do = { Send-Webhook $Subject $Text } } }
    foreach ($ch in $channels) {
        try {
            & $ch.Do
            $result += "$($ch.Name): ok"
        } catch {
            $result += "$($ch.Name): " + (L 'ошибка' 'error') + " $($_.Exception.Message)"
        }
    }
    return $result
}

# The message about a renewal that did not work; results go to the renewal log
function Send-RenewFailed($Item, [string]$Name, [string]$Notes) {
    if (-not (Test-NotifyConfigured)) { return }
    $first = if ($Item.CertOut) { $Item.CertOut } else { @($Item.Outputs)[0].Path }
    $left = '?'
    try { $left = Get-DaysLeft $first } catch { }
    $subject = L "ssl-wizard: не удалось продлить сертификат $Name" "ssl-wizard: could not renew the certificate $Name"
    $text = L ("Сервер: $env:COMPUTERNAME`nСертификат: $Name`nФайл: $first`nОсталось дней: $left`n`nЧто произошло:`n$Notes`n`n" +
               "Следующая попытка - завтра. Журнал: $($script:RenewLog)") `
              ("Server: $env:COMPUTERNAME`nCertificate: $Name`nFile: $first`nDays left: $left`n`nWhat happened:`n$Notes`n`n" +
               "The next attempt is tomorrow. Log: $($script:RenewLog)")
    foreach ($line in @(Send-Notification $subject $text)) {
        Write-RenewLog ("${Name}: " + (L 'уведомление' 'notification') + " - $line")
    }
}

# ==============================================================================
# Port 80 auto-fix - when a Let's Encrypt check through port 80 (Standalone)
# fails: find out whether a process holds the port and whether Windows Firewall
# closes it, fix what the settings allow, retry once, then put everything back
# ==============================================================================
$script:P80Notes = @()      # findings and actions - for the log and notifications

function Add-P80Note([string]$Text) {
    $script:P80Notes += $Text
    Warn $Text
}

# Who listens on port 80: services that can be stopped and started, and the rest
function Get-Port80Holders {
    $holders = @{ Busy = $false; Services = @(); Others = @() }
    $pids = @(Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue |
              ForEach-Object { $_.OwningProcess } | Select-Object -Unique)
    foreach ($procId in $pids) {
        $holders.Busy = $true
        if ($procId -eq 4) {
            # PID 4 is http.sys, shared by IIS and others; IIS is the one we know how to stop
            $w3 = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
            if ($w3 -and $w3.Status -eq 'Running') {
                if ($holders.Services -notcontains 'W3SVC') { $holders.Services += 'W3SVC' }
            } else {
                $holders.Others += 'System (http.sys)'
            }
            continue
        }
        $svc = @(Get-CimInstance Win32_Service -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue)
        if ($svc.Count -gt 0) {
            foreach ($s in $svc) { if ($holders.Services -notcontains $s.Name) { $holders.Services += $s.Name } }
        } else {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $holders.Others += "$(if ($p) { $p.ProcessName } else { '?' }) (pid $procId)"
        }
    }
    return $holders
}

# Is TCP 80 closed by Windows Firewall: 'closed', 'open', or 'unknown' (cannot read rules)
function Get-FirewallState {
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' })
        if ($profiles.Count -eq 0) { return 'open' }
        if (@($profiles | Where-Object { $_.DefaultInboundAction -ne 'Allow' }).Count -eq 0) { return 'open' }
        $filters = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction Stop | Where-Object {
            foreach ($p in @($_.LocalPort)) {
                if ($p -eq '80') { return $true }
                if ($p -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 80 -and [int]$Matches[2] -ge 80) { return $true }
            }
            return $false
        })
        $allow = @($filters | Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
        if ($allow.Count -gt 0) { return 'open' }
        return 'closed'
    } catch {
        return 'unknown'
    }
}

$script:P80RuleName = 'ssl-wizard-acme-port80'

# Invoke-WithPort80 {ACTION} - runs a Let's Encrypt action that checks the domain
# through port 80. If it fails: diagnose, fix what the settings allow, retry once,
# then put everything back (also when the retry fails). Returns the action's output
function Invoke-WithPort80([scriptblock]$Action) {
    try {
        return (& $Action)
    } catch {
        $firstError = $_
    }

    Add-P80Note (L 'Проверка через порт 80 не прошла - ищу причину...' 'The check through port 80 failed - looking for the cause...')
    $holders = Get-Port80Holders
    $fw = Get-FirewallState
    foreach ($s in $holders.Services) { Add-P80Note (L "порт 80 занят службой $s" "port 80 is held by the service $s") }
    foreach ($o in $holders.Others)   { Add-P80Note (L "порт 80 занят процессом $o" "port 80 is held by the process $o") }
    if (-not $holders.Busy) { Add-P80Note (L 'порт 80 свободен' 'port 80 is free') }
    switch ($fw) {
        'closed'  { Add-P80Note (L 'Брандмауэр Windows закрывает порт 80' 'Windows Firewall closes port 80') }
        'open'    { Add-P80Note (L 'Брандмауэр Windows пропускает порт 80' 'Windows Firewall lets port 80 through') }
        'unknown' { Add-P80Note (L 'правила брандмауэра прочитать не удалось (нужны права администратора)' 'could not read the firewall rules (administrator rights needed)') }
    }
    if (-not $holders.Busy -and $fw -ne 'closed') {
        Add-P80Note (L 'на этом компьютере порту 80 ничего не мешает: вероятно, его закрывает внешний фаервол (облако, роутер, провайдер) или домен указывает на другой адрес' `
                       'nothing on this computer blocks port 80: most likely an outside firewall (cloud, router, provider) closes it, or the domain points to another address')
        throw $firstError
    }

    # what was changed, to put it back
    $stopped = @()
    $ruleAdded = $false
    $changed = $false
    try {
        if ($holders.Busy) {
            if (-not $script:Cfg.FixStop) {
                Add-P80Note (L 'останавливать службы запрещено в настройках' 'stopping services is turned off in the settings')
            } elseif ($holders.Others.Count -gt 0) {
                # without a service there is no reliable way to start it again
                Add-P80Note (L 'это не служба - мастер не останавливает её, потому что не сможет запустить обратно' `
                               'it is not a service - the wizard leaves it alone, as it could not start it again')
            } else {
                foreach ($name in $holders.Services) {
                    # stopping a service stops the services that depend on it; start those too
                    $dependents = @(Get-Service -Name $name).DependentServices | Where-Object { $_.Status -eq 'Running' } |
                                  ForEach-Object { $_.Name }
                    try {
                        Stop-Service -Name $name -Force -ErrorAction Stop
                        $stopped += @{ Name = $name; Dependents = @($dependents) }
                        Add-P80Note (L "служба $name остановлена на время проверки" "service $name stopped for the check")
                    } catch {
                        Add-P80Note (L "не удалось остановить службу ${name}: $($_.Exception.Message)" "could not stop the service ${name}: $($_.Exception.Message)")
                    }
                }
                for ($i = 0; $i -lt 10 -and (Get-Port80Holders).Busy; $i++) { Start-Sleep -Seconds 1 }
                if ((Get-Port80Holders).Busy) { Add-P80Note (L 'порт 80 всё ещё занят' 'port 80 is still in use') }
                else                          { $changed = $true }
            }
        }
        if ($fw -eq 'closed') {
            if (-not $script:Cfg.FixFirewall) {
                Add-P80Note (L 'открывать порт в брандмауэре запрещено в настройках' 'opening the firewall is turned off in the settings')
            } else {
                try {
                    New-NetFirewallRule -Name $script:P80RuleName -DisplayName 'ssl-wizard: Let''s Encrypt check (temporary)' `
                        -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                    $ruleAdded = $true
                    $changed = $true
                    Add-P80Note (L 'порт 80 временно открыт в брандмауэре' 'port 80 temporarily opened in the firewall')
                } catch {
                    Add-P80Note (L "не удалось открыть порт 80: $($_.Exception.Message)" "could not open port 80: $($_.Exception.Message)")
                }
            }
        }
        if (-not $changed) { throw $firstError }

        Add-P80Note (L 'Повторяю проверку...' 'Retrying the check...')
        try {
            return (& $Action)
        } catch {
            Add-P80Note (L 'проверка не прошла и после исправления: вероятно, порт 80 закрыт ещё и снаружи (облако, роутер, провайдер) или домен указывает на другой адрес' `
                           'the check failed even after the fix: port 80 is probably also closed outside (cloud, router, provider), or the domain points to another address')
            throw
        }
    } finally {
        if ($ruleAdded) {
            try {
                Remove-NetFirewallRule -Name $script:P80RuleName -ErrorAction Stop
                Add-P80Note (L 'порт 80 снова закрыт' 'port 80 closed again')
            } catch {
                Add-P80Note (L "НЕ удалось удалить правило $($script:P80RuleName) - удалите вручную" "could NOT remove the rule $($script:P80RuleName) - remove it by hand")
            }
        }
        foreach ($s in $stopped) {
            foreach ($name in @($s.Name) + @($s.Dependents)) {
                try {
                    Start-Service -Name $name -ErrorAction Stop
                    Add-P80Note (L "служба $name снова запущена" "service $name started again")
                } catch {
                    Add-P80Note (L "НЕ удалось запустить службу $name - запустите вручную" "could NOT start the service $name - start it by hand")
                }
            }
        }
    }
}

# ==============================================================================
# Settings menu
# ==============================================================================
function Get-OnOff([bool]$Value) { if ($Value) { return L 'вкл' 'on' } else { return L 'выкл' 'off' } }
function Get-IsSet([string]$Value) { if ($Value) { return L 'настроено' 'configured' } else { return L 'не настроено' 'not configured' } }

# "1) Set up  2) Turn off" - returns 1 / 2, 0 = back (Nav = back)
function Read-SetupOrOff {
    Opt 1 (L 'Настроить' 'Set up')   (L 'ввести данные' 'enter the details')
    Opt 2 (L 'Отключить' 'Turn off') (L 'удалить настройки' 'remove the settings')
    Blank; Hr; Blank
    return (Read-Pick 2)
}

# Read-Setting 'prompt' 'current value' [-Secret] [check] - the new value, or $null on 0 (back)
function Read-Setting([string]$Prompt, [string]$Current, [switch]$Secret, [scriptblock]$Check = $null) {
    $script:S.SettingTmp = $Current
    $script:AskSecret = [bool]$Secret
    try { Read-Answer 'SettingTmp' $Prompt '' $Check } finally { $script:AskSecret = $false }
    if ($script:Nav -eq 'back') { $script:Nav = ''; return $null }
    $value = $script:S.SettingTmp
    $script:S.SettingTmp = ''
    return $value
}

function Step-SettingsTelegram {
    Screen (L 'Уведомления: Telegram' 'Notifications: Telegram')
    Row (L 'Сейчас' 'Now') (Get-IsSet $script:Cfg.TgToken)
    Blank
    Hint (L '1. Создайте бота у @BotFather и скопируйте его токен.' '1. Create a bot with @BotFather and copy its token.')
    Hint (L '2. Напишите своему боту любое сообщение - мастер сам найдёт chat id.' '2. Send your bot any message - the wizard finds the chat id itself.')
    Blank
    $c = Read-SetupOrOff
    if ($script:Nav -eq 'back') { $script:Nav = ''; return }
    if ($c -eq 2) { $script:Cfg.TgToken = ''; $script:Cfg.TgChat = ''; Save-Settings; return }
    Blank
    $token = Read-Setting (L 'Токен бота' 'Bot token') $script:Cfg.TgToken -Secret
    if ($null -eq $token) { return }
    $found = ''
    try {
        $updates = Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates" -TimeoutSec 15 -UseBasicParsing
        $last = @($updates.result | Where-Object { $_.message.chat.id }) | Select-Object -Last 1
        if ($last) { $found = [string]$last.message.chat.id }
    } catch { }
    if ($found) { Info (L "Найден chat id: $found" "Found chat id: $found") }
    else { Hint (L 'chat id не найден автоматически: напишите боту и повторите, или введите его сами.' 'The chat id was not found automatically: message the bot and retry, or type it in.') }
    $chat = Read-Setting 'Chat id' $(if ($found) { $found } else { $script:Cfg.TgChat })
    if ($null -eq $chat) { return }
    $script:Cfg.TgToken = $token
    $script:Cfg.TgChat = $chat
    Save-Settings
    Ok (L 'Сохранено.' 'Saved.')
    Blank
    Pause-Wizard
}

function Step-SettingsMail {
    Screen (L 'Уведомления: e-mail' 'Notifications: e-mail')
    Row (L 'Сейчас' 'Now') (Get-IsSet $script:Cfg.MailHost)
    Blank
    Hint (L 'Письма отправляются через ваш почтовый сервер (SMTP).' 'Mail is sent through your mail server (SMTP).')
    Blank
    $c = Read-SetupOrOff
    if ($script:Nav -eq 'back') { $script:Nav = ''; return }
    if ($c -eq 2) {
        foreach ($k in 'MailHost', 'MailPort', 'MailSecurity', 'MailUser', 'MailPass', 'MailFrom', 'MailTo') { $script:Cfg[$k] = '' }
        Save-Settings
        return
    }
    Blank
    $mailHost = Read-Setting (L 'SMTP-сервер' 'SMTP server') $script:Cfg.MailHost
    if ($null -eq $mailHost) { return }
    Blank
    Opt 1 'STARTTLS' (L 'порт 587' 'port 587')
    Opt 2 (L 'Без шифрования' 'No encryption') (L 'порт 25' 'port 25')
    Hint (L 'SSL на порту 465 в Windows не поддерживается - выберите STARTTLS.' 'SSL on port 465 is not supported on Windows - choose STARTTLS.')
    Blank
    $s = Read-Pick 2
    if ($script:Nav -eq 'back') { $script:Nav = ''; return }
    $security = @('starttls', 'none')[$s - 1]
    $port = if ($security -eq $script:Cfg.MailSecurity -and $script:Cfg.MailPort) { $script:Cfg.MailPort } else { @('587', '25')[$s - 1] }
    $port = Read-Setting (L 'Порт' 'Port') $port
    if ($null -eq $port) { return }
    Hint (L "Логин и пароль: '-', если сервер не требует входа." "Login and password: '-' if the server needs no login.")
    $user = Read-Setting (L 'Логин' 'Login') $(if ($script:Cfg.MailUser) { $script:Cfg.MailUser } else { '-' })
    if ($null -eq $user) { return }
    if ($user -eq '-') { $user = '' }
    $pass = ''
    if ($user) {
        $pass = Read-Setting (L 'Пароль' 'Password') $script:Cfg.MailPass -Secret
        if ($null -eq $pass) { return }
    }
    $from = Read-Setting (L 'От кого (адрес)' 'From (address)') $(if ($script:Cfg.MailFrom) { $script:Cfg.MailFrom } else { $user }) -Check $script:CheckEmail
    if ($null -eq $from) { return }
    $to = Read-Setting (L 'Кому (через запятую)' 'To (comma separated)') $script:Cfg.MailTo
    if ($null -eq $to) { return }
    $script:Cfg.MailHost = $mailHost; $script:Cfg.MailPort = $port; $script:Cfg.MailSecurity = $security
    $script:Cfg.MailUser = $user; $script:Cfg.MailPass = $pass; $script:Cfg.MailFrom = $from; $script:Cfg.MailTo = $to
    Save-Settings
    Ok (L 'Сохранено.' 'Saved.')
    Blank
    Pause-Wizard
}

function Step-SettingsWebhook {
    Screen (L 'Уведомления: webhook' 'Notifications: webhook')
    Row (L 'Сейчас' 'Now') (Get-IsSet $script:Cfg.WebhookUrl)
    Blank
    Hint (L 'Мастер отправит POST с JSON: event, host, subject, text, content.' 'The wizard sends a POST with JSON: event, host, subject, text, content.')
    Hint (L 'Подходит для Slack, Mattermost, Discord и своих сервисов.' 'Works with Slack, Mattermost, Discord and your own services.')
    Blank
    $c = Read-SetupOrOff
    if ($script:Nav -eq 'back') { $script:Nav = ''; return }
    if ($c -eq 2) { $script:Cfg.WebhookUrl = ''; Save-Settings; return }
    Blank
    $url = Read-Setting 'URL' $script:Cfg.WebhookUrl
    if ($null -eq $url) { return }
    $script:Cfg.WebhookUrl = $url
    Save-Settings
    Ok (L 'Сохранено.' 'Saved.')
    Blank
    Pause-Wizard
}

function Step-SettingsTest {
    Blank
    if (-not (Test-NotifyConfigured)) {
        Warn (L 'Ни один способ уведомлений не настроен.' 'No notification channel is set up.')
        Blank
        Pause-Wizard
        return
    }
    Info (L 'Отправляю...' 'Sending...')
    $lines = Send-Notification (L 'ssl-wizard: проверка уведомлений' 'ssl-wizard: notification test') `
        (L "Это тестовое сообщение с компьютера $env:COMPUTERNAME. Так будут приходить сообщения о неудачном продлении." `
           "This is a test message from $env:COMPUTERNAME. Messages about failed renewals will arrive like this.")
    foreach ($line in @($lines)) { if ($line -like '*: ok') { Ok $line } else { Err $line } }
    Blank
    Pause-Wizard
}

# Menu item "Settings"
function Step-Settings {
    $savedStep = $script:StepI
    $script:StepI = 0
    try {
        while ($true) {
            $c = $script:Cfg
            Screen (L 'Настройки' 'Settings')
            Hint (L 'Если Let''s Encrypt не может проверить домен через порт 80 (Standalone), мастер может сам:' `
                    'When Let''s Encrypt cannot check the domain through port 80 (Standalone), the wizard may:')
            Opt 1 (L 'Останавливать службу' 'Stop the service') `
                  ("[$(Get-OnOff $c.FixStop)] " + (L 'которая заняла порт 80, и запускать после' 'holding port 80, and start it afterwards'))
            Opt 2 (L 'Открывать брандмауэр' 'Open the firewall') `
                  ("[$(Get-OnOff $c.FixFirewall)] " + (L 'временное правило для порта 80, удалять после' 'temporary rule for port 80, removed afterwards'))
            Blank
            Hint (L 'Куда сообщать, если автоматически продлить не получилось:' 'Where to report when an automatic renewal fails:')
            Opt 3 'Telegram' "[$(Get-IsSet $c.TgToken)]"
            Opt 4 'E-mail'   "[$(Get-IsSet $c.MailHost)]"
            Opt 5 'Webhook'  "[$(Get-IsSet $c.WebhookUrl)]"
            Opt 6 (L 'Проверить уведомления' 'Test notifications') (L 'отправить тестовое сообщение' 'send a test message')
            Blank
            Hint (L "Настройки хранятся в $($script:SettingsFile)" "Settings are kept in $($script:SettingsFile)")
            Blank; Hr; Blank
            $n = Read-Pick 6
            if ($script:Nav -eq 'back') { break }
            switch ($n) {
                1 { $script:Cfg.FixStop = -not $c.FixStop; Save-Settings }
                2 { $script:Cfg.FixFirewall = -not $c.FixFirewall; Save-Settings }
                3 { Step-SettingsTelegram }
                4 { Step-SettingsMail }
                5 { Step-SettingsWebhook }
                6 { Step-SettingsTest }
            }
            $script:Nav = ''
        }
    } finally {
        $script:StepI = $savedStep
        $script:Nav = ''
    }
}

# Imports Posh-ACME on first use; only Let's Encrypt entries need it
function Use-PoshAcme {
    if (Get-Module -Name Posh-ACME) { return }
    $module = Find-PoshAcme
    if (-not $module) {
        throw (L 'модуль Posh-ACME не найден - запустите мастер' 'Posh-ACME module not found - run the wizard')
    }
    Import-Module $module
    Set-PAServer LE_PROD
}

# Like Invoke-OpenSsl, but keeps openssl's chatter off the screen; on failure
# its messages go into the exception (or $null comes back with -NoThrow)
function Invoke-OpenSslQuiet([string[]]$Arguments, [switch]$NoThrow) {
    $ErrorActionPreference = 'Continue'
    $out  = & $script:OpenSsl @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) {
        if ($NoThrow) { return $null }
        throw ((L 'openssl завершился с ошибкой' 'openssl failed') + ": $text")
    }
    return $text
}

# Days until the first certificate in a file expires
function Get-DaysLeft([string]$Path) {
    $blocks = @(Get-PemCertBlocks ([IO.File]::ReadAllText($Path)))
    if ($blocks.Count -eq 0) { throw (L "в файле нет сертификата: $Path" "no certificate in file: $Path") }
    $x = New-X509 $blocks[0]
    return [int][Math]::Floor(($x.NotAfter - (Get-Date)).TotalDays)
}

# Renew when a third of the validity is left, but not earlier than 30 days before expiry
function Get-RenewThreshold([int]$ValidityDays) {
    return [Math]::Min(30, [Math]::Max(1, [int][Math]::Floor($ValidityDays / 3)))
}

function New-Serial {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $bytes[0] = $bytes[0] -band 0x7F     # serial numbers must be positive
    return '0x' + (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

# Writes a renewed leaf certificate to every file of an entry and keeps each
# file's form: a single certificate stays single; a chain file gets the new leaf
# on top, followed by CHAIN or by whatever was below the leaf before
function Write-CertOutputs($Entry, [string]$LeafPem, [string]$ChainPem = '') {
    [void](Backup-Files (@(@($Entry.Outputs) | ForEach-Object { $_.Path }) + @($Entry.P12)))
    foreach ($o in @($Entry.Outputs)) {
        if ($o.Kind -eq 'fullchain') {
            $rest = $ChainPem
            if (-not $rest) {
                $old  = @(Get-PemCertBlocks ([IO.File]::ReadAllText($o.Path)))
                $rest = (@($old | Select-Object -Skip 1) | ForEach-Object { ConvertTo-PemCert $_ }) -join ''
            }
            Write-Text $o.Path ($LeafPem.TrimEnd() + "`n" + $rest)
        } else {
            Write-Text $o.Path ($LeafPem.TrimEnd() + "`n")
        }
    }
    $full = @($Entry.Outputs | Where-Object { $_.Kind -eq 'fullchain' }) + @($Entry.Outputs)
    foreach ($p in @($Entry.P12)) {
        if ($p) { New-P12 $full[0].Path $Entry.KeyOut $p $Entry.Name }
    }
}

function Get-PluginArgs($Entry) {
    $pluginArgs = @{}
    if ($Entry.WRPath)     { $pluginArgs.WRPath  = $Entry.WRPath }
    if ($Entry.CFTokenEnc) { $pluginArgs.CFToken = ConvertTo-SecureString $Entry.CFTokenEnc }
    return $pluginArgs
}

# A scanned Let's Encrypt certificate is renewed through its own Posh-ACME order,
# made from a request signed by the existing key: the key file stays the same
function Get-AcmeScannedCert($Entry) {
    Use-PoshAcme
    $order = $null
    try { $order = Get-PAOrder -Name $Entry.Order -ErrorAction SilentlyContinue } catch { }
    $port80 = $Entry.Plugin -eq 'WebSelfHost'
    if ($order) {
        if ($port80) { $cert = Invoke-WithPort80 { Submit-Renewal -Name $Entry.Order -Force -WarningAction SilentlyContinue } }
        else         { $cert = Submit-Renewal -Name $Entry.Order -Force -WarningAction SilentlyContinue }
    } else {
        $csr = Join-Path $script:HomeDir "$($Entry.Order).csr"
        $san = (@($Entry.Domains) | ForEach-Object { "DNS:$_" }) -join ','
        try {
            [void](Invoke-OpenSslQuiet @('req', '-new', '-key', $Entry.KeyOut, '-subj', "/CN=$(@($Entry.Domains)[0])",
                                         '-addext', "subjectAltName=$san", '-out', $csr))
            $params = @{ CSRPath = $csr; Name = $Entry.Order; AcceptTOS = $true; Plugin = $Entry.Plugin; Force = $true }
            $pluginArgs = Get-PluginArgs $Entry
            if ($pluginArgs.Count -gt 0) { $params.PluginArgs = $pluginArgs }
            if ($port80) { $cert = Invoke-WithPort80 { New-PACertificate @params } }
            else         { $cert = New-PACertificate @params }
        } finally {
            if (Test-Path -LiteralPath $csr) { [IO.File]::Delete($csr) }
        }
    }
    if (-not $cert) { $cert = Get-PACertificate -Name $Entry.Order }
    if (-not $cert) {
        throw (L 'Let''s Encrypt не выдал сертификат' 'Let''s Encrypt did not issue a certificate')
    }
    return $cert
}

# Renews an entry added by the folder scan: same files, same kind of certificate
function Renew-ScannedEntry($Entry) {
    if ($Entry.Type -eq 'acme') {
        $cert = Get-AcmeScannedCert $Entry
        Write-CertOutputs $Entry ([IO.File]::ReadAllText($cert.CertFile)) ([IO.File]::ReadAllText($cert.ChainFile))
        return
    }

    # self-signed and own-CA certificates are re-signed as they are: subject,
    # SAN and other extensions, key and validity length all stay the same
    $leaf = Join-Path $script:HomeDir 'renew-leaf.pem'
    $new  = Join-Path $script:HomeDir 'renew-new.pem'
    try {
        $blocks = @(Get-PemCertBlocks ([IO.File]::ReadAllText(@($Entry.Outputs)[0].Path)))
        Write-Text $leaf (ConvertTo-PemCert $blocks[0])
        $common = @('x509', '-in', $leaf, '-days', "$($Entry.Days)", '-set_serial', (New-Serial), '-out', $new)
        if ($Entry.Type -eq 'ca') {
            [void](Invoke-OpenSslQuiet ($common + @('-CA', $Entry.CaCert, '-CAkey', $Entry.CaKey)))
        } else {
            [void](Invoke-OpenSslQuiet ($common + @('-signkey', $Entry.KeyOut)))
        }
        Write-CertOutputs $Entry ([IO.File]::ReadAllText($new))
    } finally {
        foreach ($f in $leaf, $new) { if (Test-Path -LiteralPath $f) { [IO.File]::Delete($f) } }
    }
}

# Renews every entry that is due. Counts go to $script:RenewResult
function Invoke-RenewalCore([object[]]$List) {
    $renewed = 0
    $failed  = 0
    foreach ($item in $List) {
        $name = if ($item.Name) { $item.Name } else { $item.Domain }
        $script:BackupSet = $null       # every certificate gets its own backup set
        $script:P80Notes  = @()
        try {
            if (-not $item.Type) {
                # issued by the wizard itself: Posh-ACME decides when it is due
                # and returns nothing until then
                Use-PoshAcme
                $order = $null
                try { $order = Get-PAOrder -MainDomain $item.Domain -ErrorAction SilentlyContinue } catch { }
                if ($order -and @($order.Plugin) -contains 'WebSelfHost') {
                    $cert = Invoke-WithPort80 { Submit-Renewal -MainDomain $item.Domain -WarningAction SilentlyContinue }
                } else {
                    $cert = Submit-Renewal -MainDomain $item.Domain -WarningAction SilentlyContinue
                }
                if (-not $cert) {
                    Write-RenewLog ("${name}: " + (L 'продлевать ещё рано' 'not due for renewal yet'))
                    continue
                }
                Save-CertFiles $cert $item
                $where = $item.CertOut
            } else {
                $left = Get-DaysLeft @($item.Outputs)[0].Path
                if ($left -gt (Get-RenewThreshold $item.Days)) {
                    Write-RenewLog ("${name}: " + (L "продлевать ещё рано (осталось $left дн.)" "not due for renewal yet ($left days left)"))
                    continue
                }
                Renew-ScannedEntry $item
                $where = @($item.Outputs)[0].Path
            }
            $renewed++
            if ($script:P80Notes.Count -gt 0) { Write-RenewLog ("${name}: " + ($script:P80Notes -join '; ')) }
            Write-RenewLog ("${name}: " + (L 'продлён, файлы обновлены' 'renewed, files updated') + " - $where")
            if ($script:BackupSet) {
                Write-RenewLog ("${name}: " + (L 'старые файлы сохранены в' 'old files saved to') + " $($script:BackupSet)")
            }
        } catch {
            $failed++
            $reason = $_.Exception.Message
            if ($script:P80Notes.Count -gt 0) { $reason = ($script:P80Notes -join '; ') + '; ' + $reason }
            Write-RenewLog ("${name}: " + (L 'ошибка' 'error') + " - $reason")
            if (-not $script:RenewEcho) {
                $notes = @($script:P80Notes) + @($_.Exception.Message)
                Send-RenewFailed $item $name ($notes -join "`n")
            }
        }
    }

    # user's own script after a renewal, e.g. restarting the web server
    if ($renewed -gt 0 -and (Test-Path -LiteralPath $script:RenewHook)) {
        try {
            & $script:RenewHook | Out-Null
            Write-RenewLog ('after-renew.ps1: ' + (L 'выполнен' 'done'))
        } catch {
            $failed++
            Write-RenewLog ('after-renew.ps1: ' + (L 'ошибка' 'error') + " - $($_.Exception.Message)")
            if (-not $script:RenewEcho -and (Test-NotifyConfigured)) {
                Send-Notification (L 'ssl-wizard: after-renew.ps1 завершился с ошибкой' 'ssl-wizard: after-renew.ps1 failed') `
                                  "$env:COMPUTERNAME: $($script:RenewHook)`n$($_.Exception.Message)" | Out-Null
            }
        }
    }
    $script:RenewResult = @{ Renewed = $renewed; Failed = $failed }
}

# -Renew mode: renew everything that is due and refresh the files in the folders
function Invoke-Renewal {
    $list = @(Read-RenewList)
    if ($list.Count -eq 0) {
        Write-RenewLog (L 'сертификатов для продления нет' 'no certificates to renew')
        return
    }
    $script:OpenSsl = Find-OpenSsl
    if ($script:OpenSsl) { Set-OpenSslEnv }
    Invoke-RenewalCore $list
    if ($script:RenewResult.Failed -gt 0) { exit 1 }
}

# ==============================================================================
# Folder scan - finds certificates, shows when they expire and puts them on
# auto-renewal: the same files under the same names, the same kind of certificate
# ==============================================================================
# Base64 bodies of all certificates in PEM text, leaf first
function Get-PemCertBlocks([string]$Text) {
    $found = [regex]::Matches($Text, '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----', 'Singleline')
    return @($found | ForEach-Object { $_.Groups[1].Value -replace '\s', '' })
}

function ConvertTo-PemCert([string]$Base64) {
    $lines = for ($i = 0; $i -lt $Base64.Length; $i += 64) {
        $Base64.Substring($i, [Math]::Min(64, $Base64.Length - $i))
    }
    return "-----BEGIN CERTIFICATE-----`n" + ($lines -join "`n") + "`n-----END CERTIFICATE-----`n"
}

function New-X509([string]$Base64) {
    return New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String($Base64))
}

# Public key from openssl output, as one line - to pair certificates with keys
function Get-Spki([string]$Text) {
    $m = [regex]::Match($Text, '-----BEGIN PUBLIC KEY-----(.+?)-----END PUBLIC KEY-----', 'Singleline')
    if ($m.Success) { return ($m.Groups[1].Value -replace '\s', '') }
    return $null
}

function Get-KeyLabel($X) {
    switch ($X.PublicKey.Oid.Value) {
        '1.2.840.113549.1.1.1' {
            try { return "RSA $($X.PublicKey.Key.KeySize)" } catch { return 'RSA' }
        }
        '1.2.840.10045.2.1' {
            $curve = [BitConverter]::ToString($X.PublicKey.EncodedParameters.RawData) -replace '-', ''
            switch ($curve) {
                '06082A8648CE3D030107' { return 'ECDSA P-256' }
                '06052B81040022'       { return 'ECDSA P-384' }
                '06052B81040023'       { return 'ECDSA P-521' }
                default                { return 'ECDSA' }
            }
        }
        '1.3.101.112' { return 'Ed25519' }
        default       { return $X.PublicKey.Oid.FriendlyName }
    }
}

# Find-Certificates FOLDER [RECURSE] - every leaf certificate in the folder (and its
# subfolders), with its key, its kind and whether the wizard can renew it.
# The wizard's own backups are never picked up.
function Find-Certificates([string]$Root, [bool]$Recurse = $true) {
    $managed = @(Read-RenewList | ForEach-Object { Get-EntryPaths $_ })
    $backups = $script:BackupDir.TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse:$Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Length -lt 1MB -and @('.crt', '.cer', '.pem', '.key') -contains $_.Extension.ToLower() -and
                              -not $_.FullName.StartsWith($backups, [StringComparison]::OrdinalIgnoreCase) })

    $keys   = @{}   # public key -> private key file
    $parsed = @()
    foreach ($f in $files) {
        try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
        # a password-protected key cannot be used unattended, so it is not paired
        if ($text -match 'PRIVATE KEY-----' -and $text -notmatch 'ENCRYPTED') {
            $spki = Get-Spki (Invoke-OpenSslQuiet @('pkey', '-in', $f.FullName, '-pubout', '-passin', 'pass:') -NoThrow)
            if ($spki -and -not $keys.ContainsKey($spki)) { $keys[$spki] = $f.FullName }
        }
        $blocks = @(Get-PemCertBlocks $text)
        if ($blocks.Count -eq 0) { continue }
        try { $x = New-X509 $blocks[0] } catch { continue }
        $info = Invoke-OpenSslQuiet @('x509', '-in', $f.FullName, '-noout', '-pubkey', '-ext', 'subjectAltName') -NoThrow
        $bc = $x.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }
        $parsed += [pscustomobject]@{
            Path  = $f.FullName
            Count = $blocks.Count
            X     = $x
            Spki  = Get-Spki $info
            Dns   = @([regex]::Matches("$info", 'DNS:([^,\s]+)') | ForEach-Object { $_.Groups[1].Value })
            IsCa  = [bool]($bc -and $bc.CertificateAuthority)
        }
    }

    # CA certificates by subject, to find who signed a leaf
    $cas = @{}
    foreach ($p in @($parsed | Where-Object { $_.IsCa })) {
        $subject = [Convert]::ToBase64String($p.X.SubjectName.RawData)
        if (-not $cas.ContainsKey($subject) -or $p.Count -eq 1) { $cas[$subject] = $p }
    }

    # Which certificates are authorities rather than server certificates: an
    # intermediate (CA, not self-signed) or a root that signed something here.
    # A self-signed CA:TRUE certificate that signed nothing is a server
    # certificate - "openssl req -x509" marks them CA:TRUE by default.
    $signers = @{}
    foreach ($p in $parsed) {
        $issuer = [Convert]::ToBase64String($p.X.IssuerName.RawData)
        if ($issuer -ne [Convert]::ToBase64String($p.X.SubjectName.RawData)) { $signers[$issuer] = $true }
    }
    $leaves = @($parsed | Where-Object {
        $subject = [Convert]::ToBase64String($_.X.SubjectName.RawData)
        $selfSigned = $subject -eq [Convert]::ToBase64String($_.X.IssuerName.RawData)
        -not ($_.IsCa -and (-not $selfSigned -or $signers.ContainsKey($subject)))
    })

    $result = @()
    # the same certificate may sit in several files (cert.pem, fullchain.pem...)
    foreach ($group in @($leaves | Group-Object { $_.X.Thumbprint })) {
        $first = $group.Group[0]
        $x     = $first.X
        $name  = $x.GetNameInfo('SimpleName', $false)
        if (-not $name -and $first.Dns.Count -gt 0) { $name = $first.Dns[0] }
        $c = [pscustomobject]@{
            Name     = $name
            Type     = 'other'
            Status   = 'ok'
            Reason   = ''
            KeyLabel = Get-KeyLabel $x
            Issuer   = $x.GetNameInfo('SimpleName', $true)
            CaName   = ''
            NotAfter = $x.NotAfter
            DaysLeft = [int][Math]::Floor(($x.NotAfter - (Get-Date)).TotalDays)
            Days     = [int][Math]::Round(($x.NotAfter - $x.NotBefore).TotalDays)
            KeyOut   = if ($first.Spki) { $keys[$first.Spki] } else { $null }
            Outputs  = @($group.Group | Sort-Object Path | ForEach-Object {
                           [pscustomobject]@{ Path = $_.Path; Kind = $(if ($_.Count -gt 1) { 'fullchain' } else { 'leaf' }) } })
            P12      = @()
            Domains  = $first.Dns
            CaCert   = ''
            CaKey    = ''
        }

        $subject = [Convert]::ToBase64String($x.SubjectName.RawData)
        $issuer  = [Convert]::ToBase64String($x.IssuerName.RawData)
        if ($x.Issuer -match "O=Let's Encrypt") {
            $c.Type = 'acme'
        } elseif ($subject -eq $issuer) {
            $c.Type = 'self'
        } elseif ($cas.ContainsKey($issuer)) {
            $ca = $cas[$issuer]
            $c.Type   = 'ca'
            $c.CaName = $ca.X.GetNameInfo('SimpleName', $false)
            $c.CaCert = $ca.Path
            $c.CaKey  = if ($ca.Spki) { $keys[$ca.Spki] } else { $null }
        }

        if (@($c.Outputs | Where-Object { $managed -contains $_.Path }).Count -gt 0) {
            $c.Status = 'managed'
        } elseif ($c.Type -eq 'other') {
            $c.Status = 'skip'
            $c.Reason = L "выдан '$($c.Issuer)' - такой центр мастер продлевать не умеет" `
                          "issued by '$($c.Issuer)' - the wizard cannot renew certificates from it"
        } elseif (-not $c.KeyOut) {
            $c.Status = 'skip'
            $c.Reason = L 'закрытый ключ не найден в папке или защищён паролем' `
                          'private key not found in the folder, or it has a password'
        } elseif ($c.Type -eq 'ca' -and -not $c.CaKey) {
            $c.Status = 'skip'
            $c.Reason = L 'ключ центра сертификации не найден в папке или защищён паролем' `
                          'the CA key is not in the folder, or it has a password'
        } elseif ($c.Type -eq 'acme' -and $c.Domains.Count -eq 0) {
            $c.Status = 'skip'
            $c.Reason = L 'в сертификате нет доменов' 'the certificate lists no domains'
        }

        # a .p12/.pfx next to the certificate, with the same name and no password,
        # is rebuilt on renewal too
        foreach ($o in $c.Outputs) {
            $base = Join-Path (Split-Path $o.Path -Parent) ([IO.Path]::GetFileNameWithoutExtension($o.Path))
            foreach ($ext in '.p12', '.pfx') {
                $p = $base + $ext
                if ((Test-Path -LiteralPath $p) -and $c.P12 -notcontains $p -and
                    $null -ne (Invoke-OpenSslQuiet @('pkcs12', '-in', $p, '-passin', 'pass:', '-noout') -NoThrow)) {
                    $c.P12 += $p
                }
            }
        }
        $result += $c
    }
    return @($result | Sort-Object DaysLeft)
}

function Get-ScanTypeLabel($C) {
    switch ($C.Type) {
        'acme'  { $kind = "Let's Encrypt" }
        'self'  { $kind = L 'самоподписанный' 'self-signed' }
        'ca'    { $kind = L "подписан CA '$($C.CaName)'" "signed by CA '$($C.CaName)'" }
        default { $kind = L "выдан '$($C.Issuer)'" "issued by '$($C.Issuer)'" }
    }
    return "$($C.KeyLabel), $kind"
}

function Show-ScanResults([object[]]$Found, [string]$Root) {
    $i = 0
    foreach ($c in $Found) {
        $i++
        $date = $c.NotAfter.ToString('yyyy-MM-dd')
        if ($c.DaysLeft -lt 0) {
            $when = L "истёк $date" "expired on $date"; $color = 'Red'
        } else {
            $when = L "действует до $date, осталось $($c.DaysLeft) дн." "valid until $date, days left: $($c.DaysLeft)"
            $color = if ($c.DaysLeft -le 30) { 'Yellow' } else { 'Green' }
        }
        $files = (@($c.Outputs) + @($c.P12 | ForEach-Object { [pscustomobject]@{ Path = $_ } }) | ForEach-Object {
                      $_.Path.Substring($Root.TrimEnd('\').Length).TrimStart('\') }) -join ', '

        Write-Host ('  {0,3})  ' -f $i) -ForegroundColor Blue -NoNewline
        Write-Host (([string]$c.Name).PadRight(30) + ' ') -NoNewline
        Write-Host (Get-ScanTypeLabel $c) -ForegroundColor DarkGray
        Write-Host "        $when" -ForegroundColor $color
        Write-Host "        $files" -ForegroundColor DarkGray
        switch ($c.Status) {
            'ok'      { Write-Host ('        + ' + (L 'будет продлеваться' 'will be renewed')) -ForegroundColor Green }
            'managed' { Write-Host ('        + ' + (L 'уже в автопродлении' 'already on auto-renewal')) -ForegroundColor DarkGray }
            default   { Write-Host "        ! $($c.Reason)" -ForegroundColor Yellow }
        }
        Blank
    }
}

# How Let's Encrypt should check the domain of a scanned certificate.
# Sets Plugin (+ WRPath / CFTokenEnc) or Status = 'skip'; 0 - Nav = back
function Read-AcmeMethod($C) {
    $wildcard = @($C.Domains | Where-Object { $_ -like '*`**' }).Count -gt 0
    while ($true) {
        Screen (L "Проверка домена: $($C.Name)" "Domain check: $($C.Name)")
        Row (L 'Домены' 'Domains') ($C.Domains -join ', ')
        Blank
        Hint (L "При каждом продлении Let's Encrypt проверяет, что домен ваш. Как это делать?" `
                "On every renewal Let's Encrypt checks that the domain is yours. How?")
        Blank
        $choices = @()
        if (-not $wildcard) {
            $choices += 'standalone'
            Opt $choices.Count (L 'Автономно' 'Standalone') (L 'порт 80 свободен; нужны права администратора' 'port 80 is free; needs administrator rights')
            $choices += 'webroot'
            Opt $choices.Count (L 'Через папку сайта' 'Via site folder') (L 'сайт работает, файлы отдаются из папки' 'the site runs and serves files from a folder')
        }
        $choices += 'cloudflare'
        Opt $choices.Count 'Cloudflare' (L 'DNS-запись по API-токену' 'DNS record via API token')
        $choices += 'skip'
        Opt $choices.Count (L 'Не продлевать' 'Do not renew') (L 'пропустить этот сертификат' 'skip this certificate')
        if ($wildcard) {
            Blank
            Hint (L 'Для wildcard (*.домен) подходит только проверка через DNS.' 'A wildcard (*.domain) can only be checked via DNS.')
        }
        Blank; Hr; Blank

        $n = Read-Pick $choices.Count
        if ($script:Nav -eq 'back') { return }
        switch ($choices[$n - 1]) {
            'skip' {
                $C.Status = 'skip'
                return
            }
            'standalone' {
                if (-not (Test-Admin)) {
                    Blank
                    Err (L 'Нужны права администратора: запустите мастер от имени администратора.' `
                           'Administrator rights needed: run the wizard as administrator.')
                    Blank
                    Pause-Wizard
                    continue
                }
                $C | Add-Member -Force Plugin 'WebSelfHost'
                return
            }
            'webroot' {
                Blank
                $script:S.ScanWebroot = ''
                Read-Answer 'ScanWebroot' (L 'Папка сайта' 'Site folder') 'C:\inetpub\wwwroot' $script:CheckDir
                if ($script:Nav -eq 'back') { $script:Nav = ''; continue }
                $C | Add-Member -Force Plugin 'WebRoot'
                $C | Add-Member -Force WRPath $script:S.ScanWebroot
                return
            }
            'cloudflare' {
                Blank
                Hint (L 'Токен: Cloudflare -> My Profile -> API Tokens -> шаблон Edit zone DNS.' `
                        'Token: Cloudflare -> My Profile -> API Tokens -> Edit zone DNS template.')
                $script:S.ScanToken = ''
                Read-Answer 'ScanToken' (L 'API-токен' 'API token')
                if ($script:Nav -eq 'back') { $script:Nav = ''; continue }
                # stored encrypted for the current user - the renewal task runs as this user
                $secure = ConvertTo-SecureString $script:S.ScanToken -AsPlainText -Force
                $C | Add-Member -Force Plugin 'Cloudflare'
                $C | Add-Member -Force CFTokenEnc (ConvertFrom-SecureString $secure)
                $script:S.ScanToken = ''
                return
            }
        }
    }
}

$script:CheckDir = {
    param($v)
    if (-not (Test-Path -LiteralPath $v.Trim('"') -PathType Container)) { return (L 'Такой папки нет.' 'No such folder.') }
    return $null
}

# Menu item "Scan a folder": folder -> results -> domain checks -> add -> renew now
function Step-Scan {
    $savedStep = $script:StepI
    $script:StepI = 0
    try {
        while ($true) {
            Screen (L 'Сканирование папки' 'Scan a folder')
            Hint (L 'Мастер найдёт сертификаты в папке и вложенных папках, покажет их срок' `
                    'The wizard finds certificates in the folder and its subfolders, shows their expiry')
            Hint (L 'и поставит на автопродление: те же файлы с теми же именами, такой же сертификат.' `
                    'and puts them on auto-renewal: the same files under the same names, the same certificate.')
            Hint (L 'Enter - текущая папка, 0 - назад.' 'Enter - current folder, 0 - back.')
            Blank
            Read-Answer 'ScanDir' (L 'Путь к папке' 'Folder path') (Get-Location).ProviderPath $script:CheckDir
            if ($script:Nav -eq 'back') { $script:Nav = ''; return }
            $root = (Resolve-Path -LiteralPath $script:S.ScanDir.Trim('"')).ProviderPath

            Blank
            Opt 1 (L 'С подпапками' 'With subfolders') (L 'эта папка и все вложенные' 'this folder and everything inside it')
            Opt 2 (L 'Только эта папка' 'This folder only') (L 'без вложенных папок' 'no subfolders')
            Blank
            $depth = Read-Pick 2
            if ($script:Nav -eq 'back') { $script:Nav = ''; continue }

            Screen (L 'Найденные сертификаты' 'Certificates found')
            Info (L "Папка: $root" "Folder: $root")
            if ($depth -eq 1) { Info (L 'Вместе с подпапками' 'Including subfolders') }
            Blank
            $found = @(Find-Certificates $root ($depth -eq 1))
            if ($found.Count -eq 0) {
                Warn (L 'Сертификатов не найдено (ищутся файлы .crt, .cer, .pem).' 'No certificates found (looking for .crt, .cer, .pem files).')
                Blank
                Pause-Wizard
                continue
            }
            Show-ScanResults $found $root
            $ready = @($found | Where-Object { $_.Status -eq 'ok' })
            Hr; Blank
            if ($ready.Count -eq 0) {
                Hint (L 'Добавлять в автопродление нечего.' 'Nothing to add to auto-renewal.')
                Blank
                Pause-Wizard (L 'Нажмите Enter, чтобы вернуться...' 'Press Enter to go back...')
                continue
            }
            Opt 1 (L 'Добавить в автопродление' 'Add to auto-renewal') (L "сертификатов: $($ready.Count)" "certificates: $($ready.Count)")
            Blank
            [void](Read-Pick 1)
            if ($script:Nav -eq 'back') { $script:Nav = ''; continue }

            # Let's Encrypt needs to know how to check each domain; 0 goes to the previous one
            $acme = @($ready | Where-Object { $_.Type -eq 'acme' })
            $j = 0
            while ($j -lt $acme.Count) {
                $script:Nav = ''
                Read-AcmeMethod $acme[$j]
                if ($script:Nav -eq 'back') {
                    if ($j -eq 0) { break }
                    $j--
                } else {
                    $j++
                }
            }
            if ($script:Nav -eq 'back') { $script:Nav = ''; continue }

            $ready = @($ready | Where-Object { $_.Status -eq 'ok' })
            Screen (L 'Автопродление' 'Auto-renewal')
            if ($ready.Count -eq 0) {
                Hint (L 'Все сертификаты пропущены.' 'All certificates were skipped.')
                Blank
                Pause-Wizard
                return
            }
            $entries = @($ready | ForEach-Object { New-ScanEntry $_ })
            try {
                Add-RenewEntries $entries
            } catch {
                Err (L "Не удалось включить автопродление: $($_.Exception.Message)" "Could not enable auto-renewal: $($_.Exception.Message)")
                Blank
                Pause-Wizard
                return
            }
            Ok (L "Добавлено в автопродление: $($entries.Count)" "Added to auto-renewal: $($entries.Count)")
            Ok (L 'Задача планировщика проверяет срок каждый день и обновляет те же файлы.' `
                  'A scheduled task checks the expiry every day and updates the same files.')
            Blank

            $due = @($entries | Where-Object { (Get-DaysLeft @($_.Outputs)[0].Path) -le (Get-RenewThreshold $_.Days) })
            if ($due.Count -gt 0) {
                Warn (L "Срок истёк или скоро истечёт: $($due.Count). Продлить сейчас?" `
                        "Expired or expiring soon: $($due.Count). Renew now?")
                Opt 1 (L 'Да' 'Yes') (L 'продлить сейчас' 'renew now')
                Opt 2 (L 'Нет' 'No')  (L 'продлит задача планировщика' 'the scheduled task will do it')
                Blank
                $c = Read-Pick 2
                if ($script:Nav -ne 'back' -and $c -eq 1) {
                    Blank
                    $script:RenewEcho = $true
                    try { Invoke-RenewalCore $due } finally { $script:RenewEcho = $false }
                    Blank
                    if ($script:RenewResult.Failed -eq 0) {
                        Ok (L "Продлено: $($script:RenewResult.Renewed)" "Renewed: $($script:RenewResult.Renewed)")
                    } else {
                        Err (L "Ошибок: $($script:RenewResult.Failed). Подробности - выше и в $($script:RenewLog)" `
                               "Errors: $($script:RenewResult.Failed). Details above and in $($script:RenewLog)")
                    }
                }
                $script:Nav = ''
                Blank
            }
            Pause-Wizard (L 'Нажмите Enter, чтобы вернуться в меню...' 'Press Enter to return to the menu...')
            return
        }
    } finally {
        $script:StepI = $savedStep
    }
}

# What the renewal task needs to know about a scanned certificate
function New-ScanEntry($C) {
    $entry = [ordered]@{
        Type    = $C.Type
        Name    = $C.Name
        Days    = $C.Days
        KeyOut  = $C.KeyOut
        Outputs = @($C.Outputs)
        P12     = @($C.P12)
    }
    if ($C.Type -eq 'ca') {
        $entry.CaCert = $C.CaCert
        $entry.CaKey  = $C.CaKey
    }
    if ($C.Type -eq 'acme') {
        $entry.Domains = @($C.Domains)
        $entry.Order   = 'sslwiz_' + (@($C.Domains)[0] -replace '\*', '!')
        $entry.Plugin  = $C.Plugin
        if ($C.PSObject.Properties['WRPath'])     { $entry.WRPath     = $C.WRPath }
        if ($C.PSObject.Properties['CFTokenEnc']) { $entry.CFTokenEnc = $C.CFTokenEnc }
    }
    return [pscustomobject]$entry
}

function Get-LeDomains {
    $d = @($script:S.Domain)
    if ($script:S.Www -eq 'yes') { $d += "www.$($script:S.Domain)" }
    return $d
}

function Run-LeStandalone {
    $d = $script:S.Domain
    Info (L "Получаю сертификат для $d (порт 80 должен быть свободен)..." `
            "Requesting a certificate for $d (port 80 must be free)...")
    Invoke-LetsEncrypt 'WebSelfHost' @{} (Get-LeDomains)
}

function Run-LeWebroot {
    $s = $script:S
    if (-not (Test-Path -LiteralPath $s.Webroot)) {
        throw (L "папка сайта не найдена: $($s.Webroot)" "site folder not found: $($s.Webroot)")
    }
    Info (L "Получаю сертификат для $($s.Domain) через папку $($s.Webroot)..." `
            "Requesting a certificate for $($s.Domain) via folder $($s.Webroot)...")
    Invoke-LetsEncrypt 'WebRoot' @{ WRPath = $s.Webroot } (Get-LeDomains)
}

function Run-LeWildcardManual {
    $s = $script:S
    Info (L "Запрашиваю проверочные записи для $($s.Domain)..." "Requesting verification records for $($s.Domain)...")
    Warn (L 'Сейчас появятся TXT-записи. Добавьте их в DNS домена, подождите' `
            "TXT records will appear now. Add them to the domain's DNS, wait")
    Warn (L '2-5 минут и нажмите Enter - мастер продолжит сам.' `
            '2-5 minutes and press Enter - the wizard continues by itself.')
    Blank
    Invoke-LetsEncrypt 'Manual' @{} @($s.Domain, "*.$($s.Domain)")
}

function Run-LeWildcardCf {
    $s = $script:S
    Info (L "Получаю wildcard-сертификат для $($s.Domain) через Cloudflare..." `
            "Requesting a wildcard certificate for $($s.Domain) via Cloudflare...")
    $token = ConvertTo-SecureString $s.CfToken -AsPlainText -Force
    Invoke-LetsEncrypt 'Cloudflare' @{ CFToken = $token } @($s.Domain, "*.$($s.Domain)")
}

# ==============================================================================
# Run: simple self-signed - no passphrase (genrsa -> CSR -> x509)
# ==============================================================================
function Run-SsSimple {
    $s = $script:S
    $key = Join-Path $s.OutDir 'privkey.pem'
    $csr = Join-Path $s.OutDir 'cert.csr'
    $crt = Join-Path $s.OutDir 'fullchain.pem'

    Info (L "1/3 - создаю ключ RSA $($s.RsaBits) бит..." "1/3 - generating a $($s.RsaBits)-bit RSA key...")
    Invoke-OpenSsl @('genrsa', '-out', $key, $s.RsaBits)
    Protect-File $key
    OkF (L 'ключ' 'key') $key
    Blank

    Info (L '2/3 - создаю запрос на сертификат (CSR)...' '2/3 - creating the certificate signing request (CSR)...')
    Invoke-OpenSsl @('req', '-new', '-key', $key, '-out', $csr, '-subj', "/CN=$($s.Domain)")
    OkF (L 'запрос' 'request') $csr
    Blank

    Info (L "3/3 - подписываю сертификат на $($s.Days) дн...." "3/3 - signing the certificate for $($s.Days) days...")
    Invoke-OpenSsl @('x509', '-req', '-days', $s.Days, '-in', $csr, '-signkey', $key, '-out', $crt)
    OkF (L 'сертификат' 'certificate') $crt
    Write-UsageHint $crt $key
}

# ==============================================================================
# Run: self-signed methods
# ==============================================================================
# Run-Ss ALGORITHM - key + self-signed certificate with SAN
function Run-Ss([string]$Algo) {
    $s = $script:S
    Set-OutNames
    $cnf = Write-OpenSslCnf
    Info (L "Создаю ключ и сертификат на $($s.Days) дн...." "Creating the key and a certificate for $($s.Days) days...")
    New-Key $Algo $script:KeyOut
    Invoke-OpenSsl @('req', '-x509', '-new', '-key', $script:KeyOut, '-out', $script:CertOut,
                     '-days', $s.Days, '-extensions', 'v3_req', '-config', $cnf)
    OkF (L 'ключ' 'key') $script:KeyOut
    OkF (L 'сертификат' 'certificate') $script:CertOut
    Convert-ToP12   $script:CertOut $script:KeyOut
    Write-UsageHint $script:CertOut $script:KeyOut
}

function Run-SsCa {
    $s = $script:S
    Set-OutNames
    $cnf   = Write-OpenSslCnf
    $caKey = Join-Path $s.OutDir 'ca.key'
    $caCrt = Join-Path $s.OutDir 'ca.crt'

    if ((Test-Path -LiteralPath $caKey) -and (Test-Path -LiteralPath $caCrt)) {
        Info (L '1/3 - в папке уже есть центр сертификации (ca.key, ca.crt) - использую его.' `
                '1/3 - the folder already has a CA (ca.key, ca.crt) - reusing it.')
    } else {
        Info (L '1/3 - создаю центр сертификации (CA)...' '1/3 - creating the certificate authority (CA)...')
        if ($s.Passphrase -eq 'yes') {
            Warn (L 'Сейчас openssl попросит придумать пароль для ключа CA - запомните его.' `
                    'openssl will now ask you to set a password for the CA key - remember it.')
            Invoke-OpenSsl @('genrsa', '-aes256', '-out', $caKey, '4096')
        } else {
            Invoke-OpenSsl @('genrsa', '-out', $caKey, '4096')
        }
        Protect-File $caKey
        $caCnf = Join-Path $s.OutDir 'ca.cnf'
        Write-Text $caCnf @"
[req]
prompt             = no
utf8               = yes
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
C  = $($s.Country)
ST = $($s.State)
L  = $($s.City)
O  = $($s.Org) CA
CN = $($s.Org) Root CA

[v3_ca]
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
"@
        try {
            Invoke-OpenSsl @('req', '-x509', '-new', '-key', $caKey, '-sha256', '-days', '3650', '-out', $caCrt, '-config', $caCnf)
        } finally {
            [IO.File]::Delete($caCnf)
        }
    }
    OkF 'CA' $caCrt
    Blank

    Info (L '2/3 - создаю ключ сервера и запрос на сертификат...' '2/3 - creating the server key and signing request...')
    $csr = Join-Path $s.OutDir "$($s.Domain).csr"
    Invoke-OpenSsl @('genrsa', '-out', $script:KeyOut, '4096')
    Protect-File $script:KeyOut
    Invoke-OpenSsl @('req', '-new', '-key', $script:KeyOut, '-out', $csr, '-config', $cnf)
    OkF (L 'запрос' 'request') $csr
    Blank

    Info (L '3/3 - подписываю сертификат своим CA...' '3/3 - signing the certificate with your CA...')
    $signed = Join-Path $s.OutDir "$($s.Domain).crt"
    Invoke-OpenSsl @('x509', '-req', '-in', $csr, '-CA', $caCrt, '-CAkey', $caKey, '-CAcreateserial',
                     '-out', $signed, '-days', $s.Days, '-sha256', '-extensions', 'v3_req', '-extfile', $cnf)
    if ($s.Format -eq 'bundle') {
        # fullchain = server certificate + CA certificate
        $chain = [IO.File]::ReadAllText($signed) + [IO.File]::ReadAllText($caCrt)
        Write-Text $script:CertOut $chain
        [IO.File]::Delete($signed)
    }
    OkF (L 'ключ' 'key') $script:KeyOut
    OkF (L 'сертификат' 'certificate') $script:CertOut
    Convert-ToP12   $script:CertOut $script:KeyOut
    Write-UsageHint $script:CertOut $script:KeyOut

    Blank
    Warn (L 'Чтобы не было предупреждений, установите ca.crt на свои компьютеры.' `
            'To get rid of browser warnings, install ca.crt on your computers.')
    Info (L 'Windows (PowerShell от имени администратора):' 'Windows (PowerShell as administrator):')
    Info "  Import-Certificate -FilePath `"$caCrt`" -CertStoreLocation Cert:\LocalMachine\Root"
    Info (L 'Linux и macOS - команды в README.' 'Linux and macOS - see the commands in README.')
}

# ==============================================================================
# Run: key generator
# ==============================================================================
function Run-Keygen {
    $s = $script:S
    switch ($s.KeygenAlgo) {
        'rsa'     { $name = "key_rsa$($s.RsaBits).pem" }
        'ecdsa'   { $name = "key_ecdsa_$($s.EcCurve).pem" }
        'ed25519' { $name = 'key_ed25519.pem' }
        'rand'    { $name = "rand_$($s.RandBytes)bytes.$($s.RandFormat)" }
    }
    $outFile = Join-Path $s.OutDir $name

    if ($s.KeygenAlgo -eq 'rand') {
        $value = (& $script:OpenSsl rand "-$($s.RandFormat)" $s.RandBytes) -join ''
        if ($LASTEXITCODE -ne 0) {
            throw (L "openssl завершился с ошибкой (код $LASTEXITCODE)" "openssl failed (exit code $LASTEXITCODE)")
        }
        Write-Text $outFile "$value`n"
        Protect-File $outFile
        Write-Host "  $value" -ForegroundColor Green
        Blank
        Ok (L "Сохранено: $outFile" "Saved: $outFile")
        return
    }

    Info (L 'Создаю ключ...' 'Generating the key...')
    New-Key $s.KeygenAlgo $outFile
    Ok (L "Закрытый ключ: $outFile" "Private key: $outFile")
    Blank
    Info (L 'Открытый ключ:' 'Public key:')
    Invoke-OpenSsl @('pkey', '-in', $outFile, '-pubout')
}

# ==============================================================================
# Execute - runs the chosen method. A failure does not kill the wizard.
# ==============================================================================
function Invoke-Selected {
    $s = $script:S
    New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null

    $set = Backup-Files (Get-WizardTargets)
    if ($set) {
        Info (L "Файлы, которые будут перезаписаны, сохранены в: $set" "Files about to be overwritten were saved to: $set")
        Blank
    }

    switch ($s.Method) {
        'le_standalone'      { Run-LeStandalone }
        'le_webroot'         { Run-LeWebroot }
        'le_wildcard_manual' { Run-LeWildcardManual }
        'le_wildcard_cf'     { Run-LeWildcardCf }
        'ss_simple'          { Run-SsSimple }
        'ss_rsa'             { Run-Ss 'rsa' }
        'ss_ecdsa'           { Run-Ss 'ecdsa' }
        'ss_ed25519'         { Run-Ss 'ed25519' }
        'ss_ca'              { Run-SsCa }
        'keygen'             { Run-Keygen }
    }
}

function Invoke-Execute {
    Banner
    Write-Host ('  ' + (L 'Выполняю...' 'Working...')) -ForegroundColor White
    Hr; Blank

    # the result goes to $script:RunOk rather than a return value: otherwise
    # openssl output would end up in the return value instead of on screen
    $script:RunOk = $true
    $script:BackupSet = $null       # every certificate gets its own backup set
    try {
        Invoke-Selected
    } catch {
        $script:RunOk = $false
        Blank
        Err ((L 'Ошибка' 'Error') + ": $($_.Exception.Message)")
    }

    Blank; Hr
    if ($script:RunOk) {
        Ok (L "Готово.  Файлы в папке: $($script:S.OutDir)" "Done.  Files are in: $($script:S.OutDir)")
    } else {
        Err (L 'Не получилось. Причина - в сообщениях выше.' 'It did not work. The reason is in the messages above.')
    }
    Blank
}

# ==============================================================================
# Main - walk through Flow; "back" decreases the step number by one
# ==============================================================================
function Main {
    Check-Deps

    $i = 0
    while ($true) {
        Build-Flow
        $script:StepI = $i + 1
        $script:StepN = $script:Flow.Count
        $script:Nav   = ''
        & $script:Flow[$i]

        if ($script:Nav -eq 'back') {
            if ($i -eq 0) {
                Blank; Info (L 'Выход.' 'Bye.')
                return
            }
            $i--
            continue
        }

        $i++
        Build-Flow
        if ($i -lt $script:Flow.Count) { continue }

        Invoke-Execute
        $success = $script:RunOk

        if ($success) {
            Opt 1 (L 'Создать ещё один' 'Create another') (L 'вернуться к выбору способа' 'back to the method choice')
        } else {
            Opt 1 (L 'Исправить данные' 'Fix the details') (L 'вернуться к проверке данных' 'back to the review screen')
            Opt 2 (L 'Начать заново' 'Start over')         (L 'вернуться к выбору способа' 'back to the method choice')
        }
        Blank
        $script:Nav = ''
        $max = if ($success) { 1 } else { 2 }
        $c = Read-Pick $max -Exit
        if ($script:Nav -eq 'back') { return }
        if (-not $success -and $c -eq 1) { $i = $script:Flow.Count - 1 } else { $i = 0 }
    }
}

Load-Lang $Lang (-not $Renew)
Load-Settings
if ($Renew) { Invoke-Renewal } else { Main }
