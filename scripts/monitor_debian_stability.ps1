[CmdletBinding()]
param(
    [ValidateRange(5, 1440)]
    [int]$TargetUptimeMinutes = 30,
    [ValidateRange(10, 300)]
    [int]$ProbeIntervalSeconds = 60,
    [ValidateRange(200, 2000)]
    [int]$PingIntervalMilliseconds = 500,
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$OutputRoot = "",
    [string]$ProjectRoot = "",
    [switch]$AllowUnregisteredModem
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ProjectRoot) {
    $ProjectRoot = Join-Path $PSScriptRoot ".."
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$ActiveServices = "zu02-firewall zu02-usb-gadget adbd zu02-usb-watchdog.timer zu02-usb-network ssh dnsmasq NetworkManager serial-getty@ttyGS0.service zu02-wcnss qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register ufi210-modem-time-sync fstrim.timer"
$RestartTrackedServices = "zu02-firewall zu02-usb-gadget adbd zu02-usb-watchdog.service zu02-usb-network ssh dnsmasq NetworkManager serial-getty@ttyGS0.service zu02-wcnss qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register ufi210-modem-time-sync"
$ExpectedActiveServices = @($ActiveServices -split ' ').Count
$ExpectedRestartTrackedServices = @($RestartTrackedServices -split ' ').Count
$RequiredRootfsAvailableBytes = 32MB
$AllowedJournalBytes = 20MB
$ManifestPath = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs\BUILD-MANIFEST.txt"

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adbCommand) { $Adb = $adbCommand.Source }
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

function Wait-TcpAdb {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        $devices = Invoke-Adb @("devices", "-l")
        if ($devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 15 秒内恢复：$AdbSerial"
}

function Get-DebianUsbFingerprint {
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_18D1&PID_D001'
    } | Sort-Object InstanceId)
    if ($devices.Count -ne 3 -or
        @($devices | Where-Object Class -eq "Net").Count -ne 1 -or
        @($devices | Where-Object Class -eq "Ports").Count -ne 1 -or
        @($devices | Where-Object { $_.InstanceId -notmatch '&MI_[0-9A-F]{2}\\' }).Count -ne 1) {
        throw "Debian USB 复合设备不完整"
    }
    [string[]]$instanceIds = @($devices | ForEach-Object { $_.InstanceId })
    [Array]::Sort($instanceIds, [StringComparer]::OrdinalIgnoreCase)
    return ($instanceIds -join "`n")
}

function Get-RndisAdapter {
    $netDevice = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_18D1&PID_D001.*&MI_00'
    })
    if ($netDevice.Count -ne 1) { throw "未找到唯一的 Debian RNDIS PnP 设备" }
    $adapter = @(Get-NetAdapter -IncludeHidden | Where-Object {
        $_.InterfaceDescription -eq $netDevice[0].FriendlyName
    })
    if ($adapter.Count -ne 1) { throw "未找到唯一的 Debian RNDIS 网卡" }
    return $adapter[0]
}

