[CmdletBinding()]
param(
    [ValidateRange(10, 180)]
    [int]$TimeoutSeconds = 60,
    [string]$DeviceIp = "192.168.68.1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"

function Resolve-Tool {
    param([string]$BundledPath, [string]$CommandName)
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) { return $BundledPath }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "缺少工具：$CommandName"
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

function Get-AdbDevices {
    $result = Invoke-Native $Adb @("devices", "-l") -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device(?:\s+.*)?$') { $Matches[1] }
    })
}

function Get-FastbootDevices {
    $result = Invoke-Native $Fastboot @("devices") -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+fastboot\s*$') { $Matches[1] }
    })
}

function Assert-FastbootTarget {
    param([string]$Serial)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "getvar", "product") -AllowFailure
    if ($result.ExitCode -ne 0 -or
        $result.Text -notmatch '(?im)^(?:\(bootloader\)[ `t]*)?product:[ `t]*MSM8909[ `t]*\r?$') {
        throw "fastboot 目标不是 MSM8909：`r`n$($result.Text)"
    }
}

$Adb = Resolve-Tool $Adb "adb.exe"
$Fastboot = Resolve-Tool $Fastboot "fastboot.exe"

$fastbootDevices = @(Get-FastbootDevices)
if ($fastbootDevices.Count -gt 1) {
    throw "检测到多个 fastboot 设备：$($fastbootDevices -join ', ')"
}
if ($fastbootDevices.Count -eq 1) {
    Assert-FastbootTarget $fastbootDevices[0]
    Write-Host "设备已在 fastboot：$($fastbootDevices[0])"
    exit 0
}

$tcpAdbSerial = "${DeviceIp}:5555"
$upgradeUsbAdbSerial = "ZU02-DW01"
$adbDevices = @(Get-AdbDevices)
if ($adbDevices.Count -eq 0) {
    Invoke-Native $Adb @("connect", $tcpAdbSerial) -AllowFailure | Out-Null
    $adbDevices = @(Get-AdbDevices)
}
if ($adbDevices.Count -eq 0) { throw "没有检测到 UFI210 Debian ADB" }

$knownSerials = @($tcpAdbSerial, $upgradeUsbAdbSerial)
$unexpected = @($adbDevices | Where-Object { $_ -notin $knownSerials })
if ($unexpected.Count -gt 0) {
    throw "检测到未知 ADB 设备，拒绝重启：$($adbDevices -join ', ')"
}
$selectedAdb = if ($adbDevices -contains $tcpAdbSerial) { $tcpAdbSerial } else { $upgradeUsbAdbSerial }

$probe = Invoke-Native $Adb @(
    "-s", $selectedAdb, "shell",
    'test "$(hostname)" = ufi210 && test "$(cat /sys/devices/soc0/soc_id)" = 245 && test "$(findmnt -nro SOURCE /)" = /dev/mmcblk0p21 && test -x /system/bin/reboot && echo UFI210_DEBIAN_OK'
) -AllowFailure
if ($probe.ExitCode -ne 0 -or $probe.Text -notmatch '(?m)^UFI210_DEBIAN_OK\r?$') {
    throw "ADB 设备不是可重启到 fastboot 的 UFI210 Debian：`r`n$($probe.Text)"
}

Write-Host "正在进入 fastboot…"
Invoke-Native $Adb @(
    "-s", $selectedAdb, "shell", "/system/bin/reboot", "bootloader"
) -AllowFailure | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    $fastbootDevices = @(Get-FastbootDevices)
    if ($fastbootDevices.Count -gt 1) {
        throw "检测到多个 fastboot 设备：$($fastbootDevices -join ', ')"
    }
    if ($fastbootDevices.Count -eq 1) {
        Assert-FastbootTarget $fastbootDevices[0]
        Write-Host "fastboot 已就绪：$($fastbootDevices[0])"
        exit 0
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)

throw "设备未在 $TimeoutSeconds 秒内进入 fastboot"
