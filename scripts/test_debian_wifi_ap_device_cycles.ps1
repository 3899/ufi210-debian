[CmdletBinding()]
param(
    [string]$AdbSerial = "192.168.68.1:5555",
    [int]$Cycles = 20,
    [int]$Channel = 6,
    [int]$DwellSeconds = 2,
    [int]$ScanWaitSeconds = 3,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$ConnectionName = "ZU02 Wi-Fi AP"

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
    [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Invoke-Adb {
    param([string[]]$CommandArgs, [switch]$AllowFailure)
    Invoke-Native $Adb $CommandArgs -AllowFailure:$AllowFailure
}

function Get-AdbDmesg {
    (Invoke-Adb @("-s", $AdbSerial, "shell", "dmesg")).Text
}

function Invoke-DeviceCleanup {
    Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "nmcli connection down '$ConnectionName' >/dev/null 2>&1 || true; nmcli radio wifi on"
    ) -AllowFailure | Out-Null
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if ($Cycles -lt 1 -or $Cycles -gt 100) { throw "循环次数必须在 1 至 100 之间" }
if ($Channel -lt 1 -or $Channel -gt 13) { throw "2.4 GHz 测试信道必须在 1 至 13 之间" }

if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("wifi-ap-device-cycles-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$CsvPath = Join-Path $OutputDir "cycles.csv"

Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$adbDevices = Invoke-Adb @("devices", "-l")
if ($adbDevices.Text -notmatch "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") {
    throw "TCP ADB 不可用：$AdbSerial"
}

$profilePreflight = @'
systemctl is-active zu02-wcnss NetworkManager adbd ssh dnsmasq
printf 'FAILED_COUNT='; systemctl --failed --no-legend --plain | wc -l
printf 'REMOTEPROC_STATE='; cat /sys/class/remoteproc/remoteproc0/state
test "$(nmcli -g connection.autoconnect connection show '__CONNECTION__')" = no
test "$(nmcli -g 802-11-wireless.cloned-mac-address connection show '__CONNECTION__')" = stable
printf 'PROFILE_OK=yes\n'
'@.Replace('__CONNECTION__', $ConnectionName)
$serviceState = Invoke-Adb @("-s", $AdbSerial, "shell", $profilePreflight)
Write-Utf8File (Join-Path $OutputDir "preflight.txt") ($serviceState.Text + "`r`n")
if ($serviceState.Text -notmatch '(?s)^active\r?\nactive\r?\nactive\r?\nactive\r?\nactive\r?\nFAILED_COUNT=0\r?\nREMOTEPROC_STATE=running\r?\nPROFILE_OK=yes\r?$') {
    throw "设备端 AP 循环预检失败，查看 preflight.txt"
}

$networkManagerBefore = Invoke-Adb @(
    "-s", $AdbSerial, "shell", "journalctl -u NetworkManager --no-pager"
)
$networkManagerLineCountBefore = @($networkManagerBefore.Text -split "`r?`n").Count
$rows = @()
$expectedBssid = $null
$testError = $null

try {
    Invoke-DeviceCleanup
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        $cycleStart = Get-Date
        $dmesgBefore = Get-AdbDmesg
        $dmesgLineCountBefore = @($dmesgBefore -split "`r?`n").Count

        Invoke-Adb @(
            "-s", $AdbSerial, "shell",
            "nmcli connection up '$ConnectionName'"
        ) | Out-Null
        Start-Sleep -Seconds $DwellSeconds

        $apState = Invoke-Adb @(
            "-s", $AdbSerial, "shell",
            "nmcli -f GENERAL,IP4 connection show '$ConnectionName'; iw dev wlan0 info; " +
            "wpa_cli -i wlan0 status; ps -ef; cat /sys/class/remoteproc/remoteproc0/state"
        )
        Write-Utf8File (Join-Path $OutputDir ("cycle-{0:D3}-ap.txt" -f $cycle)) ($apState.Text + "`r`n")
        $bssidMatch = [regex]::Match($apState.Text, '(?im)^\s*addr ([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
        if ($apState.Text -notmatch '(?m)^GENERAL.STATE:\s+activated\s*$' -or
            $apState.Text -notmatch '(?m)^\s*type AP\s*$' -or
            $apState.Text -notmatch "(?m)^\s*channel $Channel \(" -or
            $apState.Text -notmatch '(?m)^wpa_state=COMPLETED\s*$' -or
            $apState.Text -notmatch '(?m)dnsmasq.*wlan0' -or
            $apState.Text -notmatch '(?m)^running\s*$' -or
            -not $bssidMatch.Success) {
            throw "第 $cycle 轮 AP 状态不正确"
        }
        $bssid = $bssidMatch.Groups[1].Value.ToLowerInvariant()
        if (-not $expectedBssid) { $expectedBssid = $bssid }
        if ($bssid -ne $expectedBssid) { throw "第 $cycle 轮 AP BSSID 改变：$bssid != $expectedBssid" }

        Invoke-DeviceCleanup
        Start-Sleep -Seconds 1
        Invoke-Adb @("-s", $AdbSerial, "shell", "nmcli device wifi rescan ifname wlan0") -AllowFailure | Out-Null
        Start-Sleep -Seconds $ScanWaitSeconds
        $scan = Invoke-Adb @(
            "-s", $AdbSerial, "shell",
            "nmcli -t --escape no -f BSSID,SSID,CHAN,SIGNAL,SECURITY device wifi list ifname wlan0"
        )
        Write-Utf8File (Join-Path $OutputDir ("cycle-{0:D3}-scan.txt" -f $cycle)) ($scan.Text + "`r`n")
        $bssCount = @($scan.Text -split "`r?`n" | Where-Object { $_ -match '^[0-9A-Fa-f]{2}:' }).Count
        if ($bssCount -eq 0) { throw "第 $cycle 轮 AP 停止后没有恢复 managed 扫描" }

        $cycleState = Invoke-Adb @(
            "-s", $AdbSerial, "shell",
            "iw dev wlan0 info; printf REMOTEPROC_STATE=; cat /sys/class/remoteproc/remoteproc0/state; " +
            "printf FAILED_COUNT=; systemctl --failed --no-legend --plain | wc -l"
        )
        if ($cycleState.Text -notmatch '(?m)^\s*type managed\s*$' -or
            $cycleState.Text -notmatch '(?m)^REMOTEPROC_STATE=running\s*$' -or
            $cycleState.Text -notmatch '(?m)^FAILED_COUNT=0\s*$') {
            throw "第 $cycle 轮恢复状态异常"
        }

        $dmesgAfter = Get-AdbDmesg
        $newKernelLines = @($dmesgAfter -split "`r?`n" | Select-Object -Skip $dmesgLineCountBefore)
        $newWcnssLines = @($newKernelLines | Where-Object { $_ -match '(?i)remoteproc|wcnss|wcn36|firmware' })
        Write-Utf8File (Join-Path $OutputDir ("cycle-{0:D3}-kernel.txt" -f $cycle)) (($newWcnssLines -join "`r`n") + "`r`n")
        $cleanupWarnings = @($newWcnssLines | Where-Object {
            $_ -match '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7'
        })
        $stopScanWarnings = @($newWcnssLines | Where-Object {
            $_ -match '(?i)wcn36xx: ERROR hal_stop_scan_offload response failed err=5'
        })
        $unknownWcnssErrors = @($newWcnssLines | Where-Object {
            ($_ -match '(?i)remoteproc.*\b(?:crash(?:ed)?|fatal|failed)\b') -or
            ($_ -match '(?i)(?:direct firmware load|request_firmware).*failed') -or
            ($_ -match '(?i)wcn36xx: ERROR' -and
                $_ -notmatch '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7' -and
                $_ -notmatch '(?i)wcn36xx: ERROR hal_stop_scan_offload response failed err=5')
        })
        if ($unknownWcnssErrors.Count -gt 0) { throw "第 $cycle 轮产生未知 WCNSS 错误" }

        $rows += [pscustomobject]@{
            Cycle = $cycle
            Seconds = [Math]::Round(((Get-Date) - $cycleStart).TotalSeconds, 1)
            Bssid = $bssid
            ManagedBssCount = $bssCount
            CleanupWarningCount = $cleanupWarnings.Count
            StopScanWarningCount = $stopScanWarnings.Count
            Remoteproc = "running"
            FailedUnits = 0
        }
        $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host ("AP_DEVICE_CYCLE_PASS={0}/{1} bssid={2} bss={3} warning={4}" -f
            $cycle, $Cycles, $bssid, $bssCount, $cleanupWarnings.Count)
    }
} catch {
    $testError = $_
} finally {
    Invoke-DeviceCleanup
}

if ($testError) {
    Write-Utf8File (Join-Path $OutputDir "FAILURE.txt") ($testError.ToString() + "`r`n")
    throw $testError
}

$networkManagerAfter = Invoke-Adb @(
    "-s", $AdbSerial, "shell", "journalctl -u NetworkManager --no-pager"
)
$newNetworkManagerLines = @($networkManagerAfter.Text -split "`r?`n" | Select-Object -Skip $networkManagerLineCountBefore)
Write-Utf8File (Join-Path $OutputDir "networkmanager-new.txt") (($newNetworkManagerLines -join "`r`n") + "`r`n")
$natHelperWarnings = @($newNetworkManagerLines | Where-Object {
    $_ -match "(?i)modprobe.*nf_nat_(?:ftp|irc|sip|tftp|pptp|h323).*not found"
})
$dnsmasqPidWarnings = @($newNetworkManagerLines | Where-Object {
    $_ -match '(?i)dnsmasq.*chown of PID file.*Operation not permitted'
})
$unknownNetworkManagerErrors = @($newNetworkManagerLines | Where-Object {
    $_ -match '(?i)NetworkManager.*<error>' -and
    $_ -notmatch "(?i)modprobe.*nf_nat_(?:ftp|irc|sip|tftp|pptp|h323).*not found"
})
if ($unknownNetworkManagerErrors.Count -gt 0) {
    throw "设备端循环产生未知 NetworkManager error，查看 networkmanager-new.txt"
}

$finalState = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "nmcli -t -f NAME,TYPE,DEVICE connection show; iw dev wlan0 info; " +
    "printf REMOTEPROC_STATE=; cat /sys/class/remoteproc/remoteproc0/state; " +
    "printf FAILED_COUNT=; systemctl --failed --no-legend --plain | wc -l; " +
    "printf AP_AUTOCONNECT=; nmcli -g connection.autoconnect connection show '$ConnectionName'; " +
    "if nmcli -t -f NAME connection show --active | grep -Fxq '$ConnectionName'; then " +
    "echo AP_ACTIVE=yes; else echo AP_ACTIVE=no; fi; ss -lntp"
)
Write-Utf8File (Join-Path $OutputDir "final-state.txt") ($finalState.Text + "`r`n")
if ($finalState.Text -notmatch '(?m)^\s*type managed\s*$' -or
    $finalState.Text -notmatch '(?m)^REMOTEPROC_STATE=running\s*$' -or
    $finalState.Text -notmatch '(?m)^FAILED_COUNT=0\s*$' -or
    $finalState.Text -notmatch '(?m)^AP_AUTOCONNECT=no\s*$' -or
    $finalState.Text -notmatch '(?m)^AP_ACTIVE=no\s*$') {
    throw "设备端循环完成后的最终状态异常"
}

$minBss = ($rows.ManagedBssCount | Measure-Object -Minimum).Minimum
$maxBss = ($rows.ManagedBssCount | Measure-Object -Maximum).Maximum
$totalCleanupWarnings = ($rows.CleanupWarningCount | Measure-Object -Sum).Sum
$totalStopScanWarnings = ($rows.StopScanWarningCount | Measure-Object -Sum).Sum
$summary = @(
    "Debian Wi-Fi AP 设备端循环验收通过"
    "management=usb-rndis-ssh-tcp-adb"
    "windows_wifi_switched=no"
    "profile=preinstalled-fixed-uuid"
    "cycles=$Cycles"
    "ap_bssid=$expectedBssid"
    "channel=$Channel"
    "managed_bss_min=$minBss"
    "managed_bss_max=$maxBss"
    "nonfatal_cleanup_warning_total=$totalCleanupWarnings"
    "nonfatal_stop_scan_mem_fail_warning_total=$totalStopScanWarnings"
    "optional_nat_helper_warning_total=$($natHelperWarnings.Count)"
    "dnsmasq_pid_chown_warning_total=$($dnsmasqPidWarnings.Count)"
    "unknown_networkmanager_errors=0"
    "remoteproc=running"
    "failed_units=0"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
