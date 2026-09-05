[CmdletBinding()]
param(
    [string]$AdbSerial = "192.168.68.1:5555",
    [ValidateRange(30, 600)]
    [int]$RegistrationTimeoutSeconds = 180,
    [ValidateSet("3g|4g", "2g|3g|4g")]
    [string]$AllowedModes = "3g|4g",
    [ValidateSet("3g", "4g")]
    [string]$PreferredMode = "4g",
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

function Invoke-AdbShell {
    param([string]$Command, [switch]$AllowFailure)
    return Invoke-Native $Adb @("-s", $AdbSerial, "shell", $Command) -AllowFailure:$AllowFailure
}

function Protect-Identifier {
    param([AllowEmptyString()][string]$Text)
    $redacted = $Text -replace '(?im)^((?:modem|sim|bearer)\..*(?:equipment-identifier|device-identifier|imsi|sim-identifier|operator-code|own-number|(?:settings|properties)\.(?:user|password)).*?[=:]).+$', '$1 [REDACTED]'
    return $redacted -replace '(?<![0-9])[0-9]{10,22}(?![0-9])', '[REDACTED]'
}

function Get-GenericBearerIndexes {
    param([string]$Text)

    $lines = @($Text -split "`r?`n" | Where-Object {
        $_ -match '^modem\.generic\.bearers(?:\.value\[[0-9]+\])?\s*:'
    })
    if ($lines.Count -eq 0) { throw "ModemManager 输出缺少 modem.generic.bearers 字段" }
    return @([regex]::Matches(($lines -join "`n"), '/org/freedesktop/ModemManager1/Bearer/([0-9]+)') |
        ForEach-Object { $_.Groups[1].Value })
}

function Read-PartitionHashes {
    $result = Invoke-AdbShell @'
set -eu
for name in modem modemst1 modemst2 fsg persist; do
    path=/dev/disk/by-partlabel/$name
    [ -e "$path" ] || { echo "MISSING  $name"; continue; }
    value=$(sha256sum "$path")
    value=${value%% *}
    printf '%s  %s\n' "$value" "$name"
done
'@
    $values = @{}
    foreach ($line in $result.Text -split "`r?`n") {
        if ($line -match '^([0-9a-f]{64})\s+([a-z0-9]+)$') {
            $values[$Matches[2]] = $Matches[1]
        }
    }
    foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
        if (-not $values.ContainsKey($name)) { throw "无法读取分区哈希：$name" }
    }
    return [pscustomobject]@{ Values = $values; Text = $result.Text }
}

function Test-Registered {
    param([string]$ModemStatus)
    return (
        $ModemStatus -match '(?m)^modem\.generic\.state\s*:\s*(registered|connected)\s*$' -or
        $ModemStatus -match '(?m)^modem\.3gpp\.registration-state\s*:\s*(home|roaming|registered)\s*$' -or
        $ModemStatus -match '(?m)^modem\.cdma\.(?:cdma1x|evdo)-registration-state\s*:\s*(home|roaming|registered)\s*$'
    )
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("lte-registration-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$deviceState = Invoke-Native $Adb @("-s", $AdbSerial, "get-state")
if ($deviceState.Text.Trim() -ne "device") { throw "TCP ADB 不可用：$AdbSerial" }

$policy = Invoke-AdbShell @'
set -eu
systemctl is-active rmtfs zu02-mpss zu02-modem-prepare ModemManager
systemctl show rmtfs -p ExecStart --no-pager
findmnt -nro SOURCE,FSTYPE,OPTIONS /firmware
findmnt -nro SOURCE,FSTYPE,OPTIONS /persist
grep '^PARTLABEL=persist /persist ext4 ro,noload,' /etc/fstab
'@
Write-Utf8File (Join-Path $OutputDir "write-protection.txt") ($policy.Text + "`r`n")
if ($policy.Text -notmatch 'argv\[\]=/usr/bin/rmtfs -r -P -s' -or
    $policy.Text -notmatch '(?m)^\S+\s+vfat\s+ro(?:,|$)' -or
    $policy.Text -notmatch '(?m)^\S+\s+ext4\s+ro(?:,|$)' -or
    $policy.Text -notmatch '(?m)^PARTLABEL=persist /persist ext4 ro,noload,') {
    throw "只读保护不符合要求，拒绝修改 modem 运行时模式；查看 $OutputDir\write-protection.txt"
}

$bearers = Invoke-AdbShell 'mmcli -m any --output-keyvalue'
Write-Utf8File (Join-Path $OutputDir "bearers-before-redacted.txt") ((Protect-Identifier $bearers.Text) + "`r`n")
if (@(Get-GenericBearerIndexes $bearers.Text).Count -ne 0) {
    throw "modem 已存在 bearer，拒绝中断现有数据连接"
}

$before = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-before.txt") ($before.Text + "`r`n")
$testFailure = $null
$registered = $false
$initialStatus = ""
$finalStatus = ""

try {
    $initialStatus = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
    Write-Utf8File (Join-Path $OutputDir "modem-before-redacted.txt") ((Protect-Identifier $initialStatus) + "`r`n")

    $setMode = Invoke-AdbShell "mmcli -m any --set-allowed-modes='$AllowedModes' --set-preferred-mode='$PreferredMode'"
    Write-Utf8File (Join-Path $OutputDir "set-mode.txt") ($setMode.Text + "`r`n")

    $deadline = (Get-Date).AddSeconds($RegistrationTimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $statusResult = Invoke-AdbShell 'mmcli -m any --output-keyvalue' -AllowFailure
        if ($statusResult.ExitCode -eq 0) {
            $finalStatus = $statusResult.Text
            $registered = Test-Registered $finalStatus
        }
    } while (-not $registered -and (Get-Date) -lt $deadline)

    Write-Utf8File (Join-Path $OutputDir "modem-after-redacted.txt") ((Protect-Identifier $finalStatus) + "`r`n")
    $signal = Invoke-AdbShell 'mmcli -m any --signal-get --output-keyvalue' -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "signal-redacted.txt") ((Protect-Identifier $signal.Text) + "`r`n")
    if (-not $registered) {
        throw "modem 未在 $RegistrationTimeoutSeconds 秒内注册网络"
    }
} catch {
    $testFailure = $_
} finally {
    $after = Read-PartitionHashes
    Write-Utf8File (Join-Path $OutputDir "partition-hashes-after.txt") ($after.Text + "`r`n")
    foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
        if ($before.Values[$name] -ne $after.Values[$name]) {
            throw "LTE 注册测试期间敏感分区发生变化：$name；立即停止后续测试"
        }
    }
}

if ($null -ne $testFailure) {
    throw "$($testFailure.Exception.Message)；敏感分区哈希保持不变；查看 $OutputDir"
}

$summary = @(
    "Debian LTE 注册验收通过"
    "management=USB RNDIS + TCP ADB only"
    "allowed_modes=$AllowedModes"
    "preferred_mode=$PreferredMode"
    "network_registration=registered"
    "bearer=not-created"
    "dialing=not-tested"
    "rmtfs=read-only-shadow-buffer"
    "persist_mount=read-only-noload"
    "partition_hashes=unchanged-during-registration"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
