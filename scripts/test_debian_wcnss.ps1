[CmdletBinding()]
param(
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [ValidateRange(5, 60)]
    [int]$ScanWaitSeconds = 8,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$ManifestPath = Join-Path $ProjectRoot "out\mainline\debian-system\BUILD-MANIFEST.txt"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adbCommand) { $Adb = $adbCommand.Source }
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    $ManifestPath = Join-Path $ProjectRoot "BUILD-MANIFEST.txt"
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

function Read-Manifest {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    foreach ($key in @("wcnss_iris", "wcnss_country", "wcnss_nv_source", "rootfs_image_sha256", "boot_image_sha256")) {
        if (-not $values.ContainsKey($key)) { throw "构建清单缺少字段：$key" }
    }
    if ($values.wcnss_iris -ne "qcom,wcn3620" -or $values.wcnss_country -ne "CN") {
        throw "构建清单不是目标 WCN3620/CN 版本"
    }
    if ($values.wcnss_nv_source -ne "PARTLABEL-persist-read-only") {
        throw "构建清单未声明从本机只读 persist 使用 WCNSS NV"
    }
    return $values
}

function Wait-TcpAdb {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $devices = Invoke-Adb @("devices", "-l")
        if ($devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 15 秒内出现：$AdbSerial"
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "缺少构建清单：$ManifestPath" }
$manifest = Read-Manifest
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("wcnss-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-TcpAdb
$services = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "systemctl is-active zu02-wcnss NetworkManager; printf 'FAILED_COUNT='; systemctl --failed --no-legend --plain | wc -l"
)
Write-Utf8File (Join-Path $OutputDir "services.txt") ($services.Text + "`r`n")
if ($services.Text -notmatch '(?s)^active\r?\nactive\r?\nFAILED_COUNT=0\r?$') {
    throw "WCNSS/NetworkManager 服务状态不正确：`r`n$($services.Text)"
}

$remoteproc = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    'for d in /sys/class/remoteproc/remoteproc*; do [ -r "$d/name" ] || continue; printf "PATH=%s\n" "$d"; cat "$d/name"; cat "$d/state"; done'
)
Write-Utf8File (Join-Path $OutputDir "remoteproc.txt") ($remoteproc.Text + "`r`n")
if ($remoteproc.Text -notmatch '(?im)(a204000|a21b000|wcnss|pronto)' -or
    $remoteproc.Text -notmatch '(?m)^running\r?$') {
    throw "WCNSS remoteproc 未处于 running：`r`n$($remoteproc.Text)"
}

