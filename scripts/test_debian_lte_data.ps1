[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$')]
    [string]$Apn,
    [ValidatePattern('^$|^[A-Za-z0-9@._-]{1,64}$')]
    [string]$CarrierUsername = "",
    [ValidatePattern('^$|^[A-Za-z0-9._-]{1,64}$')]
    [string]$CarrierPassword = "",
    [string]$AdbSerial = "192.168.68.1:5555",
    [ValidateRange(30, 300)]
    [int]$ConnectTimeoutSeconds = 120,
    [string]$ProbeAddress = "1.1.1.1",
    [ValidateRange(1, 65535)]
    [int]$ProbePort = 53,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$ConnectionName = "zu02-lte-test"
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

function Read-KeyValue {
    param([string]$Text, [string]$Key)
    $keyMatch = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))\s*:\s*(.*?)\s*$")
    if (-not $keyMatch.Success) { return $null }
    return $keyMatch.Groups[1].Value
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

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if ($ProbeAddress -notmatch '^[0-9A-Fa-f:.]+$') { throw "ProbeAddress 必须是 IP 地址" }
if ([string]::IsNullOrEmpty($CarrierUsername) -ne [string]::IsNullOrEmpty($CarrierPassword)) {
    throw "运营商用户名和密码必须同时提供或同时省略"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("lte-data-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$deviceState = Invoke-Native $Adb @("-s", $AdbSerial, "get-state")
if ($deviceState.Text.Trim() -ne "device") { throw "TCP ADB 不可用：$AdbSerial" }

$policy = Invoke-AdbShell @'
set -eu
systemctl is-active rmtfs zu02-mpss zu02-modem-prepare ModemManager NetworkManager
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
    throw "只读保护不符合要求，拒绝建立蜂窝数据连接；查看 $OutputDir\write-protection.txt"
}

$modemBefore = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
Write-Utf8File (Join-Path $OutputDir "modem-before-redacted.txt") ((Protect-Identifier $modemBefore) + "`r`n")
if ($modemBefore -notmatch '(?m)^modem\.generic\.state\s*:\s*registered\s*$' -or
    $modemBefore -notmatch '(?m)^modem\.3gpp\.packet-service-state\s*:\s*attached\s*$') {
    throw "modem 尚未注册并附着分组网络，请先运行 test_debian_lte_registration.ps1"
}

$bearersBefore = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
$bearerDetailsBefore = New-Object Collections.Generic.List[string]
foreach ($index in @(Get-GenericBearerIndexes $bearersBefore)) {
    $details = (Invoke-AdbShell "mmcli --output-keyvalue --bearer=$index").Text
    $bearerDetailsBefore.Add($details)
    if ($details -match '(?m)^bearer\.status\.connected\s*:\s*yes\s*$') {
        throw "modem 已存在已连接的 bearer，拒绝中断现有数据连接"
    }
}
Write-Utf8File (Join-Path $OutputDir "bearers-before-redacted.txt") ((Protect-Identifier (($bearerDetailsBefore.ToArray()) -join "`r`n")) + "`r`n")
$existingConnection = Invoke-AdbShell "nmcli -t -f NAME connection show | grep -Fx '$ConnectionName'" -AllowFailure
if ($existingConnection.ExitCode -eq 0) {
    throw "已存在同名 NetworkManager 连接：$ConnectionName；请先人工核对"
}

$windowsWlanBefore = (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces") -AllowFailure).Text
Write-Utf8File (Join-Path $OutputDir "windows-wlan-before.txt") ($windowsWlanBefore + "`r`n")
$before = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-before.txt") ($before.Text + "`r`n")
$testFailure = $null
$connectionCreated = $false
$pingSucceeded = $false
$tcpSucceeded = $false
$dnsSucceeded = $false
$manualNetworkConfig = $false
$networkManagerRuntimeConfig = $false
$networkManagerDispatcherConfig = $false
$manualGateway = $null
$wwanLinkRaised = $false
$currentStep = "create-connection"

try {
    $connectionCommand = "nmcli connection add type gsm ifname '*' con-name '$ConnectionName' apn '$Apn' connection.autoconnect no ipv4.method auto ipv6.method disabled"
    if ($CarrierUsername) {
        $connectionCommand += " gsm.username '$CarrierUsername' gsm.password '$CarrierPassword'"
    }
    $create = Invoke-AdbShell $connectionCommand
    $connectionCreated = $true
    Write-Utf8File (Join-Path $OutputDir "connection-create-redacted.txt") ((Protect-Identifier $create.Text) + "`r`n")

    $currentStep = "open-bam-dmux-netdev"
    Invoke-AdbShell 'ip link set wwan0 up' | Out-Null
    $wwanLinkRaised = $true

    $currentStep = "activate-connection"
    $up = Invoke-AdbShell "nmcli --wait $ConnectTimeoutSeconds connection up '$ConnectionName'" -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "connection-up-redacted.txt") ((Protect-Identifier $up.Text) + "`r`n")
    if ($up.ExitCode -ne 0) { throw "NetworkManager 建立蜂窝连接失败" }

    $currentStep = "find-connected-bearer"
    $modemWithBearers = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
    $bearerDetails = New-Object Collections.Generic.List[string]
    $connectedBearer = $null
    foreach ($bearerIndex in @(Get-GenericBearerIndexes $modemWithBearers)) {
        $currentStep = "read-bearer-$bearerIndex"
        $details = (Invoke-AdbShell "mmcli --output-keyvalue --bearer=$bearerIndex").Text
        $bearerDetails.Add($details)
        if ($details -match '(?m)^bearer\.status\.connected\s*:\s*yes\s*$') {
            $connectedBearer = $details
        }
    }
    Write-Utf8File (Join-Path $OutputDir "bearers-connected-redacted.txt") ((Protect-Identifier (($bearerDetails.ToArray()) -join "`r`n")) + "`r`n")
    if ($null -eq $connectedBearer) { throw "ModemManager 没有已连接的 bearer" }

    $wwanAddress = Read-KeyValue $connectedBearer 'bearer.ipv4-config.address'
    $wwanPrefixText = Read-KeyValue $connectedBearer 'bearer.ipv4-config.prefix'
    $wwanGateway = Read-KeyValue $connectedBearer 'bearer.ipv4-config.gateway'
    $wwanMtuText = Read-KeyValue $connectedBearer 'bearer.ipv4-config.mtu'
    $wwanDns = Read-KeyValue $connectedBearer 'bearer.ipv4-config.dns.value[1]'
    if (-not $wwanDns) { $wwanDns = Read-KeyValue $connectedBearer 'bearer.ipv4-config.dns' }

    $currentStep = "inspect-wwan-network"
    $networkCommand = @'
set -eu
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device
ip -4 address show dev wwan0
ip -4 route show dev wwan0
'@
    $network = Invoke-AdbShell $networkCommand
    if ($network.Text -notmatch '(?m)^wwan0qmi0:gsm:connected:') {
        throw "蜂窝连接未保持 connected 状态"
    }
    $networkReady = $false
    for ($dispatcherWait = 0; $dispatcherWait -le 10; $dispatcherWait++) {
        if ($network.Text -match '(?m)^\s*inet\s+[0-9]+(?:\.[0-9]+){3}/[0-9]+' -and
            $network.Text -match '(?m)^default via ') {
            $networkReady = $true
            break
        }
        if ($dispatcherWait -lt 10) {
            Start-Sleep -Seconds 1
            $network = Invoke-AdbShell $networkCommand
        }
    }
    Write-Utf8File (Join-Path $OutputDir "network.txt") ($network.Text + "`r`n")
    if ($networkReady) {
        $dispatcherProbe = Invoke-AdbShell 'test -x /etc/NetworkManager/dispatcher.d/90-zu02-wwan-ip' -AllowFailure
        $networkManagerDispatcherConfig = $dispatcherProbe.ExitCode -eq 0
    } else {
        $parsedAddress = $null
        $parsedGateway = $null
        $wwanPrefix = 0
        $wwanMtu = 0
        if (-not [Net.IPAddress]::TryParse($wwanAddress, [ref]$parsedAddress) -or
            $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            -not [Net.IPAddress]::TryParse($wwanGateway, [ref]$parsedGateway) -or
            $parsedGateway.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            -not [int]::TryParse($wwanPrefixText, [ref]$wwanPrefix) -or $wwanPrefix -lt 1 -or $wwanPrefix -gt 32 -or
            -not [int]::TryParse($wwanMtuText, [ref]$wwanMtu) -or $wwanMtu -lt 576 -or $wwanMtu -gt 2040) {
            throw "bearer 没有返回可验证的 IPv4 静态参数"
        }
        $currentStep = "apply-bearer-ipv4-via-networkmanager"
        $nmModify = Invoke-AdbShell "nmcli device modify wwan0qmi0 ipv4.method manual ipv4.addresses '$wwanAddress/$wwanPrefix' ipv4.gateway '$wwanGateway' ipv4.dns '$wwanDns'" -AllowFailure
        $nmReapply = Invoke-AdbShell 'nmcli device reapply wwan0qmi0' -AllowFailure
        Write-Utf8File (Join-Path $OutputDir "networkmanager-runtime-ipv4.txt") (($nmModify.Text + "`r`n" + $nmReapply.Text) + "`r`n")
        Start-Sleep -Seconds 1
        $network = Invoke-AdbShell 'ip -4 address show dev wwan0; ip -4 route show dev wwan0'
        if ($nmModify.ExitCode -eq 0 -and $nmReapply.ExitCode -eq 0 -and
            $network.Text -match '(?m)^\s*inet\s+[0-9]+(?:\.[0-9]+){3}/[0-9]+' -and
            $network.Text -match '(?m)^default via ') {
            $networkManagerRuntimeConfig = $true
        } else {
            $currentStep = "apply-bearer-ipv4-directly"
            Invoke-AdbShell "ip link set wwan0 mtu '$wwanMtu' up && ip address replace '$wwanAddress/$wwanPrefix' dev wwan0 && ip route replace '$wwanGateway/32' dev wwan0 && ip route replace default via '$wwanGateway' dev wwan0 metric 700" | Out-Null
            $manualNetworkConfig = $true
            $manualGateway = $wwanGateway
        }
        $network = Invoke-AdbShell 'ip -details link show wwan0; ip -4 address show dev wwan0; ip -4 route show dev wwan0'
        Write-Utf8File (Join-Path $OutputDir "network-after-bearer-ipv4.txt") ($network.Text + "`r`n")
        if ($network.Text -notmatch '(?m)^\s*inet\s+[0-9]+(?:\.[0-9]+){3}/[0-9]+' -or
            $network.Text -notmatch '(?m)^default via ') {
            throw "bearer IPv4 参数未能应用到 wwan0"
        }
    }

    $resolver = Invoke-AdbShell 'cat /run/NetworkManager/resolv.conf 2>/dev/null' -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "networkmanager-resolv.conf") ($resolver.Text + "`r`n")
    if ($networkManagerDispatcherConfig -and $wwanDns -and
        $resolver.Text -notmatch "(?m)^nameserver\s+$([regex]::Escape($wwanDns))\s*$") {
        throw "WWAN dispatcher 已配置 IPv4，但 NetworkManager 没有发布 bearer DNS"
    }

    $currentStep = "probe-public-network"
    $ping = Invoke-AdbShell "ping -I wwan0 -c 4 -W 5 '$ProbeAddress'" -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "ping.txt") ($ping.Text + "`r`n")
    $pingSucceeded = $ping.ExitCode -eq 0 -and $ping.Text -match '(?m)4 packets transmitted, [1-4] received'
    $tcp = Invoke-AdbShell "busybox nc -w 8 '$ProbeAddress' '$ProbePort' </dev/null" -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "tcp-probe.txt") ($tcp.Text + "`r`n")
    $tcpSucceeded = $tcp.ExitCode -eq 0
    $parsedDns = $null
    if ([Net.IPAddress]::TryParse($wwanDns, [ref]$parsedDns) -and
        $parsedDns.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $dns = Invoke-AdbShell "busybox nslookup debian.org '$wwanDns'" -AllowFailure
        Write-Utf8File (Join-Path $OutputDir "dns-probe.txt") ($dns.Text + "`r`n")
        $dnsSucceeded = $dns.ExitCode -eq 0 -and $dns.Text -match '(?m)^Address:\s+[0-9]+(?:\.[0-9]+){3}\s*$'
    }
    $linkStats = Invoke-AdbShell 'ip -s link show wwan0; cat /sys/class/net/wwan0/statistics/tx_packets /sys/class/net/wwan0/statistics/tx_bytes /sys/class/net/wwan0/statistics/rx_packets /sys/class/net/wwan0/statistics/rx_bytes'
    Write-Utf8File (Join-Path $OutputDir "wwan-stats-after-probes.txt") ($linkStats.Text + "`r`n")
    if (-not $pingSucceeded -and -not $tcpSucceeded -and -not $dnsSucceeded) { throw "wwan0 无法通过运营商 DNS 或公网探针" }
} catch {
    $testFailure = "阶段 $currentStep 失败：$($_.Exception.Message)"
    $diagnostic = Invoke-AdbShell 'nmcli device; mmcli -m any --output-keyvalue; journalctl -b -u NetworkManager -u ModemManager --no-pager | tail -n 300' -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "failure-diagnostic-redacted.txt") ((Protect-Identifier $diagnostic.Text) + "`r`n")
} finally {
    if ($manualNetworkConfig) {
        Invoke-AdbShell "ip route del default via '$manualGateway' dev wwan0 metric 700 2>/dev/null || true" -AllowFailure | Out-Null
    }
    if ($wwanLinkRaised) {
        Invoke-AdbShell 'ip address flush dev wwan0; ip link set wwan0 down' -AllowFailure | Out-Null
    }
    if ($connectionCreated) {
        $down = Invoke-AdbShell "nmcli --wait 30 connection down '$ConnectionName'" -AllowFailure
        $delete = Invoke-AdbShell "nmcli connection delete '$ConnectionName'" -AllowFailure
        Write-Utf8File (Join-Path $OutputDir "connection-cleanup.txt") (($down.Text + "`r`n" + $delete.Text) + "`r`n")
    }
    $remainingConnection = Invoke-AdbShell "nmcli -t -f NAME connection show | grep -Fx '$ConnectionName'" -AllowFailure
    if ($remainingConnection.ExitCode -eq 0) {
        throw "LTE 数据测试清理后仍存在 NetworkManager 连接：$ConnectionName"
    }
    $bearersAfterCleanup = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
    $bearerCleanupDetails = New-Object Collections.Generic.List[string]
    foreach ($bearerIndex in @(Get-GenericBearerIndexes $bearersAfterCleanup)) {
        $details = (Invoke-AdbShell "mmcli --output-keyvalue --bearer=$bearerIndex").Text
        $bearerCleanupDetails.Add($details)
        if ($details -match '(?m)^bearer\.status\.connected\s*:\s*yes\s*$') {
            throw "LTE 数据测试清理后仍存在已连接的 bearer：$bearerIndex"
        }
    }
    Write-Utf8File (Join-Path $OutputDir "bearers-after-cleanup-redacted.txt") ((Protect-Identifier (($bearerCleanupDetails.ToArray()) -join "`r`n")) + "`r`n")
    $after = Read-PartitionHashes
    Write-Utf8File (Join-Path $OutputDir "partition-hashes-after.txt") ($after.Text + "`r`n")
    foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
        if ($before.Values[$name] -ne $after.Values[$name]) {
            throw "LTE 数据测试期间敏感分区发生变化：$name；立即停止后续测试"
        }
    }
    $windowsWlanAfter = (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces") -AllowFailure).Text
    Write-Utf8File (Join-Path $OutputDir "windows-wlan-after.txt") ($windowsWlanAfter + "`r`n")
}

