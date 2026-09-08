[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$Cycles = 10,
    [ValidateRange(30, 300)]
    [int]$BootTimeoutSeconds = 120,
    [string]$DeviceIp = "192.168.68.1",
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$ExpectedBootSha256 = "",
    [ValidateRange(0, 33554432)]
    [int]$BootImageBytes = 0,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Services = @(
    "zu02-firewall", "zu02-usb-gadget", "adbd", "zu02-usb-watchdog.timer", "zu02-usb-network", "ssh", "dnsmasq",
    "NetworkManager", "serial-getty@ttyGS0.service", "zu02-wcnss", "qrtr-ns", "rmtfs",
    "zu02-mpss", "zu02-modem-prepare", "ModemManager", "zu02-modem-register",
    "ufi210-modem-time-sync",
    "fstrim.timer"
)

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $Adb -PathType Leaf) { return $Adb }
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "缺少工具：adb.exe"
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
    $text = $text.Replace(([char]0).ToString(), "")
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "adb 失败（$exitCode）：`r`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Test-AdbPresent {
    Invoke-Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
    $devices = Invoke-Adb @("devices", "-l") -AllowFailure
    return $devices.Text -match "(?m)^$([regex]::Escape($AdbSerial))\s+device\b"
}

function Wait-AdbDisconnected {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        if (-not (Test-AdbPresent)) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "普通重启后 TCP ADB 未在 30 秒内断开"
}

