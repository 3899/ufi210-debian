[CmdletBinding()]
param(
    [ValidateRange(10, 180)]
    [int]$TimeoutSeconds = 60,
    [string]$AdbSerial = "192.168.68.1:5555",
    [switch]$ReturnToDebian,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Resolve-Tool {
    param([string]$BundledPath, [string]$CommandName)
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) { return $BundledPath }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "缺少工具：$CommandName"
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$CommandArgs, [switch]$AllowFailure)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$FilePath 失败（$exitCode）：`r`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Wait-FastbootDevice {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-Native $Fastboot @("devices") -AllowFailure
        $devices = @($result.Text -split "`r?`n" | Where-Object { $_ -match '^\S+\s+fastboot\s*$' })
        if ($devices.Count -eq 1) { return ($devices[0] -split '\s+')[0] }
        if ($devices.Count -gt 1) { throw "检测到多个 fastboot 设备，拒绝继续" }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "设备未在 $TimeoutSeconds 秒内进入 fastboot"
}

function Wait-DebianAdb {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $result = Invoke-Native $Adb @("devices", "-l") -AllowFailure
        if ($result.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Debian TCP ADB 未在 $TimeoutSeconds 秒内恢复：$AdbSerial"
}

$Adb = Resolve-Tool $Adb "adb.exe"
$Fastboot = Resolve-Tool $Fastboot "fastboot.exe"
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("fastboot-reboot-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-DebianAdb
$probeCommand = @'
set -eu
test "$(uname -m)" = armv7l
grep -Fq DW01 /proc/device-tree/model
grep -Fq ZU02_main_v1.1 /proc/device-tree/model
test -x /system/bin/reboot
test -d /sys/firmware/devicetree/base/soc@0/sram@8600000/reboot-mode
grep -q 'root=PARTLABEL=system' /proc/cmdline
printf 'boot_id='; cat /proc/sys/kernel/random/boot_id
printf 'kernel='; uname -r
printf 'root='; findmnt -n -o SOURCE /
'@
$probe = Invoke-Native $Adb @("-s", $AdbSerial, "shell", $probeCommand)
[IO.File]::WriteAllText((Join-Path $OutputDir "debian-before.txt"), $probe.Text + "`r`n", $Utf8NoBom)

$reboot = Invoke-Native $Adb @(
    "-s", $AdbSerial, "shell", "/system/bin/reboot", "bootloader"
) -AllowFailure
[IO.File]::WriteAllText(
    (Join-Path $OutputDir "reboot-command.txt"),
    "exit_code=$($reboot.ExitCode)`r`n$($reboot.Text)`r`n",
    $Utf8NoBom
)

$FastbootSerial = Wait-FastbootDevice
$getvar = Invoke-Native $Fastboot @("-s", $FastbootSerial, "getvar", "product") -AllowFailure
[IO.File]::WriteAllText(
    (Join-Path $OutputDir "fastboot.txt"),
    "serial=$FastbootSerial`r`nexit_code=$($getvar.ExitCode)`r`n$($getvar.Text)`r`n",
    $Utf8NoBom
)

if ($ReturnToDebian) {
    Invoke-Native $Fastboot @("-s", $FastbootSerial, "reboot") | Out-Null
    Wait-DebianAdb
}

$summary = @(
    "Debian 进入 fastboot 验收通过"
    "adb_serial=$AdbSerial"
    "fastboot_serial=$FastbootSerial"
    "return_to_debian=$($ReturnToDebian.IsPresent.ToString().ToLowerInvariant())"
    "completed=$(Get-Date -Format o)"
    "logs=$OutputDir"
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $OutputDir "SUMMARY.txt"), $summary + "`r`n", $Utf8NoBom)
Write-Host $summary
