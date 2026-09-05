[CmdletBinding()]
param(
    [string]$AdbSerial = "192.168.68.1:5555",
    [int]$ReadyTimeoutSeconds = 180,
    [int]$ObservationSeconds = 60,
    [string]$BaselineDirectory = "",
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

function Read-PartitionHashes {
    $command = @'
set -eu
for name in modem modemst1 modemst2 fsg persist; do
    path=/dev/disk/by-partlabel/$name
    [ -e "$path" ] || { echo "MISSING  $name"; continue; }
    value=$(sha256sum "$path")
    value=${value%% *}
    printf '%s  %s\n' "$value" "$name"
done
'@
    $result = Invoke-AdbShell $command
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

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if ($ReadyTimeoutSeconds -lt 30 -or $ObservationSeconds -lt 0) {
    throw "超时参数无效"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("mpss-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$deviceState = Invoke-Native $Adb @("-s", $AdbSerial, "get-state") -AllowFailure
if ($deviceState.ExitCode -ne 0 -or $deviceState.Text.Trim() -ne "device") {
    throw "TCP ADB 不可用：$AdbSerial"
}

if (-not $BaselineDirectory) {
    $baselineRoot = Join-Path $ProjectRoot "out\pre-m5-baseline"
    $BaselineDirectory = Get-ChildItem -LiteralPath $baselineRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $BaselineDirectory -or -not (Test-Path -LiteralPath $BaselineDirectory -PathType Container)) {
    throw "缺少 M5 前 Android 分区基线目录"
}
$baselineSources = @{
    modem = Join-Path $ProjectRoot "resource\backup\0.modem.fat"
    modemst1 = Join-Path $BaselineDirectory "modemst1.img"
    modemst2 = Join-Path $BaselineDirectory "modemst2.img"
    fsg = Join-Path $BaselineDirectory "fsg.img"
    persist = Join-Path $BaselineDirectory "persist.img"
}
$baselineHashes = @{}
foreach ($name in $baselineSources.Keys) {
    $path = $baselineSources[$name]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "基线缺少：$path" }
    $baselineHashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$windowsWlanBefore = (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces") -AllowFailure).Text
Write-Utf8File (Join-Path $OutputDir "windows-wlan-before.txt") ($windowsWlanBefore + "`r`n")

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
$ready = $false
do {
    $probe = Invoke-AdbShell 'systemctl is-active qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register >/dev/null 2>&1 && test -e /dev/wwan0qmi0 && test -e /sys/class/net/wwan0 && mmcli -L | grep -q /Modem/' -AllowFailure
    $ready = $probe.ExitCode -eq 0
    if (-not $ready) { Start-Sleep -Seconds 2 }
} while (-not $ready -and (Get-Date) -lt $deadline)

$serviceProbe = Invoke-AdbShell @'
set +e
echo '=== BOOT ==='
cat /proc/sys/kernel/random/boot_id
uname -a
echo '=== SERVICES ==='
systemctl is-active qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register
systemctl show rmtfs -p ExecStart --no-pager
systemctl --failed --no-pager
echo '=== FIRMWARE MOUNT ==='
findmnt -nro SOURCE,FSTYPE,OPTIONS /firmware
echo '=== PERSIST MOUNT ==='
findmnt -nro SOURCE,FSTYPE,OPTIONS /persist
grep '^PARTLABEL=persist /persist ext4 ' /etc/fstab
echo '=== REMOTEPROC ==='
for r in /sys/class/remoteproc/remoteproc*; do
    [ -r "$r/name" ] || continue
    printf '%s name=' "${r##*/}"
    cat "$r/name"
    printf '%s state=' "${r##*/}"
    cat "$r/state"
    printf '%s firmware=' "${r##*/}"
    cat "$r/firmware" 2>/dev/null || true
done
echo '=== MODULES ==='
lsmod | grep -E 'qcom_q6v5_mss|qcom_bam_dmux|rpmsg_wwan_ctrl'
echo '=== WWAN ==='
ls -l /dev/wwan* 2>&1
ip -details link show wwan0 2>&1
echo '=== QRTR ==='
timeout 5 qrtr-lookup 2>&1
echo '=== MODEM LIST ==='
mmcli -L 2>&1
mmcli -m any --output-keyvalue 2>&1 | grep '^modem.generic.current-modes'
echo '=== FAILED COUNT ==='
systemctl --failed --no-legend --plain | wc -l
'@ -AllowFailure
Write-Utf8File (Join-Path $OutputDir "mpss-probe.txt") ($serviceProbe.Text + "`r`n")

if (-not $ready) {
    $journal = Invoke-AdbShell 'journalctl -b -u qrtr-ns -u rmtfs -u zu02-mpss -u zu02-modem-prepare -u ModemManager --no-pager; dmesg | tail -n 500' -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "failure-journal.txt") ($journal.Text + "`r`n")
    throw "MPSS/ModemManager 未在超时内就绪；查看 $OutputDir"
}

$before = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-before.txt") ($before.Text + "`r`n")
$baselineComparison = New-Object Collections.Generic.List[string]
foreach ($name in @("modem", "modemst1", "modemst2", "fsg")) {
    $baselineComparison += "$name.android_live_baseline_sha256=$($baselineHashes[$name])"
    $baselineComparison += "$name.debian_pre_observation_sha256=$($before.Values[$name])"
}
$baselineComparison += @(
    "persist.android_live_baseline_sha256=$($baselineHashes.persist)"
    "persist.debian_pre_observation_sha256=$($before.Values.persist)"
    "comparison=informational-only-because-Android-and-the-modem-may-update-state-during-shutdown"
)
$baselineComparisonText = $baselineComparison -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "cross-boot-baseline-comparison.txt") ($baselineComparisonText + "`r`n")
$persistPolicy = @(
    "android_live_baseline_sha256=$($baselineHashes.persist)"
    "debian_pre_observation_sha256=$($before.Values.persist)"
    "policy=read-only-noload-and-same-boot-before-after-hash-equality"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "persist-policy.txt") ($persistPolicy + "`r`n")

$modemRaw = (Invoke-AdbShell 'mmcli -m any --output-keyvalue' -AllowFailure).Text
$simRaw = (Invoke-AdbShell 'mmcli -i any --output-keyvalue' -AllowFailure).Text
Write-Utf8File (Join-Path $OutputDir "modem-redacted.txt") ((Protect-Identifier $modemRaw) + "`r`n")
Write-Utf8File (Join-Path $OutputDir "sim-redacted.txt") ((Protect-Identifier $simRaw) + "`r`n")

if ($modemRaw -notmatch '(?m)^modem\.generic\.sim\s*[=:]\s*/.+') {
    throw "ModemManager 已发现 modem，但没有关联 SIM；查看 $OutputDir\modem-redacted.txt"
}
if ($simRaw -notmatch '(?m)^sim\.properties\.active\s*[=:]\s*(true|yes|1)\s*$' -and
    $simRaw -notmatch '(?m)^sim\.properties\.sim-identifier\s*[=:]\s*(?!--)\S+') {
    throw "ModemManager 未返回可用 SIM 信息；查看 $OutputDir\sim-redacted.txt"
}

$signalSetup = Invoke-AdbShell 'mmcli -m any --signal-setup=5' -AllowFailure
Write-Utf8File (Join-Path $OutputDir "signal-setup.txt") ((Protect-Identifier $signalSetup.Text) + "`r`n")
if ($ObservationSeconds -gt 0) { Start-Sleep -Seconds $ObservationSeconds }
$signal = Invoke-AdbShell 'mmcli -m any --signal-get --output-keyvalue' -AllowFailure
Write-Utf8File (Join-Path $OutputDir "signal-redacted.txt") ((Protect-Identifier $signal.Text) + "`r`n")

$after = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-after.txt") ($after.Text + "`r`n")
foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
    if ($before.Values[$name] -ne $after.Values[$name]) {
        throw "只读 M5 观察期间分区发生变化：$name"
    }
}

$journal = Invoke-AdbShell 'journalctl -b -u qrtr-ns -u rmtfs -u zu02-mpss -u zu02-modem-prepare -u ModemManager --no-pager; dmesg | grep -Ei "remoteproc|q6v5|mpss|modem|bam|wwan|qrtr|rmtfs" | tail -n 500' -AllowFailure
Write-Utf8File (Join-Path $OutputDir "mpss-journal.txt") ((Protect-Identifier $journal.Text) + "`r`n")
$windowsWlanAfter = (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces") -AllowFailure).Text
Write-Utf8File (Join-Path $OutputDir "windows-wlan-after.txt") ($windowsWlanAfter + "`r`n")

if ($serviceProbe.Text -notmatch '/org/freedesktop/ModemManager1/Modem/[0-9]+' -or
    $serviceProbe.Text -notmatch '(?m)^remoteproc[0-9]+ state=running\s*$' -or
    $serviceProbe.Text -notmatch 'argv\[\]=/usr/bin/rmtfs -r -P -s' -or
    $serviceProbe.Text -notmatch '(?m)^\S+\s+vfat\s+ro(?:,|\s*$)' -or
    $serviceProbe.Text -notmatch '(?ms)=== PERSIST MOUNT ===\r?\n\S+\s+ext4\s+ro(?:,|\s)' -or
    $serviceProbe.Text -notmatch '(?m)^PARTLABEL=persist /persist ext4 ro,noload,') {
    throw "ModemManager 探针输出异常；查看 $OutputDir\mpss-probe.txt"
}
if ($serviceProbe.Text -notmatch '(?m)^modem\.generic\.current-modes\s*: allowed: 3g, 4g; preferred: 4g\s*$') {
    throw "modem 默认模式不是 3G+4G/优先 4G；查看 $OutputDir\mpss-probe.txt"
}
if ($serviceProbe.Text -notmatch '(?ms)=== FAILED COUNT ===\r?\n0\s*$') {
    throw "systemd 存在失败单元；查看 $OutputDir\mpss-probe.txt"
}

$summary = @(
    "M5 MPSS 第一阶段验收通过"
    "management=USB RNDIS + TCP ADB only"
    "firmware_mount=read-only"
    "mpss=running"
    "qmi=/dev/wwan0qmi0"
    "wwan=wwan0"
    "modemmanager=detected"
    "modem_default_modes=3g+4g-preferred-4g"
    "sim=detected"
    "rmtfs=read-only-shadow-buffer"
    "cross-boot-baseline=informational-only"
    "persist_mount=read-only-noload"
    "partition_hashes=unchanged-during-Debian-observation"
    "dialing=not-tested"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
