[CmdletBinding()]
param(
    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 300,
    [ValidateRange(1, 600)]
    [int]$MaxClockSkewSeconds = 120,
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
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

function Wait-TcpAdb {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $devices = Invoke-Adb @("devices", "-l")
        if ($devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 15 秒内连接：$AdbSerial"
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("time-sync-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-TcpAdb
$probeCommand = @'
printf 'ENABLED='; systemctl is-enabled systemd-timesyncd.service
printf 'ACTIVE='; systemctl is-active systemd-timesyncd.service
printf 'SYNCHRONIZED='; timedatectl show --property=NTPSynchronized --value
printf 'EPOCH='; date +%s
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
'@

$samples = New-Object 'Collections.Generic.List[string]'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$synchronized = $false
$deviceEpoch = 0L
$hostBefore = 0L
$hostAfter = 0L
do {
    $hostBefore = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $probe = Invoke-Adb @("-s", $AdbSerial, "shell", $probeCommand)
    $hostAfter = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sample = "host_before=$hostBefore host_after=$hostAfter`r`n$($probe.Text)"
    $samples.Add($sample)

    $epochMatch = [regex]::Match($probe.Text, '(?m)^EPOCH=(\d+)\r?$')
    if (-not $epochMatch.Success) { throw "无法解析设备时间：`r`n$($probe.Text)" }
    $deviceEpoch = [int64]$epochMatch.Groups[1].Value
    if ($probe.Text -notmatch '(?m)^ENABLED=enabled\r?$' -or
        $probe.Text -notmatch '(?m)^ACTIVE=active\r?$' -or
        $probe.Text -notmatch '(?m)^FAILED=0\r?$') {
        throw "时间同步服务或 systemd 状态异常：`r`n$($probe.Text)"
    }
    if ($probe.Text -match '(?m)^SYNCHRONIZED=yes\r?$') {
        $synchronized = $true
        break
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

Write-Utf8File (Join-Path $OutputDir "samples.txt") (($samples -join "`r`n---`r`n") + "`r`n")
if (-not $synchronized) {
    throw "设备未在 $TimeoutSeconds 秒内完成 NTP 同步；查看 $OutputDir\samples.txt"
}

$minimumEpoch = $hostBefore - $MaxClockSkewSeconds
$maximumEpoch = $hostAfter + $MaxClockSkewSeconds
if ($deviceEpoch -lt $minimumEpoch -or $deviceEpoch -gt $maximumEpoch) {
    throw "设备时间与宿主偏差超过 $MaxClockSkewSeconds 秒：device=$deviceEpoch host=$hostBefore..$hostAfter"
}

$diagnostic = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "timedatectl status; systemctl status systemd-timesyncd.service --no-pager; journalctl -b -u systemd-timesyncd.service --no-pager"
)
Write-Utf8File (Join-Path $OutputDir "diagnostic.txt") ($diagnostic.Text + "`r`n")
$clockSkewSeconds = [Math]::Min([Math]::Abs($deviceEpoch - $hostBefore), [Math]::Abs($deviceEpoch - $hostAfter))
$summary = @(
    "Debian 联网自动校时验收通过"
    "ntp_synchronized=true"
    "service_enabled=true"
    "service_active=true"
    "device_epoch=$deviceEpoch"
    "host_epoch_before=$hostBefore"
    "host_epoch_after=$hostAfter"
    "clock_skew_seconds=$clockSkewSeconds"
    "max_clock_skew_seconds=$MaxClockSkewSeconds"
    "systemd_failed=0"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
