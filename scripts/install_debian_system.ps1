[CmdletBinding()]
param(
    [switch]$ConfirmPersistentInstall,
    [switch]$ConfirmFastbootTarget,
    [string]$BootBackupPath = "",
    [ValidateRange(60, 600)]
    [int]$LinuxTimeoutSeconds = 240,
    [ValidateRange(15, 120)]
    [int]$FastbootTimeoutSeconds = 45,
    [string]$DeviceIp = "192.168.68.1",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Adb = Join-Path $ProjectRoot "adb.exe"
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"
$ArtifactRoot = Join-Path $ProjectRoot "out\mainline\debian-system"
$RootfsImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-system.ext4"
$BootImage = Join-Path $ArtifactRoot "boot-debian-system.img"
$ManifestPath = Join-Path $ArtifactRoot "BUILD-MANIFEST.txt"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$BootPartitionBytes = 33554432L
$SystemPartitionBytes = 1288491008L
$TcpAdbSerial = "${DeviceIp}:5555"
$UpgradeUsbAdbSerial = "ZU02-DW01"

if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $Adb = $command.Source }
}
if (-not (Test-Path -LiteralPath $Fastboot -PathType Leaf)) {
    $command = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if ($command) { $Fastboot = $command.Source }
}
if (-not (Test-Path -LiteralPath $RootfsImage -PathType Leaf)) {
    $ArtifactRoot = $ProjectRoot
    $RootfsImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-system.ext4"
    $BootImage = Join-Path $ArtifactRoot "boot-debian-system.img"
    $ManifestPath = Join-Path $ArtifactRoot "INSTALL-MANIFEST.txt"
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

function Read-KeyValues {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "缺少清单：$Path" }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "缺少文件：$Path" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "SHA256 不匹配：$Path`r`nactual=$actual`r`nexpected=$Expected"
    }
    return $actual
}

function Get-AdbDevices {
    param([switch]$AllowFailure)
    $result = Invoke-Native $Adb @("devices", "-l") -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($AllowFailure) { return @() }
        throw "无法枚举 ADB 设备：`r`n$($result.Text)"
    }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device(?:\s+.*)?$') { $Matches[1] }
    })
}

function Get-FastbootDevice {
    $result = Invoke-Native $Fastboot @("devices") -AllowFailure
    [string[]]$devices = @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+fastboot\s*$') { $Matches[1] }
    })
    if ($devices.Count -gt 1) { throw "检测到多个 fastboot 设备：$($devices -join ', ')" }
    if ($devices.Count -eq 1) { return $devices[0] }
    return $null
}

function Wait-Fastboot {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $device = Get-FastbootDevice
        if ($device) { return $device }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-TcpAdb {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Invoke-Native $Adb @("connect", $TcpAdbSerial) -AllowFailure | Out-Null
        $devices = Get-AdbDevices -AllowFailure
        if ($devices -contains $TcpAdbSerial) { return }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "Debian TCP ADB 未在 $TimeoutSeconds 秒内出现：$TcpAdbSerial"
}

function Wait-TcpAdbOffline {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $devices = Get-AdbDevices -AllowFailure
        if ($devices -notcontains $TcpAdbSerial) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Debian TCP ADB 未在 $TimeoutSeconds 秒内离线，不能证明重启已开始"
}

function Get-FastbootVariable {
    param([string]$Serial, [string]$Name, [switch]$AllowEmpty)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "getvar", $Name) -AllowFailure
    $escapedName = [regex]::Escape($Name)
    if ($result.ExitCode -ne 0) {
        throw "无法读取 fastboot getvar ${Name}：`r`n$($result.Text)"
    }
    foreach ($line in $result.Text -split "`r?`n") {
        if ($line -match "^(?:\(bootloader\)[ `t]*)?${escapedName}:[ `t]*(.*?)[ `t]*$") {
            $value = $Matches[1].Trim()
            if (-not $AllowEmpty -and -not $value) {
                throw "fastboot getvar ${Name} 返回空值：`r`n$($result.Text)"
            }
            return $value
        }
    }
    throw "无法读取 fastboot getvar ${Name}：`r`n$($result.Text)"
}

