[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$')]
    [string]$Apn,
    [ValidatePattern('^$|^[A-Za-z0-9@._-]{1,64}$')]
    [string]$CarrierUsername = "",
    [ValidatePattern('^$|^[A-Za-z0-9._-]{1,64}$')]
    [string]$CarrierPassword = "",
    [ValidateRange(5, 1440)]
    [int]$TargetDurationMinutes = 480,
    [ValidateRange(10, 300)]
    [int]$ProbeIntervalSeconds = 60,
    [ValidateRange(30, 300)]
    [int]$ConnectTimeoutSeconds = 120,
    [ValidateRange(200, 5000)]
    [int]$ManagementPingIntervalMilliseconds = 1000,
    [string]$ProbeAddress = "1.1.1.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$DeviceIp = "192.168.68.1",
    [switch]$AllowCellularDataUsage,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$ConnectionName = "zu02-lte-stability"
$SharedName = "zu02-veth-stability"
$Namespace = "zu02-lte-client"
$HostInterface = "zu02-lte-host"
$PeerInterface = "zu02-lte-peer"
$CleanupUnit = "zu02-lte-stability-cleanup"
$CleanupScript = "/run/zu02-lte-stability-cleanup.sh"
$ModemStateFile = "/run/zu02-lte-stability-mmcli.txt"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Services = "zu02-firewall zu02-usb-gadget adbd zu02-usb-network ssh dnsmasq NetworkManager zu02-wcnss qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register ufi210-modem-time-sync serial-getty@ttyGS0.service"
$ExpectedActiveServices = 16

if (-not $AllowCellularDataUsage) {
    throw "此脚本会持续使用蜂窝数据流量；确认资费后显式传入 -AllowCellularDataUsage"
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adbCommand) { $Adb = $adbCommand.Source }
}

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Add-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::AppendAllText($Path, $Content, $Utf8NoBom)
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

