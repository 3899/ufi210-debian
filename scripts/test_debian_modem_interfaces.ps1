[CmdletBinding()]
param(
    [string]$AdbSerial = "192.168.68.1:5555",
    [ValidateRange(5, 120)]
    [int]$CommandTimeoutSeconds = 30,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adbCommand) { $Adb = $adbCommand.Source }
}

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Invoke-Native {
    param([string]$Executable, [string[]]$CommandArgs, [switch]$AllowFailure)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Executable @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$([IO.Path]::GetFileName($Executable)) 失败（$exitCode）：`r`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("modem-interfaces-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$deviceState = Invoke-Native $Adb @("-s", $AdbSerial, "get-state")
if ($deviceState.Text.Trim() -ne "device") { throw "TCP ADB 不可用：$AdbSerial" }

$probeCommand = @'
set -eu
test "$(cat /sys/devices/soc0/soc_id)" = 245
for command_name in busctl mmcli qmicli timeout; do
    command -v "$command_name" >/dev/null
done
for port in /dev/wwan0at0 /dev/wwan0at1 /dev/wwan0qmi0; do
    test -c "$port"
done

echo '=== SERVICES ==='
systemctl is-active dbus ModemManager zu02-mpss

echo '=== MODEM ==='
mmcli -L
modem_path=$(mmcli -L | sed -n \
    's#^[[:space:]]*\(/org/freedesktop/ModemManager1/Modem/[0-9][0-9]*\).*#\1#p' \
    | head -n 1)
test -n "$modem_path"

echo '=== MESSAGING ==='
mmcli -m any --messaging-status
busctl introspect org.freedesktop.ModemManager1 "$modem_path" \
    | grep '^org.freedesktop.ModemManager1.Modem.Messaging[[:space:]]'

echo '=== QMI DMS ==='
timeout __TIMEOUT__ qmicli -d /dev/wwan0qmi0 --device-open-proxy \
    --dms-get-operating-mode

echo '=== QMI NAS ==='
timeout __TIMEOUT__ qmicli -d /dev/wwan0qmi0 --device-open-proxy \
    --nas-get-signal-strength

echo '=== QMI WMS ==='
timeout __TIMEOUT__ qmicli -d /dev/wwan0qmi0 --device-open-proxy \
    --wms-get-routes

echo '=== PORTS ==='
stat -c '%n type=%F mode=%a major_minor=%t:%T' \
    /dev/wwan0at0 /dev/wwan0at1 /dev/wwan0qmi0

echo '=== FAILED COUNT ==='
systemctl --failed --no-legend --plain | wc -l
'@
$probeCommand = $probeCommand.Replace("__TIMEOUT__", "$CommandTimeoutSeconds")
$probe = Invoke-Native $Adb @("-s", $AdbSerial, "shell", $probeCommand) -AllowFailure
Write-Utf8File (Join-Path $OutputDir "modem-interfaces.txt") ($probe.Text + "`r`n")

if ($probe.ExitCode -ne 0) {
    throw "蜂窝接口只读探针失败；查看 $OutputDir\modem-interfaces.txt"
}
$checks = @(
    '(?m)^active\s*$'
    '/org/freedesktop/ModemManager1/Modem/[0-9]+'
    '(?m)^\s*Messaging \| supported storages:.*\bsm\b.*\bme\b'
    'org\.freedesktop\.ModemManager1\.Modem\.Messaging'
    "Mode: 'online'"
    'Successfully got signal strength'
    'Got [1-9][0-9]* SMS routes:'
    '(?m)^/dev/wwan0at0 type=character special file '
    '(?m)^/dev/wwan0at1 type=character special file '
    '(?m)^/dev/wwan0qmi0 type=character special file '
    '(?ms)=== FAILED COUNT ===\r?\n0\s*$'
)
foreach ($pattern in $checks) {
    if ($probe.Text -notmatch $pattern) {
        throw "蜂窝接口输出缺少预期证据：$pattern；查看 $OutputDir\modem-interfaces.txt"
    }
}

$summary = @(
    "Debian 蜂窝接口只读验收通过"
    "management=USB RNDIS + TCP ADB only"
    "dbus=active"
    "modemmanager=detected"
    "at_ports=wwan0at0,wwan0at1"
    "qmi_port=wwan0qmi0"
    "qmi_dms=online"
    "qmi_nas=read-success"
    "qmi_wms_routes=read-success"
    "messaging_dbus=available"
    "sms_storage=sm,me"
    "sms_send_receive=not-tested"
    "modem_changes=none"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