function Get-HexBytes {
    param([string]$Value)
    if ($Value -notmatch '^0x([0-9a-fA-F]+)$') { throw "不是十六进制容量：$Value" }
    return [Convert]::ToInt64($Matches[1], 16)
}

function Save-AndroidBoot {
    param([string]$Serial, [string]$Destination)
    $remote = "/data/local/tmp/ufi210-boot-backup.img"
    Invoke-Native $Adb @(
        "-s", $Serial, "shell",
        "su -c 'dd if=/dev/block/bootdevice/by-name/boot of=$remote bs=1048576 2>/dev/null && chmod 0644 $remote'"
    ) | Out-Null
    try {
        Invoke-Native $Adb @("-s", $Serial, "pull", $remote, $Destination) | Out-Null
    } finally {
        Invoke-Native $Adb @("-s", $Serial, "shell", "su -c 'rm -f $remote'") -AllowFailure | Out-Null
    }
    if ((Get-Item -LiteralPath $Destination).Length -ne $BootPartitionBytes) {
        throw "boot 备份尺寸错误：$Destination"
    }
}

function Save-DebianBoot {
    param([string]$Serial, [string]$Destination)
    $remote = "/tmp/ufi210-boot-backup.img"
    Invoke-Native $Adb @(
        "-s", $Serial, "shell",
        "dd if=/dev/mmcblk0p20 of=$remote bs=1048576 2>/dev/null && chmod 0644 $remote"
    ) | Out-Null
    try {
        Invoke-Native $Adb @("-s", $Serial, "pull", $remote, $Destination) | Out-Null
    } finally {
        Invoke-Native $Adb @("-s", $Serial, "shell", "rm -f $remote") -AllowFailure | Out-Null
    }
    if ((Get-Item -LiteralPath $Destination).Length -ne $BootPartitionBytes) {
        throw "boot 备份尺寸错误：$Destination"
    }
}