function Wait-TcpAdb {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $state = Invoke-Native $Adb @("-s", $AdbSerial, "get-state") -AllowFailure
        if ($state.ExitCode -eq 0 -and $state.Text.Trim() -eq "device") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 15 秒内恢复：$AdbSerial"
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

function Receive-PingSamples {
    param($Job, [Collections.Generic.List[object]]$Store)
    $newSamples = @(Receive-Job -Job $Job)
    foreach ($sample in $newSamples) { $Store.Add($sample) }
    $failed = @($newSamples | Where-Object { -not $_.Success })
    if ($failed.Count -gt 0) {
        $first = $failed[0]
        throw "RNDIS ping 中断：$($first.Timestamp) status=$($first.Status)"
    }
}

function Invoke-DeviceCleanup {
    $cleanup = @'
set +e
systemctl stop __CLEANUP_UNIT__.timer >/dev/null 2>&1
nmcli --wait 15 connection down '__SHARED__' >/dev/null 2>&1
nmcli connection delete '__SHARED__' >/dev/null 2>&1
ip netns del '__NAMESPACE__' >/dev/null 2>&1
ip link del '__HOST__' >/dev/null 2>&1
nmcli --wait 30 connection down '__LTE__' >/dev/null 2>&1
nmcli connection delete '__LTE__' >/dev/null 2>&1
ip address flush dev wwan0 >/dev/null 2>&1
ip link set wwan0 down >/dev/null 2>&1
rm -f '__CLEANUP_SCRIPT__'
rm -f '__MODEM_STATE_FILE__'
systemctl reset-failed '__CLEANUP_UNIT__.service' >/dev/null 2>&1
systemctl reset-failed '__CLEANUP_UNIT__.timer' >/dev/null 2>&1
exit 0
'@
    $cleanup = $cleanup.Replace('__CLEANUP_UNIT__', $CleanupUnit)
    $cleanup = $cleanup.Replace('__SHARED__', $SharedName)
    $cleanup = $cleanup.Replace('__NAMESPACE__', $Namespace)
    $cleanup = $cleanup.Replace('__HOST__', $HostInterface)
    $cleanup = $cleanup.Replace('__LTE__', $ConnectionName)
    $cleanup = $cleanup.Replace('__CLEANUP_SCRIPT__', $CleanupScript)
    $cleanup = $cleanup.Replace('__MODEM_STATE_FILE__', $ModemStateFile)
    return Invoke-AdbShell $cleanup -AllowFailure
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if ($ProbeAddress -notmatch '^[0-9A-Fa-f:.]+$') { throw "ProbeAddress 必须是 IP 地址" }
if ([string]::IsNullOrEmpty($CarrierUsername) -ne [string]::IsNullOrEmpty($CarrierPassword)) {
    throw "运营商用户名和密码必须同时提供或同时省略"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("lte-stability-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$ProbeLog = Join-Path $OutputDir "probes.txt"

Wait-TcpAdb
$preflight = Invoke-AdbShell @'
set -eu
systemctl is-active rmtfs zu02-mpss zu02-modem-prepare ModemManager NetworkManager zu02-firewall zu02-wcnss
systemctl show rmtfs -p ExecStart --no-pager
findmnt -nro SOURCE,FSTYPE,OPTIONS /firmware
findmnt -nro SOURCE,FSTYPE,OPTIONS /persist
grep '^PARTLABEL=persist /persist ext4 ro,noload,' /etc/fstab
command -v nft
command -v systemd-run
command -v timeout
nft list table inet zu02_firewall | grep -q 'wwan0'
nft list table inet zu02_firewall | grep -q 'drop'
mmcli -m any --output-keyvalue | grep '^modem.generic.state *: registered$'
mmcli -m any --output-keyvalue | grep '^modem.3gpp.packet-service-state *: attached$'
test "$(systemctl --failed --no-legend --plain | wc -l)" -eq 0
'@
Write-Utf8File (Join-Path $OutputDir "preflight.txt") ($preflight.Text + "`r`n")
if ($preflight.Text -notmatch 'argv\[\]=/usr/bin/rmtfs -r -P -s' -or
    $preflight.Text -notmatch '(?m)^\S+\s+vfat\s+ro(?:,|$)' -or
    $preflight.Text -notmatch '(?m)^\S+\s+ext4\s+ro(?:,|$)' -or
    $preflight.Text -notmatch '(?m)^PARTLABEL=persist /persist ext4 ro,noload,' -or
    $preflight.Text -notmatch '(?m)^/usr/bin/systemd-run\r?$' -or
    $preflight.Text -notmatch '(?m)^/usr/bin/timeout\r?$') {
    throw "长期 LTE 测试的只读保护或工具预检失败；查看 $OutputDir\preflight.txt"
}

$modemPreflight = (Invoke-AdbShell 'mmcli -m any --output-keyvalue').Text
foreach ($bearerIndex in @(Get-GenericBearerIndexes $modemPreflight)) {
    $details = (Invoke-AdbShell "mmcli --output-keyvalue --bearer=$bearerIndex").Text
    if ($details -match '(?m)^bearer\.status\.connected\s*:\s*yes\s*$') {
        throw "modem 已存在已连接的 bearer：$bearerIndex；拒绝中断现有连接"
    }
}

$staleCommand = @'
nmcli -t -f NAME connection show | grep -E '^(__LTE__|__SHARED__)$'
ip netns list | grep -F '__NAMESPACE__'
if test -e '__CLEANUP_SCRIPT__'; then echo '__CLEANUP_SCRIPT__'; fi
'@
$staleCommand = $staleCommand.Replace('__LTE__', $ConnectionName)
$staleCommand = $staleCommand.Replace('__SHARED__', $SharedName)
$staleCommand = $staleCommand.Replace('__NAMESPACE__', $Namespace)
$staleCommand = $staleCommand.Replace('__CLEANUP_SCRIPT__', $CleanupScript)
$stale = Invoke-AdbShell $staleCommand -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($stale.Text)) {
    throw "检测到上次长期 LTE 测试残留，请先人工核对：$($stale.Text)"
}

$windowsBefore = Get-WlanIdentity
Write-Utf8File (Join-Path $OutputDir "windows-wlan-before.txt") ($windowsBefore.Text + "`r`n")
$before = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-before.txt") ($before.Text + "`r`n")
$bootId = (Invoke-AdbShell 'cat /proc/sys/kernel/random/boot_id').Text.Trim()
$dmesgBefore = (Invoke-AdbShell 'dmesg').Text
$dmesgLineCount = @($dmesgBefore -split "`r?`n").Count
$serviceRestartsBefore = (Invoke-AdbShell "systemctl show $Services -p Id -p NRestarts --no-pager").Text
Write-Utf8File (Join-Path $OutputDir "service-restarts-before.txt") ($serviceRestartsBefore + "`r`n")

$auth = ""
if ($CarrierUsername) { $auth = " gsm.username '$CarrierUsername' gsm.password '$CarrierPassword'" }
$leaseSeconds = ($TargetDurationMinutes * 60) + 900
$setupTemplate = @'
set -eu
lte='__LTE__'
shared='__SHARED__'
ns='__NAMESPACE__'
host='__HOST__'
peer='__PEER__'
cleanup_script='__CLEANUP_SCRIPT__'

cat > "$cleanup_script" <<'CLEANUP_EOF'
#!/bin/sh
set +e
nmcli --wait 15 connection down '__SHARED__' >/dev/null 2>&1
nmcli connection delete '__SHARED__' >/dev/null 2>&1
ip netns del '__NAMESPACE__' >/dev/null 2>&1
ip link del '__HOST__' >/dev/null 2>&1
nmcli --wait 30 connection down '__LTE__' >/dev/null 2>&1
nmcli connection delete '__LTE__' >/dev/null 2>&1
ip address flush dev wwan0 >/dev/null 2>&1
ip link set wwan0 down >/dev/null 2>&1
rm -f '__CLEANUP_SCRIPT__'
rm -f '__MODEM_STATE_FILE__'
exit 0
CLEANUP_EOF
chmod 0700 "$cleanup_script"
systemd-run --quiet --unit='__CLEANUP_UNIT__' --on-active='__LEASE_SECONDS__s' "$cleanup_script"

nmcli connection add type gsm ifname '*' con-name "$lte" apn '__APN__' connection.autoconnect no ipv4.method auto ipv6.method disabled__AUTH__ >/dev/null
ip link set wwan0 up
nmcli --wait __CONNECT_TIMEOUT__ connection up "$lte" >/dev/null
sleep 2
ip -4 address show dev wwan0 | grep -q 'inet '
ip -4 route show dev wwan0 | grep -q '^default via '

ip netns add "$ns"
ip link add "$host" type veth peer name "$peer"
ip link set "$peer" netns "$ns"
nmcli connection add type ethernet ifname "$host" con-name "$shared" connection.autoconnect no ipv4.method shared ipv4.addresses 192.168.77.1/24 ipv6.method disabled >/dev/null
nmcli device set "$host" managed yes
nmcli --wait 30 connection up "$shared" >/dev/null
ip netns exec "$ns" ip link set lo up
ip netns exec "$ns" ip link set "$peer" up
ip netns exec "$ns" ip address add 192.168.77.2/24 dev "$peer"
ip netns exec "$ns" ip route add default via 192.168.77.1
ip netns exec "$ns" ping -c 2 -W 2 192.168.77.1 >/dev/null
nft list ruleset | grep -q "nm-shared-$host"
nft list ruleset | grep -q 'masquerade'
if ip netns exec "$ns" busybox nc -w 2 192.168.77.1 22 </dev/null; then exit 1; fi
printf 'LTE_STABILITY_SETUP_OK\n'
'@
$setup = $setupTemplate.Replace('__LTE__', $ConnectionName)
$setup = $setup.Replace('__SHARED__', $SharedName)
$setup = $setup.Replace('__NAMESPACE__', $Namespace)
$setup = $setup.Replace('__HOST__', $HostInterface)
$setup = $setup.Replace('__PEER__', $PeerInterface)
$setup = $setup.Replace('__CLEANUP_SCRIPT__', $CleanupScript)
$setup = $setup.Replace('__MODEM_STATE_FILE__', $ModemStateFile)
$setup = $setup.Replace('__CLEANUP_UNIT__', $CleanupUnit)
$setup = $setup.Replace('__LEASE_SECONDS__', $leaseSeconds.ToString())
$setup = $setup.Replace('__APN__', $Apn)
$setup = $setup.Replace('__AUTH__', $auth)
$setup = $setup.Replace('__CONNECT_TIMEOUT__', $ConnectTimeoutSeconds.ToString())

$probeTemplate = @'
set -eu
printf 'UPTIME='; cut -d. -f1 /proc/uptime
printf 'BOOT_ID='; cat /proc/sys/kernel/random/boot_id
printf 'STATE='; systemctl is-system-running
systemctl is-active __SERVICES__
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
printf 'UDC='; cat /sys/kernel/config/usb_gadget/g1/UDC
find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf 'FUNCTION=%f\n' | sort
printf 'FUNCTION_COUNT='; find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l | wc -l
printf 'USB0_NM='; nmcli -t -f DEVICE,STATE device status | grep '^usb0:'
if ss -lnt | grep -q ':5555 '; then
    printf 'TCP_5555=present\n'
else
    printf 'TCP_5555=absent\n'
fi
for remoteproc in /sys/class/remoteproc/remoteproc*; do
    printf 'REMOTEPROC=%s:' "$(cat "$remoteproc/name")"
    cat "$remoteproc/state"
done
modem_file='__MODEM_STATE_FILE__'
rm -f "$modem_file"
modem_ok=0
for attempt in 1 2 3; do
    if mmcli -m any --output-keyvalue > "$modem_file"; then modem_ok=1; break; fi
    sleep 1
done
test "$modem_ok" -eq 1
test -s "$modem_file"
modem_state=$(sed -n 's/^modem\.generic\.state[[:space:]]*:[[:space:]]*//p' "$modem_file")
packet_state=$(sed -n 's/^modem\.3gpp\.packet-service-state[[:space:]]*:[[:space:]]*//p' "$modem_file")
printf 'MODEM_STATE=%s\n' "$modem_state"
printf 'PACKET_STATE=%s\n' "$packet_state"
case "$modem_state" in registered|connected) ;; *) exit 1 ;; esac
test "$packet_state" = attached
connected=0
connected_bearer=''
for bearer in $(grep '^modem.generic.bearers' "$modem_file" | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9][0-9]*'); do
    index=${bearer##*/}
    if mmcli --output-keyvalue --bearer="$index" | grep '^bearer.status.connected *: yes$' >/dev/null; then
        connected=$((connected + 1))
        connected_bearer=$index
    fi
done
printf 'CONNECTED_BEARERS=%s\n' "$connected"
test "$connected" -eq 1
mmcli --output-keyvalue --bearer="$connected_bearer" > "$modem_file"
bearer_rx=$(sed -n 's/^bearer\.stats\.bytes-rx[[:space:]]*:[[:space:]]*//p' "$modem_file")
bearer_tx=$(sed -n 's/^bearer\.stats\.bytes-tx[[:space:]]*:[[:space:]]*//p' "$modem_file")
rm -f "$modem_file"
case "$bearer_rx" in ''|--|*[!0-9]*) bearer_rx=-- ;; esac
case "$bearer_tx" in ''|--|*[!0-9]*) bearer_tx=-- ;; esac
nmcli -t -f NAME,TYPE,DEVICE connection show --active | grep '^__LTE__:gsm:wwan0qmi0$' >/dev/null
nmcli -t -f NAME,TYPE,DEVICE connection show --active | grep '^__SHARED__:802-3-ethernet:__HOST__$' >/dev/null
ip -4 address show dev wwan0 | grep -q 'inet '
ip -4 route show dev wwan0 | grep -q '^default via '
nft list ruleset | grep -q 'nm-shared-__HOST__'
nft list ruleset | grep -q 'masquerade'
dns=$(awk '/^nameserver[[:space:]]/{print $2; exit}' /run/NetworkManager/resolv.conf)
test -n "$dns"
public_icmp_ok=0
attempt=1
while [ "$attempt" -le 3 ]; do
    if timeout -k 2s 12s ip netns exec '__NAMESPACE__' ping -c 2 -W 5 '__PROBE_ADDRESS__' >/dev/null 2>&1; then
        public_icmp_ok=1
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done
test "$public_icmp_ok" -eq 1
printf 'PUBLIC_ICMP=passed\n'

