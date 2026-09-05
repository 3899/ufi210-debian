[CmdletBinding()]
param(
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 180,
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $Adb = $command.Source }
}
if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    throw "缺少工具：adb.exe"
}

function Invoke-Adb {
    param([string[]]$CommandArgs, [switch]$AllowFailure)

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Adb @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "adb 失败（$exitCode）：`r`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Wait-DebianAdb {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $devices = Invoke-Adb @("devices", "-l") -AllowFailure
        if ($devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") {
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Debian TCP ADB 未在 $TimeoutSeconds 秒内出现：$AdbSerial"
}

function Save-Probe {
    param([string]$Name, [string]$Command)

    $result = Invoke-Adb @("-s", $AdbSerial, "shell", $Command) -AllowFailure
    $content = @(
        "exit_code=$($result.ExitCode)"
        $result.Text
    ) -join "`r`n"
    Write-Utf8File (Join-Path $OutputDir $Name) ($content + "`r`n")
}

Wait-DebianAdb
$identity = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    'test "$(hostname)" = ufi210 && test "$(cat /sys/devices/soc0/soc_id)" = 245 && test "$(findmnt -nro SOURCE /)" = /dev/mmcblk0p21 && echo UFI210_DEBIAN_OK'
)
if ($identity.Text -notmatch '(?m)^UFI210_DEBIAN_OK\r?$') {
    throw "ADB 设备不是目标 UFI210 Debian：`r`n$($identity.Text)"
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test"
}
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) (
    "usb-failure-postmortem-" + (Get-Date -Format "yyyyMMdd-HHmmss")
)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Adb @("-s", $AdbSerial, "shell", "journalctl --sync") -AllowFailure | Out-Null

Save-Probe "boots.txt" 'journalctl --list-boots --no-pager'
Save-Probe "current-state.txt" @'
printf 'boot_id='; cat /proc/sys/kernel/random/boot_id
printf 'root='; findmnt -nro SOURCE /
printf 'uptime='; cut -d ' ' -f 1 /proc/uptime
printf 'system_state='; systemctl is-system-running || true
echo 'failed_units:'
systemctl --failed --no-legend --plain || true
printf 'UDC='; cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || true
printf 'TCP_ADB='; ss -lnt | grep -q ':5555 ' && echo listening || echo absent
echo 'functions:'
find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | sort
echo 'usb0:'
ip -4 -br address show usb0 2>/dev/null || true
echo 'services:'
systemctl show adbd.service zu02-usb-gadget.service zu02-usb-network.service ssh.service \
    -p Id -p ActiveState -p SubState -p MainPID -p NRestarts --no-pager
'@
Save-Probe "previous-usb-units.txt" @'
journalctl -b -1 -o short-monotonic --no-pager \
    -u adbd.service \
    -u zu02-usb-gadget.service \
    -u zu02-usb-network.service \
    -u ssh.service
'@
Save-Probe "previous-kernel.txt" 'journalctl -k -b -1 -o short-monotonic --no-pager'
Save-Probe "previous-full.txt" 'journalctl -b -1 -o short-monotonic --no-pager'
Save-Probe "current-usb-units.txt" @'
journalctl -b 0 -o short-monotonic --no-pager \
    -u adbd.service \
    -u zu02-usb-gadget.service \
    -u zu02-usb-network.service \
    -u ssh.service
'@

$summary = @(
    "UFI210 Debian USB 故障现场采集完成"
    "adb_serial=$AdbSerial"
    "captured_at=$(Get-Date -Format o)"
    "output=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