function Test-TcpPort {
    param([int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($DeviceIp, $Port)
        if (-not $task.Wait(1000)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
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

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "缺少构建 manifest：$ManifestPath" }
$Manifest = @{}
foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
    if ($line -match '^([^=]+)=(.*)$') { $Manifest[$Matches[1]] = $Matches[2] }
}
$ExpectedRootfsBytes = $Manifest['dm_filesystem_bytes']
$ExpectedRootfsUuid = $Manifest['rootfs_uuid']
if ($Manifest['target_partition'] -ne 'large-rootfs' -or
    $Manifest['rootfs_device'] -ne '/dev/mapper/ufi210-root' -or
    $Manifest['target_partition_bytes'] -ne '3485240832' -or
    $ExpectedRootfsBytes -ne '3485237248' -or
    $ExpectedRootfsUuid -ne '89090000-0000-4000-8000-000000000031' -or
    $Manifest['rootfs_auto_grow'] -ne 'disabled' -or
    $Manifest['fstrim'] -ne 'weekly-systemd-timer') {
    throw "构建 manifest 的大根卷布局不匹配"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$testName = if ($AllowUnregisteredModem) { "stability-no-cellular" } else { "stability" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ($testName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-TcpAdb
$baselineFingerprint = Get-DebianUsbFingerprint
$baselineAdapter = Get-RndisAdapter
if ($baselineAdapter.Status -ne "Up" -or -not (Test-TcpPort 22)) {
    throw "稳定性测试前 RNDIS 或 SSH 不可用"
}
$bootId = (Invoke-Adb @("-s", $AdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id")).Text.Trim()
$baselineUptimeText = (Invoke-Adb @("-s", $AdbSerial, "shell", "cut -d. -f1 /proc/uptime")).Text.Trim()
$baselineUptimeSeconds = 0L
if (-not [int64]::TryParse($baselineUptimeText, [ref]$baselineUptimeSeconds)) {
    throw "无法解析监控起始 uptime：$baselineUptimeText"
}
$targetUptimeSeconds = $baselineUptimeSeconds + ($TargetUptimeMinutes * 60)
$serviceRestartCommand = @'
for service in __RESTART_SERVICES__; do
    value="$(systemctl show --property=NRestarts --value "$service")"
    printf 'SERVICE_RESTART=%s:%s\n' "$service" "$value"
done
'@
$serviceRestartCommand = $serviceRestartCommand.Replace('__RESTART_SERVICES__', $RestartTrackedServices)
$baselineServiceRestartText = (Invoke-Adb @("-s", $AdbSerial, "shell", $serviceRestartCommand)).Text
$baselineServiceRestarts = @{}
foreach ($match in [regex]::Matches($baselineServiceRestartText, '(?m)^SERVICE_RESTART=([^:\r\n]+):(\d+)\r?$')) {
    $baselineServiceRestarts[$match.Groups[1].Value] = [int64]$match.Groups[2].Value
}
if ($baselineServiceRestarts.Count -ne $ExpectedRestartTrackedServices) {
    throw "无法采集全部服务的初始重启计数：`r`n$baselineServiceRestartText"
}
$probeResults = New-Object 'Collections.Generic.List[string]'
$pingSamples = New-Object 'Collections.Generic.List[object]'
$maxTemperatureMillic = 0L
$minMemAvailableKb = [int64]::MaxValue
$minRootfsAvailableBytes = [int64]::MaxValue
$maxJournalBytes = 0L
$firstEmmcSectorsWritten = -1L
$lastEmmcSectorsWritten = -1L
$emmcLogicalBlockSize = 0L
$pingJob = Start-Job -ArgumentList $DeviceIp, $PingIntervalMilliseconds -ScriptBlock {
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

$probeCommand = @'
printf 'UPTIME='; cut -d. -f1 /proc/uptime
printf 'BOOT_ID='; cat /proc/sys/kernel/random/boot_id
printf 'STATE='; systemctl is-system-running
systemctl is-active __ACTIVE_SERVICES__
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
printf 'UDC='; cat /sys/kernel/config/usb_gadget/g1/UDC
printf 'TCP_ADB='; ss -lnt | grep -q ':5555 ' && echo listening
find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf 'FUNCTION=%f\n' | sort
for remoteproc in /sys/class/remoteproc/remoteproc*; do
    printf 'REMOTEPROC=%s:' "$(cat "$remoteproc/name")"
    cat "$remoteproc/state"
done
for service in __RESTART_SERVICES__; do
    value="$(systemctl show --property=NRestarts --value "$service")"
    printf 'SERVICE_RESTART=%s:%s\n' "$service" "$value"
done
registration_state="$(mmcli -m any --output-keyvalue | grep '^modem.3gpp.registration-state' | cut -d: -f2- | xargs)"
packet_state="$(mmcli -m any --output-keyvalue | grep '^modem.3gpp.packet-service-state' | cut -d: -f2- | xargs)"
printf 'MODEM_REG=%s\n' "$registration_state"
printf 'PACKET_STATE=%s\n' "$packet_state"
printf 'TEMP_MAX='; sort -nr /sys/class/thermal/thermal_zone*/temp | head -n 1
sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\).*/MEM_AVAILABLE_KB=\1/p' /proc/meminfo
printf 'ROOTFS_AVAILABLE_BYTES='; df -B1 --output=avail / | tail -n 1 | xargs
printf 'ROOT='; findmnt -nro SOURCE /
printf 'ROOT_UUID='; findmnt -nro UUID /
printf 'ROOT_OPTIONS='; findmnt -nro OPTIONS /
root_blocks=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block count:[[:space:]]*//p')
root_block_size=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
printf 'ROOT_FS_BYTES=%s\n' "$((root_blocks * root_block_size))"
if mountpoint -q /data; then echo 'DATA_MOUNTED=yes'; else echo 'DATA_MOUNTED=no'; fi
printf 'DM_BYTES='; blockdev --getsize64 /dev/mapper/ufi210-root
printf 'DM_LINES='; dmsetup table ufi210-root | wc -l
printf 'FSTRIM_ENABLED='; systemctl is-enabled fstrim.timer
printf 'JOURNAL_BYTES='; du -s -B1 /var/log/journal | cut -f1
printf 'EMMC_SECTORS_WRITTEN='; awk '{print $7}' /sys/block/mmcblk0/stat
printf 'EMMC_LOGICAL_BLOCK_SIZE='; cat /sys/block/mmcblk0/queue/logical_block_size
'@
$probeCommand = $probeCommand.Replace('__ACTIVE_SERVICES__', $ActiveServices)
$probeCommand = $probeCommand.Replace('__RESTART_SERVICES__', $RestartTrackedServices)

try {
    while ($true) {
        Start-Sleep -Seconds $ProbeIntervalSeconds
        Receive-PingSamples $pingJob $pingSamples
        Wait-TcpAdb
        $probe = Invoke-Adb @("-s", $AdbSerial, "shell", $probeCommand)
        $uptimeMatch = [regex]::Match($probe.Text, '(?m)^UPTIME=(\d+)\r?$')
        if (-not $uptimeMatch.Success) { throw "无法解析 Linux uptime：`r`n$($probe.Text)" }
        $uptimeSeconds = [int64]$uptimeMatch.Groups[1].Value
        $remoteprocMatches = @([regex]::Matches($probe.Text, '(?m)^REMOTEPROC=([^:\r\n]+):running\r?$'))
        $temperatureMatch = [regex]::Match($probe.Text, '(?m)^TEMP_MAX=(\d+)\r?$')
        $memoryMatch = [regex]::Match($probe.Text, '(?m)^MEM_AVAILABLE_KB=(\d+)\r?$')
        $rootfsMatch = [regex]::Match($probe.Text, '(?m)^ROOTFS_AVAILABLE_BYTES=(\d+)\r?$')
        $rootfsBytesMatch = [regex]::Match($probe.Text, '(?m)^ROOT_FS_BYTES=(\d+)\r?$')
        $journalMatch = [regex]::Match($probe.Text, '(?m)^JOURNAL_BYTES=(\d+)\r?$')
        $emmcSectorsMatch = [regex]::Match($probe.Text, '(?m)^EMMC_SECTORS_WRITTEN=(\d+)\r?$')
        $emmcBlockSizeMatch = [regex]::Match($probe.Text, '(?m)^EMMC_LOGICAL_BLOCK_SIZE=(\d+)\r?$')
        $modemRegistrationMatch = [regex]::Match($probe.Text, '(?m)^MODEM_REG=([^\r\n]*)\r?$')
        $packetStateMatch = [regex]::Match($probe.Text, '(?m)^PACKET_STATE=([^\r\n]*)\r?$')
        $serviceRestartMatches = @([regex]::Matches($probe.Text, '(?m)^SERVICE_RESTART=([^:\r\n]+):(\d+)\r?$'))
        if (-not $temperatureMatch.Success -or -not $memoryMatch.Success -or
            -not $rootfsMatch.Success -or -not $rootfsBytesMatch.Success -or
            -not $journalMatch.Success -or
            -not $emmcSectorsMatch.Success -or -not $emmcBlockSizeMatch.Success -or
            -not $modemRegistrationMatch.Success -or -not $packetStateMatch.Success -or
            $serviceRestartMatches.Count -ne $ExpectedRestartTrackedServices) {
            throw "无法解析 modem、温度、内存或存储状态：`r`n$($probe.Text)"
        }
        $temperatureMillic = [int64]$temperatureMatch.Groups[1].Value
        $memAvailableKb = [int64]$memoryMatch.Groups[1].Value
        $rootfsAvailableBytes = [int64]$rootfsMatch.Groups[1].Value
        $rootfsBytes = [int64]$rootfsBytesMatch.Groups[1].Value
        $journalBytes = [int64]$journalMatch.Groups[1].Value
        $lastEmmcSectorsWritten = [int64]$emmcSectorsMatch.Groups[1].Value
        $currentEmmcBlockSize = [int64]$emmcBlockSizeMatch.Groups[1].Value
        $modemRegistrationState = $modemRegistrationMatch.Groups[1].Value
        $packetState = $packetStateMatch.Groups[1].Value
        $modemRegistered = $modemRegistrationState -match '^(?:home|roaming)$' -and $packetState -eq 'attached'
        foreach ($match in $serviceRestartMatches) {
            $serviceName = $match.Groups[1].Value
            $restartCount = [int64]$match.Groups[2].Value
            if (-not $baselineServiceRestarts.ContainsKey($serviceName) -or
                $restartCount -ne $baselineServiceRestarts[$serviceName]) {
                throw "服务重启计数发生变化：$serviceName=$restartCount"
            }
        }
        if ($firstEmmcSectorsWritten -lt 0) { $firstEmmcSectorsWritten = $lastEmmcSectorsWritten }
        if ($emmcLogicalBlockSize -eq 0) { $emmcLogicalBlockSize = $currentEmmcBlockSize }
        $maxTemperatureMillic = [Math]::Max($maxTemperatureMillic, $temperatureMillic)
        $minMemAvailableKb = [Math]::Min($minMemAvailableKb, $memAvailableKb)
        $minRootfsAvailableBytes = [Math]::Min($minRootfsAvailableBytes, $rootfsAvailableBytes)
        $maxJournalBytes = [Math]::Max($maxJournalBytes, $journalBytes)
        if ($probe.Text -notmatch "(?m)^BOOT_ID=$([regex]::Escape($bootId))\r?$" -or
            $probe.Text -notmatch '(?m)^STATE=running\r?$' -or
            @([regex]::Matches($probe.Text, '(?m)^active\r?$')).Count -ne $ExpectedActiveServices -or
            $probe.Text -notmatch '(?m)^FAILED=0\r?$' -or
            $probe.Text -notmatch '(?m)^UDC=ci_hdrc\.0\r?$' -or
            $probe.Text -notmatch '(?m)^TCP_ADB=listening\r?$' -or
            $probe.Text -notmatch '(?m)^ROOT=/dev/mapper/ufi210-root\r?$' -or
            $probe.Text -notmatch "(?m)^ROOT_UUID=$([regex]::Escape($ExpectedRootfsUuid))\r?`$" -or
            $probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\brw\b' -or
            $probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\bnoatime\b' -or
            $probe.Text -notmatch '(?m)^DATA_MOUNTED=no\r?$' -or
            $probe.Text -notmatch '(?m)^DM_BYTES=3485240832\r?$' -or
            $probe.Text -notmatch '(?m)^DM_LINES=3\r?$' -or
            $probe.Text -notmatch '(?m)^FSTRIM_ENABLED=enabled\r?$' -or
            $probe.Text -notmatch '(?m)^FUNCTION=acm\.usb0\r?$' -or
            $probe.Text -notmatch '(?m)^FUNCTION=rndis\.usb0\r?$' -or
            $remoteprocMatches.Count -ne 2 -or
            $probe.Text -notmatch '(?m)^REMOTEPROC=a204000\.remoteproc:running\r?$' -or
            $probe.Text -notmatch '(?m)^REMOTEPROC=4080000\.remoteproc:running\r?$' -or
            (-not $AllowUnregisteredModem -and -not $modemRegistered) -or
            $temperatureMillic -gt 85000 -or
            $memAvailableKb -lt 32768 -or
            $rootfsAvailableBytes -lt $RequiredRootfsAvailableBytes -or
            $rootfsBytes -ne [int64]$ExpectedRootfsBytes -or
            $journalBytes -gt $AllowedJournalBytes -or
            $currentEmmcBlockSize -ne $emmcLogicalBlockSize -or
            $lastEmmcSectorsWritten -lt $firstEmmcSectorsWritten) {
            throw "Debian 稳定性探针不匹配：`r`n$($probe.Text)"
        }
        if ((Get-DebianUsbFingerprint) -ne $baselineFingerprint) {
            throw "USB PnP 实例发生变化"
        }
        $adapter = Get-NetAdapter -IncludeHidden -Name $baselineAdapter.Name -ErrorAction Stop
        if ($adapter.Status -ne "Up" -or
            $adapter.InterfaceGuid -ne $baselineAdapter.InterfaceGuid -or
            $adapter.ifIndex -ne $baselineAdapter.ifIndex -or
            $adapter.MacAddress -ne $baselineAdapter.MacAddress -or
            -not (Test-TcpPort 22)) {
            throw "RNDIS 网卡身份、状态或 SSH 发生变化"
        }
        $modemRegisteredText = $modemRegistered.ToString().ToLowerInvariant()
        $result = "time=$(Get-Date -Format o) uptime_seconds=$uptimeSeconds ping_samples=$($pingSamples.Count) remoteprocs=2 service_restart_changes=0 modem_registered=$modemRegisteredText temperature_millic=$temperatureMillic mem_available_kb=$memAvailableKb rootfs_available_bytes=$rootfsAvailableBytes journal_bytes=$journalBytes emmc_sectors_written=$lastEmmcSectorsWritten result=pass"
        $probeResults.Add($result)
        Write-Host $result
        if ($uptimeSeconds -ge $targetUptimeSeconds) { break }
    }
} finally {
    Stop-Job -Job $pingJob -ErrorAction SilentlyContinue
    $remaining = @(Receive-Job -Job $pingJob -ErrorAction SilentlyContinue)
    foreach ($sample in $remaining) { $pingSamples.Add($sample) }
    Remove-Job -Job $pingJob -Force -ErrorAction SilentlyContinue
    if ($pingSamples.Count -gt 0) {
        $pingSamples | Export-Csv -LiteralPath (Join-Path $OutputDir "ping-samples.csv") -NoTypeInformation -Encoding UTF8
    }
    if ($probeResults.Count -gt 0) {
        Write-Utf8File (Join-Path $OutputDir "probes.txt") (($probeResults -join "`r`n") + "`r`n")
    }
}

$finalProbe = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "uptime; free -m; systemctl --failed --no-pager; dmesg | grep -Ei 'kernel panic|watchdog|remoteproc.*(crash|fatal)|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error|ci_hdrc.*(error|fail)|usb.*(error|fail)' | tail -n 100"
)
Write-Utf8File (Join-Path $OutputDir "final-probe.txt") ($finalProbe.Text + "`r`n")
if ($finalProbe.Text -match '(?im)kernel panic|watchdog|remoteproc.*(crash|fatal)|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error|ci_hdrc.*(error|fail)|usb.*(error|fail)') {
    throw "连续运行终检发现内核错误，查看 $OutputDir\final-probe.txt"
}

$summary = @(
    "Debian 连续运行验收通过"
    "target_duration_minutes=$TargetUptimeMinutes"
    "starting_uptime_seconds=$baselineUptimeSeconds"
    "validated_duration_seconds=$($uptimeSeconds - $baselineUptimeSeconds)"
    "boot_id=$bootId"
    "ping_samples=$($pingSamples.Count)"
    "ping_failures=0"
    "usb_pnp_changed=false"
    "remoteproc_failures=0"
    "service_restart_changes=0"
    "modem_registration_required=$((-not $AllowUnregisteredModem).ToString().ToLowerInvariant())"
    "max_temperature_millic=$maxTemperatureMillic"
    "min_mem_available_kb=$minMemAvailableKb"
    "min_rootfs_available_bytes=$minRootfsAvailableBytes"
    "root=/dev/mapper/ufi210-root"
    "root_filesystem_bytes=$ExpectedRootfsBytes"
    "root_uuid=$ExpectedRootfsUuid"
    "data_mount=none"
    "fstrim_timer=enabled"
    "max_journal_bytes=$maxJournalBytes"
    "emmc_logical_block_size=$emmcLogicalBlockSize"
    "emmc_write_sectors_delta=$($lastEmmcSectorsWritten - $firstEmmcSectorsWritten)"
    "emmc_write_bytes_delta=$(($lastEmmcSectorsWritten - $firstEmmcSectorsWritten) * $emmcLogicalBlockSize)"
    "systemd_failed=0"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