public_tcp_ok=0
attempt=1
while [ "$attempt" -le 3 ]; do
    if timeout -k 2s 12s ip netns exec '__NAMESPACE__' busybox nc -w 8 '__PROBE_ADDRESS__' 53 </dev/null >/dev/null 2>&1; then
        public_tcp_ok=1
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done
test "$public_tcp_ok" -eq 1
printf 'PUBLIC_TCP=passed\n'

probe_dns() {
    server="$1"
    attempt=1
    while [ "$attempt" -le 3 ]; do
        lookup=$(timeout -k 2s 12s ip netns exec '__NAMESPACE__' busybox nslookup ipv4only.arpa "$server" 2>&1) || true
        if printf '%s\n' "$lookup" | grep -q 'ipv4only.arpa' &&
           printf '%s\n' "$lookup" | grep -Eq '^Address([[:space:]][0-9]+)?:[[:space:]]+192\.0\.0\.(170|171)$'; then
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    printf '%s\n' "$lookup" >&2
    return 1
}
probe_dns "$dns"
printf 'CARRIER_DNS=passed\n'
probe_dns 192.168.77.1
printf 'SHARED_DNS_PROXY=passed\n'
printf 'PUBLIC_CONNECTIVITY=passed\n'
printf 'TEMP_MAX='; sort -nr /sys/class/thermal/thermal_zone*/temp | head -n 1
sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\).*/MEM_AVAILABLE_KB=\1/p' /proc/meminfo
printf 'BEARER_TX_BYTES=%s\n' "$bearer_tx"
printf 'BEARER_RX_BYTES=%s\n' "$bearer_rx"
printf 'DOWNSTREAM_TX_BYTES='; cat /sys/class/net/__HOST__/statistics/tx_bytes
printf 'DOWNSTREAM_RX_BYTES='; cat /sys/class/net/__HOST__/statistics/rx_bytes
'@
$probeCommand = $probeTemplate.Replace('__SERVICES__', $Services)
$probeCommand = $probeCommand.Replace('__LTE__', $ConnectionName)
$probeCommand = $probeCommand.Replace('__SHARED__', $SharedName)
$probeCommand = $probeCommand.Replace('__HOST__', $HostInterface)
$probeCommand = $probeCommand.Replace('__NAMESPACE__', $Namespace)
$probeCommand = $probeCommand.Replace('__PROBE_ADDRESS__', $ProbeAddress)
$probeCommand = $probeCommand.Replace('__MODEM_STATE_FILE__', $ModemStateFile)

