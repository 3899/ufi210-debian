[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$Cycles = 20,
    [ValidateRange(100, 1000)]
    [int]$SampleIntervalMilliseconds = 200,
    [ValidateRange(2, 15)]
    [int]$ObservationSeconds = 5,
    [string]$DeviceIp = "192.168.68.1",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$TcpSerial = "${DeviceIp}:5555"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

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

function Get-DebianUsbDevices {
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_18D1&PID_D001'
    } | Sort-Object InstanceId)
}

function Get-UsbFingerprint {
    $devices = Get-DebianUsbDevices
    if ($devices.Count -ne 3 -or
        @($devices | Where-Object Class -eq "Net").Count -ne 1 -or
        @($devices | Where-Object Class -eq "Ports").Count -ne 1 -or
        @($devices | Where-Object { $_.InstanceId -notmatch '&MI_[0-9A-F]{2}\\' }).Count -ne 1) {
        throw "Debian USB 复合设备不完整：期望父设备、RNDIS 和 ACM 各一个，实际为 $($devices.Count) 个"
    }
    [string[]]$instanceIds = @($devices | ForEach-Object { $_.InstanceId })
    [Array]::Sort($instanceIds, [StringComparer]::OrdinalIgnoreCase)
    return ($instanceIds -join "`n")
}

function Get-RndisAdapter {
    $netDevice = @(Get-DebianUsbDevices | Where-Object Class -eq "Net")
    if ($netDevice.Count -ne 1) { throw "未找到唯一的 Debian RNDIS PnP 设备" }
    $adapter = @(Get-NetAdapter -IncludeHidden | Where-Object {
        $_.InterfaceDescription -eq $netDevice[0].FriendlyName
    })
    if ($adapter.Count -ne 1) { throw "未找到唯一的 Debian RNDIS 网卡" }
    return $adapter[0]
}

function Test-DevicePing {
    $ping = New-Object Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($DeviceIp, 500)
        return $reply.Status -eq [Net.NetworkInformation.IPStatus]::Success
    } catch {
        return $false
    } finally {
        $ping.Dispose()
    }
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

