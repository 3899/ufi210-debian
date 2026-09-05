[CmdletBinding()]
param(
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$WindowsInterface = "WLAN",
    [string]$Ssid = "ZU02-M4-TEST",
    [string]$Psk = "simadmin",
    [int]$Channel = 6,
    [int]$AssociationTimeoutSeconds = 30,
    [int]$ScanWaitSeconds = 8,
    [int]$TransferMiB = 8,
    [switch]$AllowWindowsWifiSwitch,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$ConnectionName = "zu02-m4-ap-test"

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

function Invoke-Adb {
    param([string[]]$CommandArgs, [switch]$AllowFailure)
    Invoke-Native $Adb $CommandArgs -AllowFailure:$AllowFailure
}

function Get-WlanInterfaces {
    (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces")).Text
}

function Wait-WlanProfile {
    param([string]$Profile, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = Get-WlanInterfaces
        if ($state -match '(?m)^\s*State\s*:\s*connected\s*$' -and
            $state -match "(?m)^\s*SSID\s*:\s*$([regex]::Escape($Profile))\s*$") {
            return $state
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $null
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $AllowWindowsWifiSwitch) {
    throw "该脚本会切换 Windows Wi-Fi。默认禁止执行；仅在明确允许主机断网时添加 -AllowWindowsWifiSwitch。"
}
if ($Ssid -notmatch '^[A-Za-z0-9._-]{1,32}$') { throw "测试 SSID 只能使用 1 至 32 个 ASCII 字母、数字、点、下划线或连字符" }
if ($Psk -notmatch '^[A-Za-z0-9._-]{8,63}$') { throw "测试 PSK 必须是 8 至 63 个受限 ASCII 字符" }
if ($Channel -lt 1 -or $Channel -gt 13) { throw "2.4 GHz 测试信道必须在 1 至 13 之间" }
if ($TransferMiB -lt 1 -or $TransferMiB -gt 64) { throw "传输测试大小必须在 1 至 64 MiB 之间" }

if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("wifi-ap-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$adbDevices = Invoke-Adb @("devices", "-l")
if ($adbDevices.Text -notmatch "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") {
    throw "TCP ADB 不可用：$AdbSerial"
}

$serviceState = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "systemctl is-active zu02-wcnss NetworkManager adbd ssh dnsmasq"
)
if ($serviceState.Text -notmatch '(?s)^active\r?\nactive\r?\nactive\r?\nactive\r?\nactive\r?$') {
    throw "AP 测试前服务状态不正确：`r`n$($serviceState.Text)"
}
$kernelBefore = Invoke-Adb @("-s", $AdbSerial, "shell", "dmesg")
$kernelLineCountBefore = @($kernelBefore.Text -split "`r?`n").Count
$networkManagerJournalBefore = Invoke-Adb @(
    "-s", $AdbSerial, "shell", "journalctl -u NetworkManager --no-pager"
)
$networkManagerLineCountBefore = @($networkManagerJournalBefore.Text -split "`r?`n").Count

$windowsBefore = Get-WlanInterfaces
Write-Utf8File (Join-Path $OutputDir "windows-before.txt") ($windowsBefore + "`r`n")
$profileMatch = [regex]::Match($windowsBefore, '(?m)^\s*Profile\s*:\s*(.+?)\s*$')
$hostMacMatch = [regex]::Match($windowsBefore, '(?im)^\s*Physical address\s*:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
if (-not $profileMatch.Success -or -not $hostMacMatch.Success) {
    throw "无法识别 Windows 当前 WLAN 配置文件或物理地址"
}
$OriginalProfile = $profileMatch.Groups[1].Value.Trim()
$HostMac = $hostMacMatch.Groups[1].Value.ToLowerInvariant()

$escapedSsid = [Security.SecurityElement]::Escape($Ssid)
$escapedPsk = [Security.SecurityElement]::Escape($Psk)
$profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedSsid</name>
  <SSIDConfig><SSID><name>$escapedSsid</name></SSID><nonBroadcast>true</nonBroadcast></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$escapedPsk</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
$profilePath = Join-Path ([IO.Path]::GetTempPath()) ("zu02-ap-{0}.xml" -f [guid]::NewGuid().ToString("N"))
Write-Utf8File $profilePath $profileXml

$testError = $null
$windowsAssociated = $null
$stationDump = $null
$windowsClientIp = $null
$payloadSha256 = $null
$downloadMbps = 0.0
$uploadMbps = 0.0
$transferBytes = $TransferMiB * 1MB
$downloadPath = Join-Path $OutputDir "payload-download.bin"
try {
    Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "nmcli connection down $ConnectionName >/dev/null 2>&1 || true; " +
        "nmcli connection delete $ConnectionName >/dev/null 2>&1 || true; " +
        "nmcli connection add type wifi ifname wlan0 con-name $ConnectionName autoconnect no ssid $Ssid; " +
        "nmcli connection modify $ConnectionName 802-11-wireless.mode ap 802-11-wireless.band bg " +
        "802-11-wireless.channel $Channel 802-11-wireless.powersave 2 " +
        "802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk $Psk " +
        "ipv4.method shared ipv4.addresses 192.168.69.1/24 ipv4.never-default yes ipv6.method disabled; " +
        "nmcli connection up $ConnectionName"
    ) | Out-Null

    $apState = Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "nmcli -f GENERAL,802-11-WIRELESS,IP4 connection show $ConnectionName; iw dev wlan0 info; wpa_cli -i wlan0 status"
    )
    Write-Utf8File (Join-Path $OutputDir "device-ap-state.txt") ($apState.Text + "`r`n")
    if ($apState.Text -notmatch '(?m)^GENERAL.STATE:\s+activated\s*$' -or
        $apState.Text -notmatch '(?m)^\s*type AP\s*$' -or
        $apState.Text -notmatch "(?m)^\s*ssid $([regex]::Escape($Ssid))\s*$" -or
        $apState.Text -notmatch "(?m)^\s*channel $Channel \(" -or
        $apState.Text -notmatch '(?m)^wpa_state=COMPLETED\s*$') {
        throw "设备未进入预期 AP 状态，查看 device-ap-state.txt"
    }

    Invoke-Native "netsh.exe" @("wlan", "add", "profile", "filename=$profilePath", "interface=$WindowsInterface", "user=current") | Out-Null
    Invoke-Native "netsh.exe" @("wlan", "connect", "name=$Ssid", "ssid=$Ssid", "interface=$WindowsInterface") | Out-Null
    $windowsAssociated = Wait-WlanProfile $Ssid $AssociationTimeoutSeconds
    if (-not $windowsAssociated) { throw "Windows 未能关联 $Ssid" }
    Write-Utf8File (Join-Path $OutputDir "windows-associated.txt") ($windowsAssociated + "`r`n")

    $dhcpDeadline = (Get-Date).AddSeconds($AssociationTimeoutSeconds)
    do {
        $windowsClientIp = Get-NetIPAddress -InterfaceAlias $WindowsInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '192.168.69.*' } |
            Select-Object -ExpandProperty IPAddress -First 1
        if (-not $windowsClientIp) { Start-Sleep -Seconds 1 }
    } while (-not $windowsClientIp -and (Get-Date) -lt $dhcpDeadline)
    if (-not $windowsClientIp) { throw "Windows 已关联 AP，但没有获得 192.168.69.0/24 DHCP 地址" }

    $ipConfig = ipconfig.exe /all | Out-String
    Write-Utf8File (Join-Path $OutputDir "windows-dhcp.txt") ($ipConfig + "`r`n")
    $leaseState = Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "cat /var/lib/NetworkManager/dnsmasq-wlan0.leases; ps -ef"
    )
    Write-Utf8File (Join-Path $OutputDir "device-dhcp.txt") ($leaseState.Text + "`r`n")
    if ($leaseState.Text -notmatch "(?im)\s$([regex]::Escape($windowsClientIp))\s") {
        throw "NetworkManager dnsmasq 租约中没有 Windows 客户端地址 $windowsClientIp"
    }

    $ping = New-Object Net.NetworkInformation.Ping
    try {
        $pingResults = 1..8 | ForEach-Object {
            $phase = if ($_ -le 3) { "warmup" } else { "measured" }
            $reply = $ping.Send("192.168.69.1", 2000)
            $sample = [pscustomobject]@{
                Sequence = $_
                Phase = $phase
                Status = $reply.Status
                RoundtripTime = $reply.RoundtripTime
                Address = $reply.Address
            }
            Start-Sleep -Milliseconds 250
            $sample
        }
    } finally {
        $ping.Dispose()
    }
    Write-Utf8File (Join-Path $OutputDir "ping-ap.txt") (($pingResults | Format-Table -AutoSize | Out-String) + "`r`n")
    $measuredPingFailures = @($pingResults | Where-Object {
        $_.Phase -eq "measured" -and $_.Status -ne [Net.NetworkInformation.IPStatus]::Success
    })
    if ($measuredPingFailures.Count -gt 0) {
        throw "Windows 通过 AP 的 5 个正式 ping 样本存在丢包，查看 ping-ap.txt"
    }

    $payload = Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "mkdir -p /run/zu02-ap-test; " +
        "busybox dd if=/dev/urandom of=/run/zu02-ap-test/payload.bin bs=1048576 count=$TransferMiB; " +
        "busybox sha256sum /run/zu02-ap-test/payload.bin; " +
        "nohup busybox httpd -f -p 192.168.69.1:8080 -h /run/zu02-ap-test " +
        ">/run/zu02-ap-test/httpd.log 2>&1 </dev/null & echo `$! >/run/zu02-ap-test/httpd.pid"
    )
    $payloadHashMatch = [regex]::Match($payload.Text, '(?im)^([0-9a-f]{64})\s+/run/zu02-ap-test/payload\.bin\s*$')
    if (-not $payloadHashMatch.Success) { throw "无法获得设备测试文件 SHA256" }
    $payloadSha256 = $payloadHashMatch.Groups[1].Value.ToLowerInvariant()

    $webClient = New-Object Net.WebClient
    $webClient.Proxy = $null
    $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $webClient.DownloadFile("http://192.168.69.1:8080/payload.bin", $downloadPath)
    } finally {
        $downloadTimer.Stop()
        $webClient.Dispose()
    }
    $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $downloadPath).Length -ne $transferBytes -or $downloadHash -ne $payloadSha256) {
        throw "AP HTTP 下行文件大小或 SHA256 不匹配"
    }
    $downloadMbps = [Math]::Round(($transferBytes * 8.0 / 1000000.0) / $downloadTimer.Elapsed.TotalSeconds, 2)

    Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "rm -f /run/zu02-ap-test/upload.bin /run/zu02-ap-test/nc.err; " +
        "nohup busybox nc -l -p 8081 >/run/zu02-ap-test/upload.bin 2>/run/zu02-ap-test/nc.err </dev/null &"
    ) | Out-Null
    Start-Sleep -Milliseconds 500
    $tcpClient = New-Object Net.Sockets.TcpClient
    $uploadTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $tcpClient.Connect("192.168.69.1", 8081)
        $networkStream = $tcpClient.GetStream()
        $fileStream = [IO.File]::OpenRead($downloadPath)
        try {
            $fileStream.CopyTo($networkStream, 65536)
            $networkStream.Flush()
        } finally {
            $fileStream.Dispose()
            $networkStream.Dispose()
        }
    } finally {
        $uploadTimer.Stop()
        $tcpClient.Dispose()
    }

    $uploadState = $null
    $uploadDeadline = (Get-Date).AddSeconds(30)
    do {
        $uploadState = Invoke-Adb @(
            "-s", $AdbSerial, "shell",
            "stat -c %s /run/zu02-ap-test/upload.bin 2>/dev/null; " +
            "busybox sha256sum /run/zu02-ap-test/upload.bin 2>/dev/null; cat /run/zu02-ap-test/nc.err 2>/dev/null"
        ) -AllowFailure
        if ($uploadState.Text -notmatch "(?m)^$transferBytes\s*$") { Start-Sleep -Milliseconds 500 }
    } while ($uploadState.Text -notmatch "(?m)^$transferBytes\s*$" -and (Get-Date) -lt $uploadDeadline)
    Write-Utf8File (Join-Path $OutputDir "upload-state.txt") ($uploadState.Text + "`r`n")
    if ($uploadState.Text -notmatch "(?m)^$transferBytes\s*$" -or
        $uploadState.Text -notmatch "(?im)^$payloadSha256\s+/run/zu02-ap-test/upload\.bin\s*$") {
        throw "AP TCP 上行文件大小或 SHA256 不匹配"
    }
    $uploadMbps = [Math]::Round(($transferBytes * 8.0 / 1000000.0) / $uploadTimer.Elapsed.TotalSeconds, 2)

    $stationDump = Invoke-Adb @("-s", $AdbSerial, "shell", "iw dev wlan0 station dump")
    Write-Utf8File (Join-Path $OutputDir "station-dump.txt") ($stationDump.Text + "`r`n")
    if ($stationDump.Text -notmatch "(?im)^Station $([regex]::Escape($HostMac)) \(on wlan0\)\s*$" -or
        $stationDump.Text -notmatch '(?im)^\s*authorized:\s+yes\s*$' -or
        $stationDump.Text -notmatch '(?im)^\s*authenticated:\s+yes\s*$' -or
        $stationDump.Text -notmatch '(?im)^\s*associated:\s+yes\s*$') {
        throw "设备端没有记录已授权、已认证、已关联的 Windows 客户端"
    }
} catch {
    $testError = $_
} finally {
    Invoke-Native "netsh.exe" @("wlan", "connect", "name=$OriginalProfile", "interface=$WindowsInterface") -AllowFailure | Out-Null
    $windowsRestored = Wait-WlanProfile $OriginalProfile $AssociationTimeoutSeconds
    Write-Utf8File (Join-Path $OutputDir "windows-restored.txt") (($windowsRestored | Out-String) + "`r`n")
    Invoke-Native "netsh.exe" @("wlan", "delete", "profile", "name=$Ssid", "interface=$WindowsInterface") -AllowFailure | Out-Null
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "if test -s /run/zu02-ap-test/httpd.pid; then " +
        "kill `$(cat /run/zu02-ap-test/httpd.pid) >/dev/null 2>&1 || true; fi; " +
        "busybox killall nc >/dev/null 2>&1 || true; " +
        "rm -rf /run/zu02-ap-test"
    ) -AllowFailure | Out-Null
    Invoke-Adb @(
        "-s", $AdbSerial, "shell",
        "nmcli connection down $ConnectionName >/dev/null 2>&1 || true; " +
        "nmcli connection delete $ConnectionName >/dev/null 2>&1 || true; nmcli radio wifi on"
    ) -AllowFailure | Out-Null
}