$pingSamples = New-Object 'Collections.Generic.List[object]'
$pingJob = $null
$testFailure = $null
$setupComplete = $false
$probeCount = 0
$maxTemperatureMillic = 0L
$minMemAvailableKb = [int64]::MaxValue
$firstBearerTxBytes = -1L
$firstBearerRxBytes = -1L
$lastBearerTxBytes = -1L
$lastBearerRxBytes = -1L
$firstDownstreamTxBytes = -1L
$firstDownstreamRxBytes = -1L
$lastDownstreamTxBytes = -1L
$lastDownstreamRxBytes = -1L
$startedAt = Get-Date
$deadline = $startedAt.AddMinutes($TargetDurationMinutes)

try {
    $setupResult = Invoke-AdbShell $setup
    Write-Utf8File (Join-Path $OutputDir "setup.txt") ($setupResult.Text + "`r`n")
    if ($setupResult.Text -notmatch '(?m)^LTE_STABILITY_SETUP_OK\r?$') {
        throw "长期 LTE 测试环境没有返回成功标记"
    }
    $setupComplete = $true

    $pingJob = Start-Job -ArgumentList $DeviceIp, $ManagementPingIntervalMilliseconds -ScriptBlock {
        param($Address, $IntervalMilliseconds)
        while ($true) {
            $ping = New-Object Net.NetworkInformation.Ping
            try {
                $reply = $ping.Send($Address, 1000)
                [pscustomobject]@{
                    Timestamp = (Get-Date -Format o)
                    Success = ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success)
                    Status = $reply.Status.ToString()
                    RoundtripTime = $reply.RoundtripTime
                }
            } catch {
                [pscustomobject]@{
                    Timestamp = (Get-Date -Format o)
                    Success = $false
                    Status = $_.Exception.Message
                    RoundtripTime = -1
                }
            } finally {
                $ping.Dispose()
            }
            Start-Sleep -Milliseconds $IntervalMilliseconds
        }
    }

    while ($true) {
        Wait-TcpAdb
        Receive-PingSamples $pingJob $pingSamples
        $probe = Invoke-AdbShell $probeCommand
        $probeCount++
        $uptimeMatch = [regex]::Match($probe.Text, '(?m)^UPTIME=(\d+)\r?$')
        $temperatureMatch = [regex]::Match($probe.Text, '(?m)^TEMP_MAX=(\d+)\r?$')
        $memoryMatch = [regex]::Match($probe.Text, '(?m)^MEM_AVAILABLE_KB=(\d+)\r?$')
        $txMatch = [regex]::Match($probe.Text, '(?m)^BEARER_TX_BYTES=(\d+|--)\r?$')
        $rxMatch = [regex]::Match($probe.Text, '(?m)^BEARER_RX_BYTES=(\d+|--)\r?$')
        $downstreamTxMatch = [regex]::Match($probe.Text, '(?m)^DOWNSTREAM_TX_BYTES=(\d+)\r?$')
        $downstreamRxMatch = [regex]::Match($probe.Text, '(?m)^DOWNSTREAM_RX_BYTES=(\d+)\r?$')
        $remoteprocMatches = @([regex]::Matches($probe.Text, '(?m)^REMOTEPROC=([^:\r\n]+):running\r?$'))
        if (-not $uptimeMatch.Success -or -not $temperatureMatch.Success -or
            -not $memoryMatch.Success -or -not $txMatch.Success -or -not $rxMatch.Success -or
            -not $downstreamTxMatch.Success -or -not $downstreamRxMatch.Success) {
            throw "无法解析长期 LTE 探针：`r`n$($probe.Text)"
        }
        $temperatureMillic = [int64]$temperatureMatch.Groups[1].Value
        $memAvailableKb = [int64]$memoryMatch.Groups[1].Value
        $bearerTxText = $txMatch.Groups[1].Value
        $bearerRxText = $rxMatch.Groups[1].Value
        if ($bearerTxText -ne "--") { $lastBearerTxBytes = [int64]$bearerTxText }
        if ($bearerRxText -ne "--") { $lastBearerRxBytes = [int64]$bearerRxText }
        $lastDownstreamTxBytes = [int64]$downstreamTxMatch.Groups[1].Value
        $lastDownstreamRxBytes = [int64]$downstreamRxMatch.Groups[1].Value
        if ($firstBearerTxBytes -lt 0) { $firstBearerTxBytes = $lastBearerTxBytes }
        if ($firstBearerRxBytes -lt 0) { $firstBearerRxBytes = $lastBearerRxBytes }
        if ($firstDownstreamTxBytes -lt 0) { $firstDownstreamTxBytes = $lastDownstreamTxBytes }
        if ($firstDownstreamRxBytes -lt 0) { $firstDownstreamRxBytes = $lastDownstreamRxBytes }
        $maxTemperatureMillic = [Math]::Max($maxTemperatureMillic, $temperatureMillic)
        $minMemAvailableKb = [Math]::Min($minMemAvailableKb, $memAvailableKb)
        if ($probe.Text -notmatch "(?m)^BOOT_ID=$([regex]::Escape($bootId))\r?$" -or
            $probe.Text -notmatch '(?m)^STATE=running\r?$' -or
            @([regex]::Matches($probe.Text, '(?m)^active\r?$')).Count -ne $ExpectedActiveServices -or
            $probe.Text -notmatch '(?m)^FAILED=0\r?$' -or
            $probe.Text -notmatch '(?m)^UDC=ci_hdrc\.0\r?$' -or
            $probe.Text -notmatch '(?m)^FUNCTION=acm\.usb0\r?$' -or
            $probe.Text -notmatch '(?m)^FUNCTION=rndis\.usb0\r?$' -or
            $probe.Text -notmatch '(?m)^FUNCTION_COUNT=2\r?$' -or
            $probe.Text -notmatch '(?m)^USB0_NM=usb0:unmanaged\r?$' -or
            $probe.Text -notmatch '(?m)^TCP_5555=present\r?$' -or
            $remoteprocMatches.Count -ne 2 -or
            $probe.Text -notmatch '(?m)^REMOTEPROC=a204000\.remoteproc:running\r?$' -or
            $probe.Text -notmatch '(?m)^REMOTEPROC=4080000\.remoteproc:running\r?$' -or
            $probe.Text -notmatch '(?m)^MODEM_STATE=(?:registered|connected)\r?$' -or
            $probe.Text -notmatch '(?m)^PACKET_STATE=attached\r?$' -or
            $probe.Text -notmatch '(?m)^CONNECTED_BEARERS=1\r?$' -or
            $probe.Text -notmatch '(?m)^PUBLIC_ICMP=passed\r?$' -or
            $probe.Text -notmatch '(?m)^PUBLIC_TCP=passed\r?$' -or
            $probe.Text -notmatch '(?m)^CARRIER_DNS=passed\r?$' -or
            $probe.Text -notmatch '(?m)^SHARED_DNS_PROXY=passed\r?$' -or
            $probe.Text -notmatch '(?m)^PUBLIC_CONNECTIVITY=passed\r?$' -or
            $temperatureMillic -gt 85000 -or $memAvailableKb -lt 32768) {
            throw "长期 LTE 探针不匹配：`r`n$($probe.Text)"
        }

        $dmesgNow = (Invoke-AdbShell 'dmesg').Text
        $dmesgLines = @($dmesgNow -split "`r?`n")
        if ($dmesgLines.Count -lt $dmesgLineCount) { throw "内核日志环形缓冲区发生回卷，无法证明期间无错误" }
        $newKernelLines = @($dmesgLines | Select-Object -Skip $dmesgLineCount)
        $dmesgLineCount = $dmesgLines.Count
        $kernelErrors = @($newKernelLines | Where-Object {
            $_ -match '(?i)kernel panic|watchdog|remoteproc.*(?:crash|fatal)|smd_dsm_memcpy|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error'
        })
        if ($kernelErrors.Count -gt 0) {
            Write-Utf8File (Join-Path $OutputDir "kernel-errors.txt") (($kernelErrors -join "`r`n") + "`r`n")
            throw "检测到新的内核、remoteproc、OOM 或存储错误"
        }

        $line = "time=$(Get-Date -Format o) uptime_seconds=$($uptimeMatch.Groups[1].Value) probe=$probeCount ping_samples=$($pingSamples.Count) bearer=connected nat=passed temperature_millic=$temperatureMillic mem_available_kb=$memAvailableKb bearer_tx_bytes=$bearerTxText bearer_rx_bytes=$bearerRxText downstream_tx_bytes=$lastDownstreamTxBytes downstream_rx_bytes=$lastDownstreamRxBytes result=pass"
        Add-Utf8File $ProbeLog ($line + "`r`n")
        Write-Host $line
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $ProbeIntervalSeconds
    }
} catch {
    $testFailure = $_.Exception.Message
    $diagnostic = Invoke-AdbShell "systemctl --failed --no-pager; systemctl status ModemManager NetworkManager zu02-mpss zu02-wcnss --no-pager; journalctl -b -u ModemManager -u NetworkManager -u zu02-mpss -u zu02-wcnss --no-pager | tail -n 500" -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "failure-diagnostic.txt") ($diagnostic.Text + "`r`n")
} finally {
    if ($pingJob) {
        Stop-Job -Job $pingJob -ErrorAction SilentlyContinue
        $remaining = @(Receive-Job -Job $pingJob -ErrorAction SilentlyContinue)
        foreach ($sample in $remaining) { $pingSamples.Add($sample) }
        Remove-Job -Job $pingJob -Force -ErrorAction SilentlyContinue
    }
    if ($pingSamples.Count -gt 0) {
        $pingSamples | Export-Csv -LiteralPath (Join-Path $OutputDir "management-ping-samples.csv") -NoTypeInformation -Encoding UTF8
    }
    if ($setupComplete) {
        $cleanup = Invoke-DeviceCleanup
        Write-Utf8File (Join-Path $OutputDir "cleanup.txt") ($cleanup.Text + "`r`n")
        if ($cleanup.ExitCode -ne 0 -and -not $testFailure) { $testFailure = "设备端临时资源清理失败" }
    }
}