function Wait-TcpAdb {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Invoke-Adb @("connect", $TcpSerial) -AllowFailure | Out-Null
        $devices = Invoke-Adb @("devices", "-l")
        if ($devices.Text -match "(?m)^$([regex]::Escape($TcpSerial))\s+device\b") { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 30 秒内恢复：$TcpSerial"
}

function Wait-ManagementRecovered {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        try {
            $fingerprint = Get-UsbFingerprint
            $adapter = Get-RndisAdapter
            if ($fingerprint -eq $baselineFingerprint -and
                $adapter.Status -eq "Up" -and
                (Test-DevicePing) -and
                (Test-TcpPort 22)) {
                return $adapter
            }
        } catch {
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 重启后 RNDIS/SSH 未在 30 秒内恢复"
}

function Wait-AdbdPidChanged {
    param([string]$OldPid)
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Wait-TcpAdb
        $result = Invoke-Adb @(
            "-s", $TcpSerial, "shell",
            "systemctl is-active adbd; systemctl show -p MainPID --value adbd"
        ) -AllowFailure
        $lines = @($result.Text -split "`r?`n" | Where-Object { $_ -ne "" })
        if ($result.ExitCode -eq 0 -and
            $lines.Count -eq 2 -and
            $lines[0] -eq "active" -and
            $lines[1] -match '^\d+$' -and
            $lines[1] -ne $OldPid) {
            return $lines[1]
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "adbd 未在 15 秒内以新 PID 稳定运行，旧 PID=$OldPid"
}

function Receive-PingSamples {
    param($Job, [Collections.Generic.List[object]]$Store)
    $newSamples = @(Receive-Job -Job $Job)
    foreach ($sample in $newSamples) { $Store.Add($sample) }
    return $newSamples.Count
}

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：$Adb" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("adbd-restart-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Wait-TcpAdb
$baselineFingerprint = Get-UsbFingerprint
$baselineAdapter = Get-RndisAdapter
if ($baselineAdapter.Status -ne "Up") { throw "RNDIS 网卡当前不是 Up：$($baselineAdapter.Status)" }
if (-not (Test-DevicePing) -or -not (Test-TcpPort 22)) {
    throw "测试前 RNDIS ping 或 SSH 不可用"
}

$baseline = @(
    "start=$(Get-Date -Format o)"
    "cycles=$Cycles"
    "sample_interval_ms=$SampleIntervalMilliseconds"
    "observation_seconds=$ObservationSeconds"
    "adapter_name=$($baselineAdapter.Name)"
    "adapter_guid=$($baselineAdapter.InterfaceGuid)"
    "adapter_ifindex=$($baselineAdapter.ifIndex)"
    "adapter_mac=$($baselineAdapter.MacAddress)"
    "usb_instances_begin"
    $baselineFingerprint
    "usb_instances_end"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "baseline.txt") ($baseline + "`r`n")

$cycleResults = New-Object 'Collections.Generic.List[string]'
$pingSamples = New-Object 'Collections.Generic.List[object]'
$pingJob = Start-Job -ArgumentList $DeviceIp, $SampleIntervalMilliseconds -ScriptBlock {
    param($Address, $IntervalMilliseconds)
    while ($true) {
        $ping = New-Object Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($Address, 500)
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

try {
    Start-Sleep -Seconds 1
    Receive-PingSamples $pingJob $pingSamples | Out-Null
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        $samplesBefore = $pingSamples.Count
        $oldPid = (Invoke-Adb @("-s", $TcpSerial, "shell", "systemctl show -p MainPID --value adbd")).Text.Trim()
        $unit = "zu02-adbd-restart-$cycle"
        Invoke-Adb @(
            "-s", $TcpSerial, "shell",
            "systemd-run --quiet --collect --unit=$unit --on-active=1s /usr/bin/systemctl restart adbd"
        ) | Out-Null

        Start-Sleep -Seconds $ObservationSeconds
        Receive-PingSamples $pingJob $pingSamples | Out-Null
        $newPid = Wait-AdbdPidChanged $oldPid
        $adapter = Wait-ManagementRecovered
        if ($adapter.Status -ne "Up" -or
            $adapter.InterfaceGuid -ne $baselineAdapter.InterfaceGuid -or
            $adapter.ifIndex -ne $baselineAdapter.ifIndex -or
            $adapter.MacAddress -ne $baselineAdapter.MacAddress) {
            throw "第 $cycle 轮：RNDIS 网卡状态或身份发生变化"
        }

        $serviceProbe = Invoke-Adb @(
            "-s", $TcpSerial, "shell",
            "systemctl is-active zu02-usb-gadget adbd zu02-usb-watchdog.timer zu02-usb-network ssh; " +
            "if ss -lnt | grep -q ':5555 '; then echo TCP_ADB_PRESENT; fi"
        )
        $serviceLines = @($serviceProbe.Text -split "`r?`n" | Where-Object { $_ -ne "" })
        if (@($serviceLines | Where-Object { $_ -eq "active" }).Count -ne 5 -or
            $serviceProbe.Text -notmatch '(?m)^TCP_ADB_PRESENT\r?$') {
            throw "第 $cycle 轮：Debian 服务探针不匹配：`r`n$($serviceProbe.Text)"
        }
        $udc = (Invoke-Adb @(
            "-s", $TcpSerial, "shell", "cat /sys/kernel/config/usb_gadget/g1/UDC"
        )).Text.Trim()
        $functionLinks = (Invoke-Adb @(
            "-s", $TcpSerial, "shell",
            "find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf '%f\n' | sort"
        )).Text.Trim()
        if ($udc -ne "ci_hdrc.0" -or $functionLinks -ne "acm.usb0`r`nrndis.usb0") {
            throw "第 $cycle 轮：USB gadget 状态不匹配：UDC=$udc functions=$functionLinks"
        }
        $samples = $pingSamples.Count - $samplesBefore
        $result = "cycle=$cycle old_pid=$oldPid new_pid=$newPid ping_samples=$samples result=pass"
        $cycleResults.Add($result)
        Write-Host $result
    }
} finally {
    Stop-Job -Job $pingJob -ErrorAction SilentlyContinue
    $remaining = @(Receive-Job -Job $pingJob -ErrorAction SilentlyContinue)
    foreach ($sample in $remaining) { $pingSamples.Add($sample) }
    Remove-Job -Job $pingJob -Force -ErrorAction SilentlyContinue
    if ($pingSamples.Count -gt 0) {
        $pingSamples | Export-Csv -LiteralPath (Join-Path $OutputDir "ping-samples.csv") -NoTypeInformation -Encoding UTF8
    }
    if ($cycleResults.Count -gt 0) {
        Write-Utf8File (Join-Path $OutputDir "cycles.txt") (($cycleResults -join "`r`n") + "`r`n")
    }
}

$summary = @(
    "Debian adbd 热重启验收通过"
    "cycles=$Cycles"
    "usb_functions=rndis-acm"
    "adb_transport=tcp-5555"
    "usb_watchdog=systemd-timer"
    "usb_pnp_identity_changed=false"
    "rndis_recovered=true"
    "ssh_recovered=true"
    "ping_samples=$($pingSamples.Count)"
    "ping_failures=$(@($pingSamples | Where-Object { -not $_.Success }).Count)"
    "completed=$(Get-Date -Format o)"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