if ($testError) { throw $testError }
if (-not $windowsRestored) { throw "AP 测试成功，但 Windows 未恢复原 WLAN 配置 $OriginalProfile" }

$rescan = Invoke-Adb @("-s", $AdbSerial, "shell", "nmcli device wifi rescan ifname wlan0") -AllowFailure
Start-Sleep -Seconds $ScanWaitSeconds
$scan = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "nmcli -t --escape no -f BSSID,SSID,CHAN,SIGNAL,SECURITY device wifi list ifname wlan0"
)
Write-Utf8File (Join-Path $OutputDir "managed-rescan.txt") ($scan.Text + "`r`n")
$networks = @($scan.Text -split "`r?`n" | Where-Object { $_ -match '^[0-9A-Fa-f]{2}:' })
if ($networks.Count -eq 0) { throw "AP 清理后 managed 模式未恢复扫描能力" }

$finalState = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "nmcli -t -f NAME,TYPE,DEVICE connection show; iw dev wlan0 info; " +
    "printf REMOTEPROC_STATE=; cat /sys/class/remoteproc/remoteproc0/state; " +
    "printf FAILED_COUNT=; systemctl --failed --no-legend --plain | wc -l; ss -lntp; ps -ef"
)
Write-Utf8File (Join-Path $OutputDir "device-final-state.txt") ($finalState.Text + "`r`n")
if ($finalState.Text -match "(?m)^$([regex]::Escape($ConnectionName)):") {
    throw "临时 AP 连接未从设备删除"
}
if ($finalState.Text -match '(?im)192\.168\.69\.1:8080|busybox httpd') {
    throw "测试 HTTP 进程或 8080 监听未清理"
}
if ($finalState.Text -notmatch '(?m)^\s*type managed\s*$' -or
    $finalState.Text -notmatch '(?m)^REMOTEPROC_STATE=running\s*$' -or
    $finalState.Text -notmatch '(?m)^FAILED_COUNT=0\s*$') {
    throw "AP 清理后的设备状态异常，查看 device-final-state.txt"
}