Wait-TcpAdb
$after = Read-PartitionHashes
Write-Utf8File (Join-Path $OutputDir "partition-hashes-after.txt") ($after.Text + "`r`n")
foreach ($name in @("modem", "modemst1", "modemst2", "fsg", "persist")) {
    if ($before.Values[$name] -ne $after.Values[$name]) {
        throw "长期 LTE 测试期间敏感分区发生变化：${name}；立即停止后续测试"
    }
}

$windowsAfter = Get-WlanIdentity
Write-Utf8File (Join-Path $OutputDir "windows-wlan-after.txt") ($windowsAfter.Text + "`r`n")
if ($windowsBefore.Ssid -ne $windowsAfter.Ssid -or $windowsBefore.Profile -ne $windowsAfter.Profile) {
    throw "Windows Wi-Fi 身份发生变化；该测试按设计不应切换 Wi-Fi"
}

$serviceRestartsAfter = (Invoke-AdbShell "systemctl show $Services -p Id -p NRestarts --no-pager").Text
Write-Utf8File (Join-Path $OutputDir "service-restarts-after.txt") ($serviceRestartsAfter + "`r`n")
if ($serviceRestartsBefore -ne $serviceRestartsAfter) {
    throw "长期 LTE 测试期间服务重启计数发生变化；查看 service-restarts-*.txt"
}