function Wait-NewBoot {
    param([string]$PreviousBootId)
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    do {
        if (Test-AdbPresent) {
            $probe = Invoke-Adb @(
                "-s", $AdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id"
            ) -AllowFailure
            $bootId = $probe.Text.Trim()
            if ($probe.ExitCode -eq 0 -and $bootId -match '^[0-9a-f-]{36}$' -and $bootId -ne $PreviousBootId) {
                return $bootId
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "设备未在 $BootTimeoutSeconds 秒内以新 boot_id 返回 Debian"
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
        throw "Debian USB 复合设备不完整：期望父设备、RNDIS 和 ACM 各一个"
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
        $reply = $ping.Send($DeviceIp, 1000)
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

function Get-RuntimeProbe {
    $serviceList = $Services -join " "
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
printf 'ADB_TMP_MODE='; stat -c %a /data/local/tmp
printf 'DM_BYTES='; blockdev --getsize64 /dev/mapper/ufi210-root
printf 'DM_LINES='; dmsetup table ufi210-root | wc -l
printf 'FSTRIM_ENABLED='; systemctl is-enabled fstrim.timer
printf 'KERNEL='; uname -r
printf 'ARCH='; uname -m
printf 'MODEL='; grep -a -o 'DW01 (ZU02_main_v1.1)' /proc/device-tree/model
printf 'CMDLINE='; cat /proc/cmdline
printf 'FAILED='; systemctl --failed --no-legend --plain | wc -l
printf 'ACTIVE='; systemctl is-active __SERVICES__ | grep -c '^active$'
printf 'UDC='; cat /sys/kernel/config/usb_gadget/g1/UDC
printf 'RNDIS_DEV_ADDR='; cat /sys/kernel/config/usb_gadget/g1/functions/rndis.usb0/dev_addr; echo
printf 'RNDIS_HOST_ADDR='; cat /sys/kernel/config/usb_gadget/g1/functions/rndis.usb0/host_addr; echo
printf 'TCP_ADB='; ss -lnt | grep -q ':5555 ' && echo listening
for function in /sys/kernel/config/usb_gadget/g1/configs/c.1/*; do
    test -L "$function" && echo "FUNCTION=$(basename "$function")"
done | sort
for remoteproc in /sys/class/remoteproc/remoteproc*; do
    printf 'REMOTEPROC=%s:' "$(cat "$remoteproc/name")"
    cat "$remoteproc/state"
done
printf 'BOOT_SHA256='; head -c __BOOT_BYTES__ /dev/mmcblk0p20 | sha256sum | cut -d' ' -f1
printf 'UPTIME='; cut -d. -f1 /proc/uptime
'@
    $command = $command.Replace('__SERVICES__', $serviceList)
    $command = $command.Replace('__BOOT_BYTES__', $BootImageBytes.ToString())
    return Invoke-Adb @("-s", $AdbSerial, "shell", $command) -AllowFailure
}

function Assert-RuntimeProbe {
    param($Probe, [string]$ExpectedBootId)
    if ($Probe.ExitCode -ne 0) { throw "运行态探针失败：`r`n$($Probe.Text)" }
    $checks = @(
        "BOOT_ID=$ExpectedBootId",
        "ROOT=/dev/mapper/ufi210-root",
        "ROOT_UUID=$ExpectedRootfsUuid",
        "ROOT_FS_BYTES=$ExpectedRootfsBytes",
        "DATA_MOUNTED=no",
        "ADB_TMP_MODE=1777",
        "DM_BYTES=3485240832",
        "DM_LINES=3",
        "FSTRIM_ENABLED=enabled",
        "KERNEL=7.0.0-msm8909",
        "ARCH=armv7l",
        "MODEL=DW01 (ZU02_main_v1.1)",
        "FAILED=0",
        "ACTIVE=$($Services.Count)",
        "UDC=ci_hdrc.0",
        "TCP_ADB=listening",
        "BOOT_SHA256=$ExpectedBootSha256"
    )
    foreach ($check in $checks) {
        if ($Probe.Text -notmatch "(?m)^$([regex]::Escape($check))\r?$") {
            throw "运行态探针缺少：$check`r`n$($Probe.Text)"
        }
    }
    if ($Probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\brw\b' -or
        $Probe.Text -notmatch '(?m)^ROOT_OPTIONS=.*\bnoatime\b') {
        throw "运行态根文件系统挂载选项不匹配：`r`n$($Probe.Text)"
    }
    if ($Probe.Text -notmatch '(?m)^CMDLINE=.*\breboot=warm\b' -or
        $Probe.Text -notmatch '(?m)^CMDLINE=.*\broot=/dev/mapper/ufi210-root\b') {
        throw "内核 cmdline 不包含 reboot=warm 和大根卷：`r`n$($Probe.Text)"
    }
    if ($Probe.Text -notmatch '(?m)^RNDIS_DEV_ADDR=02(?::[0-9a-f]{2}){5}\r?$' -or
        $Probe.Text -notmatch '(?m)^RNDIS_HOST_ADDR=06(?::[0-9a-f]{2}){5}\r?$') {
        throw "RNDIS MAC 不是设备派生的本地管理单播地址：`r`n$($Probe.Text)"
    }
    $functions = @([regex]::Matches($Probe.Text, '(?m)^FUNCTION=(.+)\r?$') | ForEach-Object {
        $_.Groups[1].Value.Trim()
    })
    if (($functions -join ',') -ne 'acm.usb0,rndis.usb0') {
        throw "USB functions 不匹配：$($functions -join ',')"
    }
    $remoteprocs = @([regex]::Matches($Probe.Text, '(?m)^REMOTEPROC=([^:]+):running\r?$'))
    if ($remoteprocs.Count -ne 2) {
        throw "运行中的 remoteproc 数量不是 2：`r`n$($Probe.Text)"
    }
}

function Wait-ManagementReady {
    param([string]$ExpectedBootId, [string]$ExpectedUsbFingerprint, $ExpectedAdapter)
    $deadline = (Get-Date).AddSeconds(60)
    $lastError = "尚未执行探针"
    do {
        try {
            $fingerprint = Get-UsbFingerprint
            $adapter = Get-RndisAdapter
            $probe = Get-RuntimeProbe
            Assert-RuntimeProbe $probe $ExpectedBootId
            if ($fingerprint -ne $ExpectedUsbFingerprint) { throw "USB PnP 标识发生变化" }
            if ($adapter.Status -ne "Up" -or
                $adapter.InterfaceGuid -ne $ExpectedAdapter.InterfaceGuid -or
                $adapter.MacAddress -ne $ExpectedAdapter.MacAddress) {
                throw "RNDIS 网卡状态或身份发生变化"
            }
            if (-not (Test-DevicePing)) { throw "RNDIS ping 不通" }
            if (-not (Test-TcpPort 22)) { throw "SSH 端口不可达" }
            return $probe
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "Debian 管理面未在 60 秒内就绪：$lastError"
}

$Adb = Resolve-Adb
$Manifest = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs\BUILD-MANIFEST.txt"
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw "缺少 large-rootfs 构建 manifest：$Manifest"
}
$manifestValues = @{}
foreach ($line in Get-Content -LiteralPath $Manifest -Encoding UTF8) {
    if ($line -match '^([^=]+)=(.*)$') { $manifestValues[$matches[1]] = $matches[2] }
}
if (-not $ExpectedBootSha256) { $ExpectedBootSha256 = $manifestValues['boot_image_sha256'] }
if ($BootImageBytes -eq 0) { $BootImageBytes = [int]$manifestValues['boot_image_bytes'] }
$ExpectedRootfsBytes = $manifestValues['dm_filesystem_bytes']
$ExpectedRootfsUuid = $manifestValues['rootfs_uuid']
if ($manifestValues['target_partition'] -ne 'large-rootfs' -or
    $manifestValues['target_partition_bytes'] -ne '3485240832' -or
    $manifestValues['dm_total_bytes'] -ne '3485240832' -or
    $ExpectedRootfsBytes -ne '3485237248' -or
    $ExpectedRootfsUuid -ne '89090000-0000-4000-8000-000000000031' -or
    $manifestValues['rootfs_auto_grow'] -ne 'disabled' -or
    $manifestValues['fstrim'] -ne 'weekly-systemd-timer') {
    throw "构建 manifest 的持久存储布局不匹配"
}
if ($ExpectedBootSha256 -notmatch '^[0-9a-f]{64}$') { throw "boot SHA256 格式错误" }
if ($BootImageBytes -le 0 -or $BootImageBytes -gt 33554432) { throw "boot 镜像长度越界" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("reboot-cycles-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not (Test-AdbPresent)) { throw "TCP ADB 不可用：$AdbSerial" }
$baselineFingerprint = Get-UsbFingerprint
$baselineAdapter = Get-RndisAdapter
$bootId = (Invoke-Adb @("-s", $AdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id")).Text.Trim()
$baselineProbe = Wait-ManagementReady $bootId $baselineFingerprint $baselineAdapter
$baseline = @(
    "adapter_name=$($baselineAdapter.Name)",
    "adapter_guid=$($baselineAdapter.InterfaceGuid)",
    "adapter_mac=$($baselineAdapter.MacAddress)",
    "initial_ifindex=$($baselineAdapter.ifIndex)",
    "usb_instances_begin",
    $baselineFingerprint,
    "usb_instances_end",
    $baselineProbe.Text
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "baseline.txt") ($baseline + "`r`n")

$results = New-Object 'Collections.Generic.List[string]'
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $previousBootId = $bootId
    $started = Get-Date
    $reboot = Invoke-Adb @("-s", $AdbSerial, "shell", "sync; systemctl reboot") -AllowFailure
    Write-Utf8File (Join-Path $OutputDir ("reboot-command-{0:D2}.txt" -f $cycle)) (
        "exit_code=$($reboot.ExitCode)`r`n$($reboot.Text)`r`n"
    )
    Wait-AdbDisconnected
    $bootId = Wait-NewBoot $previousBootId
    $probe = Wait-ManagementReady $bootId $baselineFingerprint $baselineAdapter
    Write-Utf8File (Join-Path $OutputDir ("probe-{0:D2}.txt" -f $cycle)) ($probe.Text + "`r`n")
    $duration = [int]((Get-Date) - $started).TotalSeconds
    $result = "cycle=$cycle previous_boot_id=$previousBootId boot_id=$bootId duration_seconds=$duration result=pass"
    $results.Add($result)
    Write-Host $result
}

$kernelErrors = Invoke-Adb @(
    "-s", $AdbSerial, "shell",
    "dmesg | grep -Ei 'kernel panic|watchdog|remoteproc.*(crash|fatal)|oom-killer|out of memory|ext4-fs error|buffer i/o error|mmc.*error|I/O error' | tail -n 100"
) -AllowFailure
Write-Utf8File (Join-Path $OutputDir "kernel-errors.txt") ($kernelErrors.Text + "`r`n")
if ($kernelErrors.Text.Trim()) {
    throw "最后一轮启动日志中发现严重内核错误，查看 $OutputDir\kernel-errors.txt"
}

Write-Utf8File (Join-Path $OutputDir "cycles.txt") (($results -join "`r`n") + "`r`n")
$summary = @(
    "Debian 普通重启回归通过",
    "cycles=$Cycles",
    "root=/dev/mapper/ufi210-root",
    "root_filesystem_bytes=$ExpectedRootfsBytes",
    "root_uuid=$ExpectedRootfsUuid",
    "data_mount=none",
    "fstrim_timer=enabled",
    "boot_sha256=$ExpectedBootSha256",
    "reboot_mode=warm",
    "usb_functions=rndis-acm",
    "adb_transport=tcp-5555",
    "remoteprocs=2",
    "systemd_failed=0",
    "final_boot_id=$bootId",
    "completed=$(Get-Date -Format o)",
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