function Assert-DebianRuntime {
    param([string]$Phase)
    Wait-TcpAdb $LinuxTimeoutSeconds
    $command = @'
set -eu
test "$(cat /sys/devices/soc0/soc_id)" = 245
test "$(hostname)" = ufi210
test "$(findmnt -nro SOURCE /)" = /dev/mmcblk0p21
test "$(findmnt -nro FSTYPE /)" = ext4
test "$(findmnt -nro UUID /)" = 89090000-0000-4000-8000-000000000021
test "$(cat /sys/kernel/reboot/mode)" = warm
test "$(blockdev --getsize64 /dev/mmcblk0p21)" = 1288491008
boot_prefix_hash=$(head -c __BOOT_IMAGE_BYTES__ /dev/mmcblk0p20 | sha256sum | cut -d ' ' -f1)
test "$boot_prefix_hash" = __BOOT_IMAGE_SHA256__
fs_block_count=$(dumpe2fs -h /dev/mmcblk0p21 2>/dev/null | sed -n 's/^Block count:[[:space:]]*//p')
fs_block_size=$(dumpe2fs -h /dev/mmcblk0p21 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
test "$fs_block_count" -gt 0
test "$fs_block_size" -gt 0
test "$((fs_block_count * fs_block_size))" = 1288491008
systemctl is-active NetworkManager ssh adbd zu02-usb-watchdog.timer zu02-wcnss zu02-mpss ModemManager
test "$(systemctl --failed --no-legend --plain | wc -l)" = 0
test "$(nmcli -t -f DEVICE,STATE device status | grep '^usb0:')" = usb0:unmanaged
ip -4 -o address show dev usb0 | grep -q ' 192.168.68.1/24 '
test -L /sys/kernel/config/usb_gadget/g1/configs/c.1/acm.usb0
test -L /sys/kernel/config/usb_gadget/g1/configs/c.1/rndis.usb0
test "$(find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l | wc -l)" = 2
! mountpoint -q /dev/usb-ffs/adb
ss -lnt | grep -q ':5555 '
test "$(nmcli -g connection.autoconnect connection show 'ZU02 Wi-Fi AP')" = no
test "$(cat /sys/class/remoteproc/remoteproc0/state)" = running
test "$(cat /sys/class/remoteproc/remoteproc1/state)" = running
echo SYSTEM_RUNTIME_OK
'@
    $command = $command.Replace("__BOOT_IMAGE_BYTES__", "$((Get-Item -LiteralPath $BootImage).Length)")
    $command = $command.Replace("__BOOT_IMAGE_SHA256__", $bootHash)
    $deadline = (Get-Date).AddSeconds($LinuxTimeoutSeconds)
    do {
        $result = Invoke-Native $Adb @("-s", $TcpAdbSerial, "shell", $command) -AllowFailure
        if ($result.ExitCode -eq 0 -and $result.Text -match '(?m)^SYSTEM_RUNTIME_OK\r?$') {
            Write-Utf8File (Join-Path $OutputDir "runtime-$Phase.txt") ($result.Text + "`r`n")
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Debian system 运行验收失败：$Phase`r`n$($result.Text)"
}

foreach ($tool in @($Adb, $Fastboot)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "缺少工具：$tool" }
}
if (-not $ConfirmPersistentInstall) {
    throw "本脚本会持久覆盖 system 和 boot；确认目标和恢复准备后使用 -ConfirmPersistentInstall"
}

$manifest = Read-KeyValues $ManifestPath
$required = [ordered]@{
    architecture = "armhf"
    hostname = "ufi210"
    target_partition = "system"
    target_partition_bytes = "$SystemPartitionBytes"
    rootfs_auto_grow = "enabled"
    reboot_mode = "warm"
    device_ip = "192.168.68.1"
    root_password = "simadmin"
    adbd = "tcp-5555"
    fastboot_reboot_command = "adb-shell-system-bin-reboot-bootloader"
    adb_tcp_endpoint = "192.168.68.1:5555"
    usb_functions = "rndis-acm"
    usb_product_id = "0xD001"
    usb_watchdog = "systemd-timer"
    usb_watchdog_interval_seconds = "5"
    usb_watchdog_unhealthy_seconds = "5"
    usb_management = "static-service-networkmanager-unmanaged"
    wifi_ap_profile = "preinstalled-disabled"
    wifi_interface_concurrency = "managed-or-ap-exclusive"
    qcdt_version = "3"
    qcdt_record_count = "30"
    qcdt_unique_dtb_count = "1"
}
foreach ($key in $required.Keys) {
    if (-not $manifest.ContainsKey($key) -or $manifest[$key] -ne $required[$key]) {
        throw "安装清单字段不匹配：$key"
    }
}
$rootfsHash = Assert-Hash $RootfsImage $manifest.rootfs_image_sha256
$bootHash = Assert-Hash $BootImage $manifest.boot_image_sha256
if ((Get-Item -LiteralPath $RootfsImage).Length -ge $SystemPartitionBytes) {
    throw "rootfs 镜像不小于 system 分区"
}
if ((Get-Item -LiteralPath $BootImage).Length -ge $BootPartitionBytes) {
    throw "boot image 不小于 boot 分区"
}

if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\persistent-install" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Native $Adb @("connect", $TcpAdbSerial) -AllowFailure | Out-Null
$adbDevices = @(Get-AdbDevices)
$fastbootSerial = Get-FastbootDevice
$knownDebianAdbSerials = @($TcpAdbSerial, $UpgradeUsbAdbSerial)
$selectedAdbSerial = $null
if ($adbDevices.Count -gt 1) {
    $unexpectedAdbDevices = @($adbDevices | Where-Object { $_ -notin $knownDebianAdbSerials })
    if ($unexpectedAdbDevices.Count -gt 0) {
        throw "检测到多个 ADB 设备，且包含未知设备：$($adbDevices -join ', ')"
    }
    if ($adbDevices -contains $TcpAdbSerial) {
        $selectedAdbSerial = $TcpAdbSerial
    } elseif ($adbDevices -contains $UpgradeUsbAdbSerial) {
        $selectedAdbSerial = $UpgradeUsbAdbSerial
    }
} elseif ($adbDevices.Count -eq 1) {
    $selectedAdbSerial = $adbDevices[0]
}
if ($selectedAdbSerial -and $fastbootSerial) { throw "同时检测到 ADB 和 fastboot 设备，拒绝继续" }

if ($selectedAdbSerial) {
    $debianProbe = Invoke-Native $Adb @(
        "-s", $selectedAdbSerial, "shell",
        'echo "hostname=$(hostname)"; echo "soc_id=$(cat /sys/devices/soc0/soc_id 2>/dev/null)"; echo "root=$(findmnt -nro SOURCE / 2>/dev/null)"; echo "boot_sectors=$(cat /sys/class/block/mmcblk0p20/size 2>/dev/null)"; echo "system_sectors=$(cat /sys/class/block/mmcblk0p21/size 2>/dev/null)"; test -x /system/bin/reboot && echo "reboot_compat=yes"'
    ) -AllowFailure
    $isDebian = $debianProbe.ExitCode -eq 0 -and
        $debianProbe.Text -match '(?m)^hostname=ufi210\r?$' -and
        $debianProbe.Text -match '(?m)^soc_id=245\r?$' -and
        $debianProbe.Text -match '(?m)^root=/dev/mmcblk0p21\r?$' -and
        $debianProbe.Text -match '(?m)^boot_sectors=65536\r?$' -and
        $debianProbe.Text -match '(?m)^system_sectors=2516584\r?$' -and
        $debianProbe.Text -match '(?m)^reboot_compat=yes\r?$'

    if ($isDebian) {
        if (-not $BootBackupPath) {
            $BootBackupPath = Join-Path $OutputDir "boot-before-install.img"
            Save-DebianBoot $selectedAdbSerial $BootBackupPath
        }
        $rebootResult = Invoke-Native $Adb @(
            "-s", $selectedAdbSerial, "shell", "/system/bin/reboot", "bootloader"
        ) -AllowFailure
        Write-Utf8File (Join-Path $OutputDir "debian-reboot-fastboot.txt") ((@(
            "exit_code=$($rebootResult.ExitCode)", $rebootResult.Text
        ) -join "`r`n") + "`r`n")
        $fastbootSerial = Wait-Fastboot $FastbootTimeoutSeconds
        if (-not $fastbootSerial) { throw "Debian 重启后 fastboot 未出现；尚未写入分区" }
    } else {
        $probe = Invoke-Native $Adb @(
            "-s", $selectedAdbSerial, "shell",
            'echo "device=$(getprop ro.product.device)"; echo "soc_id=$(cat /sys/devices/soc0/soc_id)"; echo "boot_completed=$(getprop sys.boot_completed)"; echo "boot_sectors=$(cat /sys/class/block/mmcblk0p20/size)"; echo "system_sectors=$(cat /sys/class/block/mmcblk0p21/size)"'
        )
        if ($probe.Text -notmatch '(?m)^device=msm8909\r?$' -or
            $probe.Text -notmatch '(?m)^soc_id=245\r?$' -or
            $probe.Text -notmatch '(?m)^boot_completed=1\r?$' -or
            $probe.Text -notmatch '(?m)^boot_sectors=65536\r?$' -or
            $probe.Text -notmatch '(?m)^system_sectors=2516584\r?$') {
            throw "目标 Android 身份或分区布局不匹配：`r`n$($probe.Text)"
        }
        if (-not $BootBackupPath) {
            $BootBackupPath = Join-Path $OutputDir "boot-before-install.img"
            Save-AndroidBoot $selectedAdbSerial $BootBackupPath
        }
        Invoke-Native $Adb @("-s", $selectedAdbSerial, "reboot", "bootloader") | Out-Null
        $fastbootSerial = Wait-Fastboot $FastbootTimeoutSeconds
        if (-not $fastbootSerial) { throw "Android 重启后 fastboot 未出现；尚未写入分区" }
    }
} elseif (-not $fastbootSerial) {
    throw "没有检测到唯一的目标 Android ADB 或 fastboot 设备"
} elseif (-not $ConfirmFastbootTarget) {
    throw "从 fastboot 直接开始时必须提供 -ConfirmFastbootTarget，并用 -BootBackupPath 指定本机 boot 备份"
} elseif (-not $BootBackupPath) {
    throw "从 fastboot 直接开始时必须使用 -BootBackupPath 指定当前设备的 boot 备份"
}

if (-not (Test-Path -LiteralPath $BootBackupPath -PathType Leaf) -or
    (Get-Item -LiteralPath $BootBackupPath).Length -ne $BootPartitionBytes) {
    throw "boot 备份不存在或尺寸不是 32 MiB：$BootBackupPath"
}
$bootBackupHash = (Get-FileHash -LiteralPath $BootBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()

$product = Get-FastbootVariable $fastbootSerial "product"
$bootSizeValue = Get-FastbootVariable $fastbootSerial "partition-size:boot" -AllowEmpty
if ([string]::IsNullOrWhiteSpace($bootSizeValue)) {
    $bootSize = $BootPartitionBytes
    $bootSizeSource = "32 MiB boot 备份"
} else {
    $bootSize = Get-HexBytes $bootSizeValue
    $bootSizeSource = "fastboot getvar"
}
$systemSize = Get-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:system")
if ($product -notmatch '(?i)^MSM8909$' -or
    $bootSize -ne $BootPartitionBytes -or $systemSize -ne $SystemPartitionBytes) {
    throw "fastboot 目标或分区布局不匹配：product=$product boot=$bootSize system=$systemSize"
}

Write-Utf8File (Join-Path $OutputDir "preflight.txt") ((@(
    "started_at=$(Get-Date -Format o)", "product=$product",
    "boot_partition_bytes=$bootSize", "boot_partition_size_source=$bootSizeSource",
    "system_partition_bytes=$systemSize",
    "rootfs_sha256=$rootfsHash", "boot_sha256=$bootHash",
    "boot_backup=$BootBackupPath", "boot_backup_sha256=$bootBackupHash"
) -join "`r`n") + "`r`n")

Write-Host "持久写入 Debian system rootfs。"
$flashSystem = Invoke-Native $Fastboot @("-s", $fastbootSerial, "flash", "system", $RootfsImage)
Write-Utf8File (Join-Path $OutputDir "flash-system.txt") ($flashSystem.Text + "`r`n")

Write-Host "持久写入已通过 QCDT 直启验证的 Debian boot。"
$flashBoot = Invoke-Native $Fastboot @("-s", $fastbootSerial, "flash", "boot", $BootImage)
Write-Utf8File (Join-Path $OutputDir "flash-boot.txt") ($flashBoot.Text + "`r`n")

Write-Host "从 RAM 启动同一镜像，验证已写入的 system rootfs。"
$ramBoot = Invoke-Native $Fastboot @("-s", $fastbootSerial, "boot", $BootImage)
Write-Utf8File (Join-Path $OutputDir "fastboot-boot.txt") ($ramBoot.Text + "`r`n")
Assert-DebianRuntime "first-boot"
$firstBootId = (Invoke-Native $Adb @(
    "-s", $TcpAdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id"
)).Text.Trim()
if ($firstBootId -notmatch '^[0-9a-f-]{36}$') { throw "无法读取首次启动 boot_id：$firstBootId" }

Write-Host "执行普通 warm reboot，验证持久 boot 无需插拔自动返回 Debian。"
Invoke-Native $Adb @("-s", $TcpAdbSerial, "shell", "sync; reboot") -AllowFailure | Out-Null
Wait-TcpAdbOffline 30
Assert-DebianRuntime "ordinary-reboot"
$secondBootId = (Invoke-Native $Adb @(
    "-s", $TcpAdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id"
)).Text.Trim()
if ($secondBootId -notmatch '^[0-9a-f-]{36}$' -or $secondBootId -eq $firstBootId) {
    throw "普通 reboot 后 boot_id 未变化：before=$firstBootId after=$secondBootId"
}

$summary = @(
    "UFI210 Debian 持久安装与重启验收通过",
    "persistent_partitions=boot,system",
    "root=/dev/mmcblk0p21", "reboot_mode=warm",
    "first_boot_id=$firstBootId", "ordinary_reboot_boot_id=$secondBootId",
    "boot_sha256=$bootHash", "rootfs_source_sha256=$rootfsHash",
    "boot_backup=$BootBackupPath", "boot_backup_sha256=$bootBackupHash",
    "ssh=${DeviceIp}:22", "adb_tcp=$TcpAdbSerial", "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
