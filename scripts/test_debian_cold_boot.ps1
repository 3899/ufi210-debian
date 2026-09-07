[CmdletBinding()]
param(
    [ValidateRange(30, 600)]
    [int]$DisconnectTimeoutSeconds = 300,
    [ValidateRange(60, 600)]
    [int]$BootTimeoutSeconds = 300,
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$OutputRoot = "",
    [string]$ResumeDirectory = "",
    [ValidateRange(0, 86400)]
    [int]$ConfirmedDisconnectSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$ManifestPath = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs\BUILD-MANIFEST.txt"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$ActiveServices = @(
    "zu02-firewall", "zu02-usb-gadget", "adbd", "zu02-usb-watchdog.timer",
    "zu02-usb-network", "ssh", "dnsmasq", "NetworkManager",
    "serial-getty@ttyGS0.service", "zu02-wcnss", "qrtr-ns", "rmtfs",
    "zu02-mpss", "zu02-modem-prepare", "ModemManager", "zu02-modem-register",
    "ufi210-modem-time-sync",
    "fstrim.timer"
)

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $Adb = $command.Source }
}
if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "缺少工具：adb.exe" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "缺少 large-rootfs 构建清单：$ManifestPath"
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
    [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Read-Manifest {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
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
        throw "USB 复合设备不完整：期望父设备、RNDIS 和 ACM 各一个，实际 $($devices.Count) 个"
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

function Get-UsbLastArrival {
    $parent = @(Get-DebianUsbDevices | Where-Object {
        $_.InstanceId -notmatch '&MI_[0-9A-F]{2}\\'
    })
    if ($parent.Count -ne 1) { throw "未找到唯一的 Debian USB 父设备" }
    $property = Get-PnpDeviceProperty -InstanceId $parent[0].InstanceId `
        -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop
    if ($null -eq $property.Data) { throw "Windows 未返回 USB 最后到达时间" }
    return [datetime]$property.Data
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

function Test-TcpAdb {
    Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
    $devices = Invoke-Adb @("devices", "-l") -AllowFailure
    return $devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b"
}

function Wait-TcpAdb {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-TcpAdb) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "TCP ADB 未在 $TimeoutSeconds 秒内出现：$AdbSerial"
}

function Get-RuntimeProbe {
    $serviceList = $ActiveServices -join " "
    $command = @'
set -eu
printf 'BOOT_ID='; cat /proc/sys/kernel/random/boot_id
printf 'ROOT='; findmnt -nro SOURCE /
printf 'ROOT_UUID='; findmnt -nro UUID /
printf 'ROOT_OPTIONS='; findmnt -nro OPTIONS /
root_blocks=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block count:[[:space:]]*//p')
root_block_size=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
printf 'ROOT_FS_BYTES=%s\n' "$((root_blocks * root_block_size))"
if mountpoint -q /data; then echo 'DATA_MOUNTED=yes'; else echo 'DATA_MOUNTED=no'; fi
root_probe="/var/tmp/.ufi210-cold-boot-write-test-$$"
printf 'ok\n' > "$root_probe"
test "$(cat "$root_probe")" = ok
rm -f "$root_probe"
printf 'ROOT_WRITABLE=yes\n'
printf 'DM_BYTES='; blockdev --getsize64 /dev/mapper/ufi210-root
printf 'DM_LINES='; dmsetup table ufi210-root | wc -l
printf 'FSTRIM_ENABLED='; systemctl is-enabled fstrim.timer
printf 'KERNEL='; uname -r
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
printf 'ACTIVE='; systemctl is-active __SERVICES__ | grep -c '^active$'
printf 'UDC='; cat /sys/kernel/config/usb_gadget/g1/UDC
printf 'USB_PID='; cat /sys/kernel/config/usb_gadget/g1/idProduct
printf 'TCP_ADB='; ss -lnt | grep -q ':5555 ' && echo listening
printf 'USB0='; ip -4 -o address show dev usb0 | sed -n 's/.* \(192\.168\.68\.1\/24\) .*/\1/p'
find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf 'FUNCTION=%f\n' | sort
for remoteproc in /sys/class/remoteproc/remoteproc*; do
    printf 'REMOTEPROC=%s:' "$(cat "$remoteproc/name")"
    cat "$remoteproc/state"
done
test ! -e /dev/usb-ffs/adb
printf 'BOOT_SHA256='; head -c __BOOT_BYTES__ /dev/mmcblk0p20 | sha256sum | cut -d' ' -f1
'@
    $command = $command.Replace('__SERVICES__', $serviceList)
    $command = $command.Replace('__BOOT_BYTES__', $Manifest.boot_image_bytes)
    return Invoke-Adb @("-s", $AdbSerial, "shell", $command)
}

function Assert-RuntimeProbe {
    param($Probe, [string]$ExpectedBootId)
    $checks = @(
        "BOOT_ID=$ExpectedBootId",
        "ROOT=/dev/mapper/ufi210-root",
        "ROOT_UUID=$($Manifest.rootfs_uuid)",
        "ROOT_FS_BYTES=$($Manifest.dm_filesystem_bytes)",
        "DATA_MOUNTED=no",
        "ROOT_WRITABLE=yes",
        "DM_BYTES=$($Manifest.dm_total_bytes)",
        "DM_LINES=3",
        "FSTRIM_ENABLED=enabled",
        "KERNEL=7.0.0-msm8909",
        "FAILED=0",
        "ACTIVE=$($ActiveServices.Count)",
        "UDC=ci_hdrc.0",
        "USB_PID=0xd001",
        "TCP_ADB=listening",
        "USB0=192.168.68.1/24",
        "BOOT_SHA256=$($Manifest.boot_image_sha256)"
    )
    foreach ($check in $checks) {
        if ($Probe.Text -notmatch "(?m)^$([regex]::Escape($check))\r?$") {
            throw "冷启动运行探针缺少：$check`r`n$($Probe.Text)"
        }
    }
    if ($Probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\brw\b' -or
        $Probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\bnoatime\b') {
        throw "冷启动后根文件系统挂载选项不匹配：`r`n$($Probe.Text)"
    }
    $functions = @([regex]::Matches($Probe.Text, '(?m)^FUNCTION=(.+)\r?$') | ForEach-Object {
        $_.Groups[1].Value.Trim()
    })
    if (($functions -join ',') -ne 'acm.usb0,rndis.usb0') {
        throw "USB functions 不匹配：$($functions -join ',')"
    }
    if (@([regex]::Matches($Probe.Text, '(?m)^REMOTEPROC=([^:\r\n]+):running\r?$')).Count -ne 2) {
        throw "运行中的 remoteproc 数量不是 2：`r`n$($Probe.Text)"
    }
}

$Manifest = Read-Manifest
if ($Manifest.target_partition -ne "large-rootfs" -or $Manifest.target_partition_bytes -ne "3485240832" -or
    $Manifest.dm_total_bytes -ne "3485240832" -or $Manifest.dm_filesystem_bytes -ne "3485237248" -or
    $Manifest.rootfs_uuid -ne "89090000-0000-4000-8000-000000000031" -or
    $Manifest.rootfs_auto_grow -ne "disabled" -or $Manifest.fstrim -ne "weekly-systemd-timer" -or
    $Manifest.usb_product_id -ne "0xD001" -or
    $Manifest.usb_functions -ne "rndis-acm" -or $Manifest.boot_image_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $Manifest.boot_image_bytes -notmatch '^\d+$') {
    throw "large-rootfs 构建清单不满足冷启动验收条件"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$resumed = [bool]$ResumeDirectory
$reconnectedAt = $null
if ($resumed) {
    if ($ConfirmedDisconnectSeconds -lt 15) {
        throw "恢复冷启动验收必须提供至少 15 秒的已确认 USB 缺席时长"
    }
    $OutputDir = [IO.Path]::GetFullPath($ResumeDirectory)
    $beforePath = Join-Path $OutputDir "before.txt"
    if (-not (Test-Path -LiteralPath $beforePath -PathType Leaf)) {
        throw "恢复目录缺少断电前基线：$beforePath"
    }
    $beforeText = Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8
    $beforeBootMatch = [regex]::Match($beforeText, '(?m)^boot_id=([0-9a-f-]{36})\r?$')
    $beforeGuidMatch = [regex]::Match($beforeText, '(?m)^adapter_guid=\{?([0-9A-Fa-f-]{36})\}?\r?$')
    $beforeMacMatch = [regex]::Match($beforeText, '(?m)^adapter_mac=([0-9A-Fa-f-]{17})\r?$')
    $beforeFingerprintMatch = [regex]::Match(
        $beforeText,
        '(?ms)^usb_instances_begin\r?\n(.+?)\r?\nusb_instances_end\r?$'
    )
    if (-not $beforeBootMatch.Success -or -not $beforeGuidMatch.Success -or
        -not $beforeMacMatch.Success -or -not $beforeFingerprintMatch.Success) {
        throw "断电前基线结构无效：$beforePath"
    }
    $beforeBootId = $beforeBootMatch.Groups[1].Value
    $beforeAdapterGuid = $beforeGuidMatch.Groups[1].Value
    $beforeAdapterMac = $beforeMacMatch.Groups[1].Value
    [string[]]$beforeInstanceIds = @($beforeFingerprintMatch.Groups[1].Value -split "`r?`n")
    [Array]::Sort($beforeInstanceIds, [StringComparer]::OrdinalIgnoreCase)
    $beforeFingerprint = $beforeInstanceIds -join "`n"
    Wait-TcpAdb 30
    $reconnectedAt = Get-UsbLastArrival
    if ($reconnectedAt.ToUniversalTime() -le (Get-Item -LiteralPath $beforePath).LastWriteTimeUtc) {
        throw "USB 最后到达时间不晚于断电前基线，不能证明重新枚举"
    }
    $disconnectedAt = $reconnectedAt.AddSeconds(-$ConfirmedDisconnectSeconds)
} else {
    if ($ConfirmedDisconnectSeconds -ne 0) {
        throw "ConfirmedDisconnectSeconds 只能与 ResumeDirectory 一起使用"
    }
    $OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("cold-boot-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    Wait-TcpAdb 30
    $beforeFingerprint = Get-UsbFingerprint
    $beforeAdapter = Get-RndisAdapter
    $beforeAdapterGuid = $beforeAdapter.InterfaceGuid.ToString().Trim('{}')
    $beforeAdapterMac = $beforeAdapter.MacAddress
    if ($beforeAdapter.Status -ne "Up" -or -not (Test-TcpPort 22)) {
        throw "冷启动测试前 RNDIS 或 SSH 不可用"
    }
    $beforeBootId = (Invoke-Adb @("-s", $AdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id")).Text.Trim()
    $beforeProbe = Get-RuntimeProbe
    Assert-RuntimeProbe $beforeProbe $beforeBootId
    Write-Utf8File (Join-Path $OutputDir "before.txt") ((@(
        "boot_id=$beforeBootId", "adapter_guid=$beforeAdapterGuid",
        "adapter_mac=$beforeAdapterMac", "usb_instances_begin", $beforeFingerprint,
        "usb_instances_end", $beforeProbe.Text
    ) -join "`r`n") + "`r`n")

    Write-Host "监控已就绪：请将设备完全断电至少 15 秒，然后重新插入 USB。"
    $disconnectDeadline = (Get-Date).AddSeconds($DisconnectTimeoutSeconds)
    do {
        if ((Get-DebianUsbDevices).Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $disconnectDeadline)
    if ((Get-DebianUsbDevices).Count -ne 0) {
        throw "未在 $DisconnectTimeoutSeconds 秒内检测到设备物理断开"
    }
    $disconnectedAt = Get-Date
    $minimumPowerOffDeadline = $disconnectedAt.AddSeconds(15)
    do {
        if ((Get-DebianUsbDevices).Count -ne 0) {
            throw "设备在 USB 缺席满 15 秒前重新插入，不满足冷启动验收条件"
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $minimumPowerOffDeadline)
    Write-Host "已确认 USB 连续缺席 15 秒，等待冷启动。"
}

$bootDeadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
$lastError = "尚未重新枚举"
$afterFingerprint = $null
$afterAdapter = $null
$afterBootId = $null
$afterProbe = $null
do {
    try {
        if ((Get-DebianUsbDevices).Count -eq 3 -and (Test-TcpAdb)) {
            $afterFingerprint = Get-UsbFingerprint
            $afterAdapter = Get-RndisAdapter
            $afterBootId = (Invoke-Adb @("-s", $AdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id")).Text.Trim()
            $afterProbe = Get-RuntimeProbe
            Assert-RuntimeProbe $afterProbe $afterBootId
            if ($afterBootId -eq $beforeBootId) { throw "冷启动后 boot_id 未变化" }
            if ($afterFingerprint -ne $beforeFingerprint) { throw "冷启动后 USB PnP 指纹变化" }
            if ($afterAdapter.Status -ne "Up" -or
                $afterAdapter.InterfaceGuid.ToString().Trim('{}') -ne $beforeAdapterGuid -or
                $afterAdapter.MacAddress -ne $beforeAdapterMac -or
                -not (Test-TcpPort 22)) {
                throw "冷启动后 RNDIS 身份、状态或 SSH 不匹配"
            }
            break
        }
    } catch {
        $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $bootDeadline)
if (-not $afterBootId -or $afterBootId -eq $beforeBootId) {
    throw "设备未在 $BootTimeoutSeconds 秒内完成冷启动：$lastError"
}

Write-Utf8File (Join-Path $OutputDir "after.txt") ((@(
    "boot_id=$afterBootId", "adapter_guid=$($afterAdapter.InterfaceGuid)",
    "adapter_mac=$($afterAdapter.MacAddress)", "usb_instances_begin", $afterFingerprint,
    "usb_instances_end", $afterProbe.Text
) -join "`r`n") + "`r`n")
$summary = @(
    "Debian 真实断电冷启动验收通过",
    "power_off_minimum_seconds=$(if ($resumed) { $ConfirmedDisconnectSeconds } else { 15 })",
    "evidence_mode=$(if ($resumed) { 'resume-after-confirmed-usb-absence' } else { 'continuous-monitor' })",
    "before_boot_id=$beforeBootId",
    "after_boot_id=$afterBootId",
    "usb_pnp_changed=false",
    "rndis_identity_changed=false",
    "usb_functions=rndis-acm",
    "adb_transport=tcp-5555",
    "root=/dev/mapper/ufi210-root",
    "root_filesystem_bytes=$($Manifest.dm_filesystem_bytes)",
    "root_uuid=$($Manifest.rootfs_uuid)",
    "data_mount=none",
    "fstrim_timer=enabled",
    "boot_sha256=$($Manifest.boot_image_sha256)",
    "disconnected_at=$($disconnectedAt.ToString('o'))",
    "reconnected_at=$(if ($reconnectedAt) { $reconnectedAt.ToString('o') } else { 'observed-by-monitor' })",
    "completed=$(Get-Date -Format o)",
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
