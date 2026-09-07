[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$DurationMinutes = 10,
    [ValidateRange(2, 60)]
    [int]$ProbeIntervalSeconds = 5,
    [ValidateRange(60000, 95000)]
    [int]$StopTemperatureMillic = 80000,
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Services = @(
    "zu02-firewall", "zu02-usb-gadget", "adbd", "zu02-usb-network", "ssh", "dnsmasq",
    "NetworkManager", "serial-getty@ttyGS0.service", "zu02-wcnss", "qrtr-ns", "rmtfs",
    "zu02-mpss", "zu02-modem-prepare", "ModemManager", "zu02-modem-register",
    "ufi210-modem-time-sync"
)

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

function Invoke-AdbShell {
    param([string]$Command, [switch]$AllowFailure)
    return Invoke-Adb @("-s", $AdbSerial, "shell", $Command) -AllowFailure:$AllowFailure
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

function Get-ServiceRestarts {
    $command = @'
for service in __SERVICES__; do
    printf 'SERVICE_RESTART=%s:' "$service"
    systemctl show --property=NRestarts --value "$service"
done
'@.Replace('__SERVICES__', ($Services -join " "))
    $result = Invoke-AdbShell $command
    $values = @{}
    foreach ($match in [regex]::Matches($result.Text, '(?m)^SERVICE_RESTART=([^:\r\n]+):(\d+)\r?$')) {
        $values[$match.Groups[1].Value] = [int64]$match.Groups[2].Value
    }
    if ($values.Count -ne $Services.Count) { throw "未获取全部服务重启计数" }
    return $values
}

function Test-RndisPing {
    $ping = New-Object Net.NetworkInformation.Ping
    try {
        return $ping.Send($DeviceIp, 1000).Status -eq [Net.NetworkInformation.IPStatus]::Success
    } finally {
        $ping.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("thermal-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-TcpAdb
$identity = Invoke-AdbShell @'
set -eu
test "$(cat /sys/devices/soc0/soc_id)" = 245
test "$(findmnt -nro SOURCE /)" = /dev/mapper/ufi210-root
for zone_type in cpu0-2-thermal cpu1-3-thermal; do
    zone=''
    for candidate in /sys/class/thermal/thermal_zone*; do
        test "$(cat "$candidate/type")" = "$zone_type" || continue
        test -z "$zone"
        zone="$candidate"
    done
    test -n "$zone"
    test "$(cat "$zone/trip_point_0_temp")" = 75000
    test "$(cat "$zone/trip_point_0_type")" = passive
    test "$(cat "$zone/trip_point_0_hyst")" = 3000
    test "$(cat "$zone/trip_point_1_temp")" = 100000
    test "$(cat "$zone/trip_point_1_type")" = critical
    test "$(cat "$zone/trip_point_1_hyst")" = 2000
done
echo IDENTITY_OK
'@
if ($identity.Text -notmatch '(?m)^IDENTITY_OK\r?$') { throw "设备身份或根分区不匹配" }
$bootId = (Invoke-AdbShell 'cat /proc/sys/kernel/random/boot_id').Text.Trim()
$baselineRestarts = Get-ServiceRestarts
$inventory = Invoke-AdbShell @'
for zone in /sys/class/thermal/thermal_zone*; do
    printf 'ZONE=%s TYPE=' "${zone##*/}"; cat "$zone/type"
    printf 'TEMP='; cat "$zone/temp"
    printf 'POLICY='; cat "$zone/policy"
    for trip in "$zone"/trip_point_*_temp; do
        test -e "$trip" || continue
        base=${trip%_temp}
        printf 'TRIP=%s TEMP=' "${base##*/}"; cat "$trip"
        printf 'TRIP_TYPE='; cat "${base}_type"
        printf 'TRIP_HYST='; cat "${base}_hyst"
    done
done
for cooling in /sys/class/thermal/cooling_device*; do
    printf 'COOLING=%s TYPE=' "${cooling##*/}"; cat "$cooling/type"
    printf 'CUR='; cat "$cooling/cur_state"
    printf 'MAX='; cat "$cooling/max_state"
done
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    printf 'CPUFREQ=%s DRIVER=' "${policy##*/}"; cat "$policy/scaling_driver"
    printf 'GOVERNOR='; cat "$policy/scaling_governor"
    printf 'MIN='; cat "$policy/scaling_min_freq"
    printf 'MAX='; cat "$policy/scaling_max_freq"
done
'@
Write-Utf8File (Join-Path $OutputDir "thermal-inventory.txt") ($inventory.Text + "`r`n")
if (@([regex]::Matches($inventory.Text, '(?m)^ZONE=')).Count -lt 5 -or
    $inventory.Text -notmatch '(?m)^COOLING=.*TYPE=cpufreq-cpu0\r?$' -or
    $inventory.Text -notmatch '(?m)^GOVERNOR=schedutil\r?$') {
    throw "thermal zone、CPU cooling 或 schedutil 配置不完整"
}

$durationSeconds = $DurationMinutes * 60
$loadScript = @'
#!/bin/sh
set -eu
duration="$1"
pids=""
cleanup() {
    trap - EXIT INT TERM
    test -z "$pids" || kill $pids 2>/dev/null || true
    test -z "$pids" || wait $pids 2>/dev/null || true
}
trap cleanup EXIT INT TERM
i=0
while [ "$i" -lt "$(nproc)" ]; do
    nice -n 10 sha256sum /dev/zero >/dev/null &
    pids="$pids $!"
    i=$((i + 1))
done
sleep "$duration"
'@
$localLoadScript = Join-Path ([IO.Path]::GetTempPath()) ("zu02-thermal-load-" + [guid]::NewGuid().ToString("N") + ".sh")
Write-Utf8File $localLoadScript $loadScript
$remoteLoadScript = "/run/zu02-thermal-load.sh"
$samples = New-Object 'Collections.Generic.List[object]'
$maxTemperature = 0L
$maxCoolingState = 0L
$startedAt = Get-Date

try {
    Invoke-Adb @("-s", $AdbSerial, "push", $localLoadScript, $remoteLoadScript) | Out-Null
    Invoke-AdbShell "chmod 0700 $remoteLoadScript"
    $runtimeLimit = $durationSeconds + 30
    $start = Invoke-AdbShell "systemd-run --unit=zu02-thermal-load --collect --property=RuntimeMaxSec=${runtimeLimit}s $remoteLoadScript $durationSeconds"
    Write-Utf8File (Join-Path $OutputDir "load-start.txt") ($start.Text + "`r`n")
    $deadline = $startedAt.AddSeconds($durationSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $ProbeIntervalSeconds
        if (-not (Test-RndisPing)) { throw "热测试期间 RNDIS ping 失败" }
        Wait-TcpAdb
        $probe = Invoke-AdbShell @'
printf 'BOOT_ID='; cat /proc/sys/kernel/random/boot_id
printf 'LOAD_STATE='; systemctl is-active zu02-thermal-load.service
printf 'LOAD_AVERAGE='; cut -d' ' -f1 /proc/loadavg
for zone in /sys/class/thermal/thermal_zone*; do
    printf 'TEMP=%s:' "$(cat "$zone/type")"; cat "$zone/temp"
done
for cooling in /sys/class/thermal/cooling_device*; do
    printf 'COOLING=%s:' "$(cat "$cooling/type")"; cat "$cooling/cur_state"
done
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    printf 'FREQ=%s:' "${policy##*/}"; cat "$policy/scaling_cur_freq"
done
'@
        $probeTime = Get-Date
        $loadActive = $probe.Text -match '(?m)^LOAD_STATE=active\r?$'
        $loadCompleted = $probeTime -ge $deadline -and $probe.Text -match '(?m)^LOAD_STATE=inactive\r?$'
        if ($probe.Text -notmatch "(?m)^BOOT_ID=$([regex]::Escape($bootId))\r?$" -or
            (-not $loadActive -and -not $loadCompleted)) {
            throw "热负载或 boot ID 异常：`r`n$($probe.Text)"
        }
        $temperatures = @([regex]::Matches($probe.Text, '(?m)^TEMP=([^:\r\n]+):(\d+)\r?$'))
        $coolingStates = @([regex]::Matches($probe.Text, '(?m)^COOLING=([^:\r\n]+):(\d+)\r?$'))
        if ($temperatures.Count -lt 5 -or $coolingStates.Count -lt 1) { throw "无法解析 thermal 探针" }
        $sampleMax = ($temperatures | ForEach-Object { [int64]$_.Groups[2].Value } | Measure-Object -Maximum).Maximum
        $sampleCooling = ($coolingStates | ForEach-Object { [int64]$_.Groups[2].Value } | Measure-Object -Maximum).Maximum
        $maxTemperature = [Math]::Max($maxTemperature, [int64]$sampleMax)
        $maxCoolingState = [Math]::Max($maxCoolingState, [int64]$sampleCooling)
        $loadAverage = [regex]::Match($probe.Text, '(?m)^LOAD_AVERAGE=([^\r\n]+)\r?$').Groups[1].Value
        $samples.Add([pscustomobject]@{
            Timestamp = Get-Date -Format o
            ElapsedSeconds = [int]($probeTime - $startedAt).TotalSeconds
            MaxTemperatureMillic = $sampleMax
            MaxCoolingState = $sampleCooling
            LoadAverage = $loadAverage
            Probe = ($probe.Text -replace "`r?`n", ";")
        })
        Write-Host "elapsed=$([int]($probeTime - $startedAt).TotalSeconds)s max_temperature_millic=$sampleMax cooling_state=$sampleCooling load_average=$loadAverage"
        if ([int64]$sampleMax -ge $StopTemperatureMillic) {
            throw "温度达到停止门槛：${sampleMax}mC >= ${StopTemperatureMillic}mC"
        }
        if ($loadCompleted) { break }
    }
} finally {
    Invoke-AdbShell 'systemctl stop zu02-thermal-load.service 2>/dev/null || true; systemctl reset-failed zu02-thermal-load.service 2>/dev/null || true; rm -f /run/zu02-thermal-load.sh' -AllowFailure | Out-Null
    Remove-Item -LiteralPath $localLoadScript -Force -ErrorAction SilentlyContinue
    if ($samples.Count -gt 0) {
        $samples | Export-Csv -LiteralPath (Join-Path $OutputDir "thermal-samples.csv") -NoTypeInformation -Encoding UTF8
    }
}

Start-Sleep -Seconds 2
$postRestarts = Get-ServiceRestarts
foreach ($service in $Services) {
    if ($postRestarts[$service] -ne $baselineRestarts[$service]) {
        throw "热测试期间服务重启计数变化：$service=$($postRestarts[$service])"
    }
}
$final = Invoke-AdbShell @'
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
for remoteproc in /sys/class/remoteproc/remoteproc*; do
    printf 'REMOTEPROC=%s:' "$(cat "$remoteproc/name")"; cat "$remoteproc/state"
done
dmesg | grep -Ei 'thermal.*(critical|shutdown)|kernel panic|watchdog|remoteproc.*(crash|fatal)|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error|ci_hdrc.*(error|fail)' | tail -n 100
'@
Write-Utf8File (Join-Path $OutputDir "final-probe.txt") ($final.Text + "`r`n")
if ($final.Text -notmatch '(?m)^FAILED=0\r?$' -or
    @([regex]::Matches($final.Text, '(?m)^REMOTEPROC=[^:\r\n]+:running\r?$')).Count -ne 2 -or
    $final.Text -match '(?im)thermal.*(critical|shutdown)|kernel panic|watchdog|remoteproc.*(crash|fatal)|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error|ci_hdrc.*(error|fail)') {
    throw "热测试终检失败：`r`n$($final.Text)"
}

$summary = @(
    "Debian 受控 CPU 热测试通过",
    "duration_minutes=$DurationMinutes", "stop_temperature_millic=$StopTemperatureMillic",
    "max_temperature_millic=$maxTemperature", "max_cooling_state=$maxCoolingState",
    "cooling_exercised=$((($maxCoolingState -gt 0).ToString().ToLowerInvariant()))",
    "ping_failures=0", "service_restart_changes=0", "remoteproc_failures=0",
    "systemd_failed=0", "claim=bounded-test-not-thermal-optimality-proof", "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