if ($null -ne $testFailure) {
    throw "$testFailure；临时连接已清理且敏感分区哈希保持不变；查看 $OutputDir"
}
if (-not $pingSucceeded -and -not $tcpSucceeded -and -not $dnsSucceeded) { throw "蜂窝公网探针未通过" }

$summary = @(
    "Debian LTE 数据链路验收通过"
    "management=USB RNDIS + TCP ADB only"
    "apn=explicitly-supplied"
    "carrier_authentication=$(if ($CarrierUsername) { 'explicitly-supplied' } else { 'not-supplied' })"
    "network_registration=registered"
    "packet_service=attached"
    "bearer=connected-then-disconnected-and-profile-removed"
    "ipv4=assigned"
    "ipv4_configuration=$(if ($networkManagerDispatcherConfig) { 'NetworkManager-dispatcher' } elseif ($networkManagerRuntimeConfig) { 'NetworkManager-runtime' } elseif ($manualNetworkConfig) { 'bearer-values-applied-directly' } else { 'NetworkManager-native' })"
    "public_probe=${ProbeAddress}:$ProbePort"
    "public_probe_icmp=$(if ($pingSucceeded) { 'passed' } else { 'blocked-or-failed' })"
    "public_probe_tcp=$(if ($tcpSucceeded) { 'passed' } else { 'blocked-or-failed' })"
    "carrier_dns_resolution=$(if ($dnsSucceeded) { 'passed' } else { 'failed' })"
    "public_connectivity=passed"
    "temporary_connection=deleted"
    "windows_wifi=not-modified"
    "partition_hashes=unchanged-during-data-test"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