$nv = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "link=/usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin; target=`$(readlink `"`$link`"); test -L `"`$link`"; test `"`$target`" = /persist/WCNSS_qcom_wlan_nv.bin; test -s `"`$target`"; printf 'LINK_TARGET=%s\n' `"`$target`"; printf 'SIZE=%s\n' `"`$(stat -Lc %s `"`$target`")`"; printf 'MOUNT_OPTIONS='; findmnt -nro OPTIONS /persist"
)
Write-Utf8File (Join-Path $OutputDir "nv-policy.txt") ($nv.Text + "`r`n")
$nvSizeMatch = [regex]::Match($nv.Text, '(?m)^SIZE=([0-9]+)\r?$')
$mountOptionsMatch = [regex]::Match($nv.Text, '(?m)^MOUNT_OPTIONS=([^\r\n]+)\r?$')
if ($nv.Text -notmatch '(?m)^LINK_TARGET=/persist/WCNSS_qcom_wlan_nv\.bin\r?$' -or
    -not $nvSizeMatch.Success -or [int64]$nvSizeMatch.Groups[1].Value -le 0 -or
    -not $mountOptionsMatch.Success) {
    throw "设备 WCNSS NV 的链接、大小或 persist 挂载状态无效：`r`n$($nv.Text)"
}
$mountOptions = @($mountOptionsMatch.Groups[1].Value -split ',')
if ($mountOptions -notcontains 'ro' -or $mountOptions -contains 'rw') {
    throw "persist 未按只读方式挂载：$($mountOptionsMatch.Groups[1].Value)"
}

$iwInfo = Invoke-Adb @("-s", $AdbSerial, "shell", "iw dev wlan0 info")
$iwList = Invoke-Adb @("-s", $AdbSerial, "shell", "iw list")
$regulatory = Invoke-Adb @("-s", $AdbSerial, "shell", "iw reg get")
Write-Utf8File (Join-Path $OutputDir "iw-info.txt") ($iwInfo.Text + "`r`n")
Write-Utf8File (Join-Path $OutputDir "iw-list.txt") ($iwList.Text + "`r`n")
Write-Utf8File (Join-Path $OutputDir "regulatory.txt") ($regulatory.Text + "`r`n")
$macMatch = [regex]::Match($iwInfo.Text, '(?im)^\s*addr ([0-9a-f]{2}(?::[0-9a-f]{2}){5})\r?$')
if ($iwInfo.Text -notmatch '(?m)^Interface wlan0\r?$' -or -not $macMatch.Success) {
    throw "wlan0 或 MAC 地址无效：`r`n$($iwInfo.Text)"
}
$mac = $macMatch.Groups[1].Value.ToLowerInvariant()
if ($mac -eq "00:00:00:00:00:00" -or (([Convert]::ToInt32($mac.Split(':')[0], 16) -band 1) -ne 0)) {
    throw "wlan0 MAC 不是有效单播地址：$mac"
}
if ($iwList.Text -notmatch '(?m)^\s*\* managed\r?$' -or
    $iwList.Text -notmatch '(?m)^\s*\* AP\r?$') {
    throw "WCN36XX 未声明 managed/AP 模式"
}
if ($iwList.Text -notmatch '(?m)^\s*interface combinations are not supported\r?$') {
    throw "WCN36XX 并发接口能力与已验证硬件不一致"
}
if ($regulatory.Text -notmatch '(?m)^country CN:') {
    throw "无线监管域不是 CN：`r`n$($regulatory.Text)"
}

Invoke-Adb @("-s", $AdbSerial, "shell", "nmcli radio wifi on") | Out-Null
$rescan = Invoke-Adb @("-s", $AdbSerial, "shell", "nmcli device wifi rescan ifname wlan0") -AllowFailure
Start-Sleep -Seconds $ScanWaitSeconds
$scan = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "nmcli -t --escape no -f BSSID,SSID,CHAN,SIGNAL,SECURITY device wifi list ifname wlan0"
)
Write-Utf8File (Join-Path $OutputDir "rescan.txt") ($rescan.Text + "`r`n")
Write-Utf8File (Join-Path $OutputDir "scan.txt") ($scan.Text + "`r`n")
$networks = @($scan.Text -split "`r?`n" | Where-Object { $_ -match '^[0-9A-Fa-f]{2}:' })
if ($networks.Count -eq 0) {
    throw "wlan0 已创建但没有扫描到任何 BSS，不能确认射频链路"
}

$kernelLog = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "dmesg | grep -Ei 'remoteproc|wcnss|wcn36|firmware' | tail -n 300"
)
$journal = Invoke-Adb @("-s", $AdbSerial, "shell", "journalctl -u zu02-wcnss --no-pager")
Write-Utf8File (Join-Path $OutputDir "kernel-wcnss.txt") ($kernelLog.Text + "`r`n")
Write-Utf8File (Join-Path $OutputDir "journal-wcnss.txt") ($journal.Text + "`r`n")

$requiredKernelMilestones = @(
    @{ Pattern = '(?im)Booting fw image wcnss\.mdt'; Name = '开始加载 wcnss.mdt' }
    @{ Pattern = '(?im)remote processor .* is now up'; Name = 'remoteproc 启动完成' }
    @{ Pattern = '(?im)WCNSS Version'; Name = 'WCNSS control 握手完成' }
    @{ Pattern = '(?im)wcn36xx: firmware API'; Name = 'WCN36XX firmware API 就绪' }
)
foreach ($milestone in $requiredKernelMilestones) {
    if ($kernelLog.Text -notmatch $milestone.Pattern) {
        throw "WCNSS 内核日志缺少成功标志：$($milestone.Name)；查看 $OutputDir\kernel-wcnss.txt"
    }
}

$remoteprocUpMatches = [regex]::Matches(
    $kernelLog.Text,
    '(?im)remote processor .* is now up[^\r\n]*'
)
$lastRemoteprocUp = $remoteprocUpMatches[$remoteprocUpMatches.Count - 1]
$postBootLog = $kernelLog.Text.Substring($lastRemoteprocUp.Index + $lastRemoteprocUp.Length)
$postBootLines = @($postBootLog -split "`r?`n")
$cleanupWarnings = @($postBootLines | Where-Object {
    $_ -match '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7'
})
$stopScanWarnings = @($postBootLines | Where-Object {
    $_ -match '(?i)wcn36xx: ERROR hal_stop_scan_offload response failed err=5'
})
$fatalWcnssLines = @($postBootLines | Where-Object {
    ($_ -match '(?i)remoteproc.*\b(?:crash(?:ed)?|fatal|failed)\b') -or
    ($_ -match '(?i)(?:direct firmware load|request_firmware).*failed') -or
    ($_ -match '(?i)wcn36xx: ERROR' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_stop_scan_offload response failed err=5') -or
    ($_ -match '(?i)wcn36xx.*\b(?:crash(?:ed)?|fatal|failed)\b' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_stop_scan_offload response failed err=5') -or
    ($_ -match '(?i)wcnss.*\b(?:crash(?:ed)?|fatal|failed)\b')
})
if ($fatalWcnssLines.Count -gt 0) {
    throw "WCNSS 在最后一次成功启动后出现致命或未知错误，查看 $OutputDir\kernel-wcnss.txt"
}

$summary = @(
    "Debian WCNSS 实机验收通过"
    "remoteproc=running"
    "interface=wlan0"
    "mac=$mac"
    "managed_mode=supported"
    "ap_mode=supported"
    "managed_ap_concurrency=exclusive"
    "country=CN"
    "scan_bss_count=$($networks.Count)"
    "nonfatal_cleanup_warning_hal_delete_sta_self_err7=$($cleanupWarnings.Count)"
    "nonfatal_stop_scan_mem_fail_warning_err5=$($stopScanWarnings.Count)"
    "nv_source=device-persist-read-only"
    "nv_nonempty=true"
    "rootfs_sha256=$($manifest.rootfs_image_sha256)"
    "boot_sha256=$($manifest.boot_image_sha256)"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