$final = Invoke-AdbShell "nmcli -t -f NAME connection show; ip netns list; ip -brief link; printf FAILED_COUNT=; systemctl --failed --no-legend --plain | wc -l"
Write-Utf8File (Join-Path $OutputDir "final-state.txt") ($final.Text + "`r`n")
$connectionPattern = '(?m)^(' + [regex]::Escape($ConnectionName) + '|' + [regex]::Escape($SharedName) + '):'
if ($final.Text -match $connectionPattern -or
    $final.Text -match ('(?m)^' + [regex]::Escape($Namespace) + '\b') -or
    $final.Text -match ('(?m)^' + [regex]::Escape($HostInterface) + '\b') -or
    $final.Text -notmatch '(?m)^FAILED_COUNT=0\r?$') {
    throw "长期 LTE 测试临时资源未完全清理或 systemd 状态异常"
}
if ($testFailure) { throw "${testFailure}；临时资源已清理且敏感分区哈希保持不变；查看 $OutputDir" }
if ($probeCount -lt 2 -or
    $firstBearerTxBytes -lt 0 -or $firstBearerRxBytes -lt 0 -or
    $lastBearerTxBytes -le $firstBearerTxBytes -or $lastBearerRxBytes -le $firstBearerRxBytes -or
    $lastDownstreamTxBytes -le $firstDownstreamTxBytes -or $lastDownstreamRxBytes -le $firstDownstreamRxBytes) {
    throw "长期 LTE 测试没有形成可验证的双向 WWAN 流量增长"
}

$validatedSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
$summary = @(
    "Debian LTE 持续联网与 NAT 稳定性验收通过"
    "target_duration_minutes=$TargetDurationMinutes"
    "validated_duration_seconds=$validatedSeconds"
    "management=USB RNDIS + TCP ADB only"
    "windows_wifi_switched=no"
    "apn=explicitly-supplied-not-recorded"
    "bearer=continuously-connected"
    "downstream=isolated-network-namespace-veth"
    "routing_firewall=NetworkManager-nftables"
    "public_connectivity_probes=$probeCount"
    "public_icmp_probes=$probeCount"
    "public_tcp_probes=$probeCount"
    "carrier_dns_probes=$probeCount"
    "shared_dns_proxy_probes=$probeCount"
    "management_ping_samples=$($pingSamples.Count)"
    "management_ping_failures=0"
    "bearer_tx_growth_bytes=$($lastBearerTxBytes - $firstBearerTxBytes)"
    "bearer_rx_growth_bytes=$($lastBearerRxBytes - $firstBearerRxBytes)"
    "downstream_tx_growth_bytes=$($lastDownstreamTxBytes - $firstDownstreamTxBytes)"
    "downstream_rx_growth_bytes=$($lastDownstreamRxBytes - $firstDownstreamRxBytes)"
    "remoteproc_failures=0"
    "service_restarts=0"
    "systemd_failed=0"
    "max_temperature_millic=$maxTemperatureMillic"
    "min_mem_available_kb=$minMemAvailableKb"
    "partition_hashes=unchanged"
    "temporary_resources=deleted"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
