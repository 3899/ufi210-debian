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
    [switch]$AllowCellularDataUsage,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$ConnectionName = "zu02-lte-routing-test"
$SharedName = "zu02-veth-shared-test"
$Namespace = "zu02-nat-client"
$HostInterface = "zu02-nat-host"
$PeerInterface = "zu02-nat-peer"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

if (-not $AllowCellularDataUsage) {
    throw "此脚本会建立蜂窝数据连接并产生流量；确认资费后显式传入 -AllowCellularDataUsage"
}

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

function Get-WlanIdentity {
    $text = (Invoke-Native "netsh.exe" @("wlan", "show", "interfaces") -AllowFailure).Text
    $ssid = [regex]::Match($text, '(?m)^\s*SSID\s*:\s*(.+?)\s*$').Groups[1].Value.Trim()
    $profile = [regex]::Match($text, '(?m)^\s*Profile\s*:\s*(.+?)\s*$').Groups[1].Value.Trim()
    return [pscustomobject]@{ Text = $text; Ssid = $ssid; Profile = $profile }
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if ([string]::IsNullOrEmpty($CarrierUsername) -ne [string]::IsNullOrEmpty($CarrierPassword)) {
    throw "运营商用户名和密码必须同时提供或同时省略"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("lte-routing-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
$deviceState = Invoke-Native $Adb @("-s", $AdbSerial, "get-state")
if ($deviceState.Text.Trim() -ne "device") { throw "TCP ADB 不可用：$AdbSerial" }

$preflight = Invoke-AdbShell @'
set -eu
systemctl is-active rmtfs zu02-mpss zu02-modem-prepare ModemManager NetworkManager zu02-firewall
command -v nft
command -v ip
nft list table inet zu02_firewall | grep -q 'wwan0'
nft list table inet zu02_firewall | grep -q 'drop'
mmcli -m any --output-keyvalue | grep '^modem.generic.state *: registered$'
mmcli -m any --output-keyvalue | grep '^modem.3gpp.packet-service-state *: attached$'
test "$(systemctl --failed --no-legend --plain | wc -l)" -eq 0
'@
Write-Utf8File (Join-Path $OutputDir "preflight.txt") ($preflight.Text + "`r`n")
if ($preflight.Text -notmatch '(?m)^/usr/sbin/nft\r?$') {
    throw "rootfs 未安装 nftables，拒绝把 shared profile 激活误判为路由可用"
}
$modemPreflight = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
$genericBearerStates = New-Object Collections.Generic.List[string]
foreach ($bearerIndex in @(Get-GenericBearerIndexes $modemPreflight)) {
    $status = (Invoke-AdbShell "mmcli --output-keyvalue --bearer=$bearerIndex | grep '^bearer.status.connected'").Text.Trim()
    $genericBearerStates.Add("bearer=$bearerIndex $status")
    if ($status -match ':\s*yes\s*$') {
        throw "modem 已存在已连接的 generic bearer：$bearerIndex；拒绝中断现有数据连接"
    }
}
Write-Utf8File (Join-Path $OutputDir "generic-bearers-before.txt") (($genericBearerStates.ToArray() -join "`r`n") + "`r`n")

$stale = Invoke-AdbShell "nmcli -t -f NAME connection show | grep -E '^($ConnectionName|$SharedName)`$'; ip netns list | grep -F '$Namespace'" -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($stale.Text)) {
    throw "检测到上次路由测试残留，请先人工核对：$($stale.Text)"
}

$windowsBefore = Get-WlanIdentity
Write-Utf8File (Join-Path $OutputDir "windows-wlan-before.txt") ($windowsBefore.Text + "`r`n")
$before = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-before.txt") ($before.Text + "`r`n")

$auth = ""
if ($CarrierUsername) { $auth = " gsm.username '$CarrierUsername' gsm.password '$CarrierPassword'" }
$remote = @"
set -eu
lte='$ConnectionName'
shared='$SharedName'
ns='$Namespace'
host='$HostInterface'
peer='$PeerInterface'
stage=initial-cleanup
cleanup() {
    nmcli --wait 15 connection down "`$shared" >/dev/null 2>&1 || true
    nmcli connection delete "`$shared" >/dev/null 2>&1 || true
    ip netns del "`$ns" >/dev/null 2>&1 || true
    ip link del "`$host" >/dev/null 2>&1 || true
    nmcli --wait 30 connection down "`$lte" >/dev/null 2>&1 || true
    nmcli connection delete "`$lte" >/dev/null 2>&1 || true
    ip address flush dev wwan0 >/dev/null 2>&1 || true
    ip link set wwan0 down >/dev/null 2>&1 || true
}
on_exit() {
    rc=`$?
    trap - EXIT
    if [ "`$rc" -ne 0 ]; then printf 'LTE_ROUTING_FAILED_STAGE=%s\n' "`$stage"; fi
    cleanup
    exit "`$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
cleanup

stage=lte-connection
nmcli connection add type gsm ifname '*' con-name "`$lte" apn '$Apn' connection.autoconnect no ipv4.method auto ipv6.method disabled$auth >/dev/null
ip link set wwan0 up
nmcli --wait $ConnectTimeoutSeconds connection up "`$lte" >/dev/null
sleep 2
dns=`$(awk '/^nameserver[[:space:]]/{print `$2; exit}' /run/NetworkManager/resolv.conf)
[ -n "`$dns" ]
ip -4 address show dev wwan0 | grep -q 'inet '
ip -4 route show dev wwan0 | grep -q '^default via '

stage=shared-profile
ip netns add "`$ns"
ip link add "`$host" type veth peer name "`$peer"
ip link set "`$peer" netns "`$ns"
nmcli connection add type ethernet ifname "`$host" con-name "`$shared" connection.autoconnect no ipv4.method shared ipv4.addresses 192.168.77.1/24 ipv6.method disabled >/dev/null
nmcli device set "`$host" managed yes
nmcli --wait 30 connection up "`$shared" >/dev/null

stage=namespace-client
ip netns exec "`$ns" ip link set lo up
ip netns exec "`$ns" ip link set "`$peer" up
ip netns exec "`$ns" ip address add 192.168.77.2/24 dev "`$peer"
ip netns exec "`$ns" ip route add default via 192.168.77.1
ip netns exec "`$ns" ping -c 2 -W 2 192.168.77.1 >/dev/null

stage=nftables
nft list ruleset | grep -q "nm-shared-`$host"
nft list ruleset | grep -q 'masquerade'
nft list ruleset | grep -q 'forward'
nft list chain inet zu02_firewall input | grep -q usb0
if ip netns exec "`$ns" busybox nc -w 2 192.168.77.1 22 </dev/null; then
    echo 'SSH was reachable from a non-USB downstream interface' >&2
    exit 1
fi
if ip netns exec "`$ns" busybox nc -w 2 192.168.77.1 5555 </dev/null; then
    echo 'TCP ADB was reachable from a non-USB downstream interface' >&2
    exit 1
fi
stage=downstream-public
ping_rc=1
tcp_rc=1
ip netns exec "`$ns" ping -c 3 -W 3 1.1.1.1 >/dev/null && ping_rc=0 || true
ip netns exec "`$ns" busybox nc -w 8 1.1.1.1 53 </dev/null && tcp_rc=0 || true
[ "`$ping_rc" -eq 0 ] || [ "`$tcp_rc" -eq 0 ]

stage=carrier-dns
carrier_dns_ok=0
attempt=1
while [ "`$attempt" -le 3 ]; do
    result=`$(ip netns exec "`$ns" busybox nslookup ipv4only.arpa "`$dns" 2>&1) || true
    if printf '%s\n' "`$result" | grep -q 'ipv4only.arpa' &&
       printf '%s\n' "`$result" | grep -Eq '^Address([[:space:]][0-9]+)?:[[:space:]]+192\.0\.0\.(170|171)`$'; then
        carrier_dns_ok=1
        break
    fi
    sleep 2
    attempt=`$((attempt + 1))
done
[ "`$carrier_dns_ok" -eq 1 ] || { printf '%s\n' "`$result" >&2; exit 1; }

stage=shared-dns
shared_dns_ok=0
attempt=1
while [ "`$attempt" -le 3 ]; do
    result=`$(ip netns exec "`$ns" busybox nslookup ipv4only.arpa 192.168.77.1 2>&1) || true
    if printf '%s\n' "`$result" | grep -q 'ipv4only.arpa' &&
       printf '%s\n' "`$result" | grep -Eq '^Address([[:space:]][0-9]+)?:[[:space:]]+192\.0\.0\.(170|171)`$'; then
        shared_dns_ok=1
        break
    fi
    sleep 2
    attempt=`$((attempt + 1))
done
[ "`$shared_dns_ok" -eq 1 ] || { printf '%s\n' "`$result" >&2; exit 1; }

printf 'LTE_ROUTING_NAMESPACE_OK\n'
printf 'routing_firewall=NetworkManager-nftables\n'
printf 'nft_masquerade=present\n'
printf 'management_ingress=usb-only-rndis-ssh-tcp-adb-acm\n'
printf 'non_usb_management=blocked\n'
printf 'wwan_ingress=drop-new-and-untracked\n'
printf 'downstream_public_connectivity=passed\n'
printf 'downstream_public_icmp=%s\n' "`$([ "`$ping_rc" -eq 0 ] && printf passed || printf blocked-or-failed)"
printf 'downstream_public_tcp=%s\n' "`$([ "`$tcp_rc" -eq 0 ] && printf passed || printf blocked-or-failed)"
printf 'carrier_dns_direct=passed\n'
printf 'shared_dns_proxy=passed\n'
printf 'windows_wifi=not-modified\n'
ip netns exec "`$ns" ip -s link show "`$peer"
"@

$testFailure = $null
try {
    $routing = Invoke-AdbShell $remote
    Write-Utf8File (Join-Path $OutputDir "routing.txt") ($routing.Text + "`r`n")
    if ($routing.Text -notmatch '(?m)^LTE_ROUTING_NAMESPACE_OK\r?$' -or
        $routing.Text -notmatch '(?m)^routing_firewall=NetworkManager-nftables\r?$' -or
        $routing.Text -notmatch '(?m)^nft_masquerade=present\r?$' -or
        $routing.Text -notmatch '(?m)^management_ingress=usb-only-rndis-ssh-tcp-adb-acm\r?$' -or
        $routing.Text -notmatch '(?m)^non_usb_management=blocked\r?$' -or
        $routing.Text -notmatch '(?m)^wwan_ingress=drop-new-and-untracked\r?$' -or
        $routing.Text -notmatch '(?m)^downstream_public_connectivity=passed\r?$' -or
        $routing.Text -notmatch '(?m)^carrier_dns_direct=passed\r?$' -or
        $routing.Text -notmatch '(?m)^shared_dns_proxy=passed\r?$') {
        throw "LTE namespace 路由结果缺少成功标记"
    }
} catch {
    $testFailure = $_.Exception.Message
    $diagnostic = Invoke-AdbShell "journalctl -b -u NetworkManager -u ModemManager --no-pager | tail -n 300; systemctl --failed --no-pager" -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "failure-diagnostic.txt") ($diagnostic.Text + "`r`n")
} finally {
    $after = Read-PartitionHashes
    Write-Utf8File (Join-Path $OutputDir "partition-hashes-after.txt") ($after.Text + "`r`n")
    foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
        if ($before.Values[$name] -ne $after.Values[$name]) {
            throw "LTE 路由测试期间敏感分区发生变化：${name}；立即停止后续测试"
        }
    }
}

$final = Invoke-AdbShell "nmcli -t -f NAME connection show; ip netns list; ip -brief link; printf FAILED_COUNT=; systemctl --failed --no-legend --plain | wc -l"
Write-Utf8File (Join-Path $OutputDir "final-state.txt") ($final.Text + "`r`n")
$connectionPattern = '(?m)^(' + [regex]::Escape($ConnectionName) + '|' + [regex]::Escape($SharedName) + '):'
$namespacePattern = '(?m)^' + [regex]::Escape($Namespace) + '\b'
$hostPattern = '(?m)^' + [regex]::Escape($HostInterface) + '\b'
$peerPattern = '(?m)^' + [regex]::Escape($PeerInterface) + '\b'
if (($final.Text -match $connectionPattern) -or
    ($final.Text -match $namespacePattern) -or
    ($final.Text -match $hostPattern) -or
    ($final.Text -match $peerPattern) -or
    ($final.Text -notmatch '(?m)^FAILED_COUNT=0\r?$')) {
    throw "路由测试临时资源未完全清理或 systemd 状态异常"
}

$windowsAfter = Get-WlanIdentity
Write-Utf8File (Join-Path $OutputDir "windows-wlan-after.txt") ($windowsAfter.Text + "`r`n")
if ($windowsBefore.Ssid -ne $windowsAfter.Ssid -or $windowsBefore.Profile -ne $windowsAfter.Profile) {
    throw "Windows Wi-Fi 身份发生变化；该测试按设计不应切换 Wi-Fi"
}
if ($testFailure) { throw "${testFailure}；临时资源已清理且敏感分区哈希保持不变；查看 $OutputDir" }

$summary = @(
    "Debian LTE nftables 路由验收通过"
    "management=USB RNDIS + TCP ADB only"
    "downstream=isolated-network-namespace-veth"
    "routing_firewall=NetworkManager-nftables"
    "nft_masquerade=present"
    "management_ingress=usb-only-rndis-ssh-tcp-adb-acm"
    "non_usb_management_ports=blocked"
    "wwan_ingress=drop-new-and-untracked"
    "downstream_public_connectivity=passed"
    "carrier_dns_resolution=passed-direct-from-downstream"
    "shared_dns_proxy=passed-from-downstream"
    "temporary_connections=deleted"
    "temporary_namespace=deleted"
    "windows_wifi=not-modified"
    "partition_hashes=unchanged-during-routing-test"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