$networkManagerJournal = Invoke-Adb @(
    "-s", $AdbSerial, "shell", "journalctl -u NetworkManager --no-pager"
)
$networkManagerLines = @($networkManagerJournal.Text -split "`r?`n")
$newNetworkManagerLines = @($networkManagerLines | Select-Object -Skip $networkManagerLineCountBefore)
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
    throw "AP 测试产生未知 NetworkManager error，查看 networkmanager-new.txt"
}

$kernelLog = Invoke-Adb @("-s", $AdbSerial, "shell", "dmesg")
$filteredKernelLog = ($kernelLog.Text -split "`r?`n" | Where-Object { $_ -match '(?i)remoteproc|wcnss|wcn36|firmware' }) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "kernel-wcnss.txt") ($filteredKernelLog + "`r`n")
$allKernelLines = @($kernelLog.Text -split "`r?`n")
$newKernelLines = @($allKernelLines | Select-Object -Skip $kernelLineCountBefore)
$newWcnssLines = @($newKernelLines | Where-Object { $_ -match '(?i)remoteproc|wcnss|wcn36|firmware' })
Write-Utf8File (Join-Path $OutputDir "kernel-wcnss-new.txt") (($newWcnssLines -join "`r`n") + "`r`n")

$cleanupWarnings = @($newWcnssLines | Where-Object {
    $_ -match '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7'
})
$fatalWcnssLines = @($newWcnssLines | Where-Object {
    ($_ -match '(?i)remoteproc.*\b(?:crash(?:ed)?|fatal|failed)\b') -or
    ($_ -match '(?i)(?:direct firmware load|request_firmware).*failed') -or
    ($_ -match '(?i)wcn36xx: ERROR' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7') -or
    ($_ -match '(?i)wcn36xx.*\b(?:crash(?:ed)?|fatal|failed)\b' -and
        $_ -notmatch '(?i)wcn36xx: ERROR hal_delete_sta_self response failed err=7')
})
if ($fatalWcnssLines.Count -gt 0) {
    throw "AP 测试产生新的 WCNSS 致命或未知错误，查看 kernel-wcnss-new.txt"
}

$bssidMatch = [regex]::Match($windowsAssociated, '(?im)^\s*AP BSSID\s*:\s*([0-9a-f:]+)\s*$')
$rateMatch = [regex]::Match($windowsAssociated, '(?im)^\s*Receive rate \(Mbps\)\s*:\s*([0-9.]+)\s*$')
$summary = @(
    "Debian Wi-Fi AP 实机验收通过"
    "ssid=$Ssid"
    "bssid=$($bssidMatch.Groups[1].Value.ToLowerInvariant())"
    "channel=$Channel"
    "security=WPA2-PSK-CCMP"
    "windows_client=$HostMac"
    "windows_dhcp_ip=$windowsClientIp"
    "windows_receive_rate_mbps=$($rateMatch.Groups[1].Value)"
    "transfer_bytes_each_direction=$transferBytes"
    "transfer_sha256=$payloadSha256"
    "http_download_mbps=$downloadMbps"
    "tcp_upload_mbps=$uploadMbps"
    "device_client_authorized=yes"
    "device_client_authenticated=yes"
    "device_client_associated=yes"
    "nonfatal_cleanup_warning_hal_delete_sta_self_err7=$($cleanupWarnings.Count)"
    "optional_nat_helper_warning_count=$($natHelperWarnings.Count)"
    "dnsmasq_pid_chown_warning_count=$($dnsmasqPidWarnings.Count)"
    "managed_scan_recovered_bss=$($networks.Count)"
    "temporary_profiles_and_processes_removed=yes"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
