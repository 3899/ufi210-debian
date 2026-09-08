[CmdletBinding()]
param(
    [switch]$ConfirmPersistentInstall,
    [switch]$ConfirmEraseCacheAndUserdata,
    [switch]$ConfirmFastbootTarget,
    [switch]$ValidateRecoveryOnly,
    [switch]$ResumePostInstallValidation,
    [string]$BootBackupPath = "",
    [string]$RecoveryBackupDirectory = "",
    [ValidateRange(60, 600)]
    [int]$LinuxTimeoutSeconds = 600,
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
$ArtifactRoot = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs"
$RootfsSystemImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-system.img"
$RootfsCacheImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-cache.img"
$RootfsUserdataImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-userdata.img"
$BootImage = Join-Path $ArtifactRoot "boot-debian-large-rootfs.img"
$ManifestPath = Join-Path $ArtifactRoot "BUILD-MANIFEST.txt"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$BootPartitionBytes = 33554432L
$SystemPartitionBytes = 1288491008L
$CachePartitionBytes = 268435456L
$UserdataPartitionBytes = 1928314368L
$LargeRootBytes = 3485240832L
$LargeRootFilesystemBytes = 3485237248L
$LargeRootFilesystemUuid = "89090000-0000-4000-8000-000000000031"
$DiskSectors = 7569408L
$PrimaryGptBytes = 17408L
$BackupGptBytes = 16896L
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
if (-not (Test-Path -LiteralPath $RootfsSystemImage -PathType Leaf)) {
    $ArtifactRoot = $ProjectRoot
    $RootfsSystemImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-system.img"
    $RootfsCacheImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-cache.img"
    $RootfsUserdataImage = Join-Path $ArtifactRoot "debian-bookworm-armhf-large-rootfs-userdata.img"
    $BootImage = Join-Path $ArtifactRoot "boot-debian-large-rootfs.img"
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
    $result = Invoke-Native -Executable $Adb -CommandArgs @("devices", "-l") -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($AllowFailure) { return @() }
        throw "无法枚举 ADB 设备：`r`n$($result.Text)"
    }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device(?:\s+.*)?$') { $Matches[1] }
    })
}

function Get-FastbootDevice {
    $result = Invoke-Native -Executable $Fastboot -CommandArgs @("devices") -AllowFailure
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
        Invoke-Native -Executable $Adb -CommandArgs @("connect", $TcpAdbSerial) -AllowFailure | Out-Null
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
    $result = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $Serial, "getvar", $Name) -AllowFailure
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

function Get-UInt32LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-UInt64LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt64($Bytes, $Offset)
}

function Get-Crc32 {
    param([byte[]]$Bytes)
    [long]$crc = 0xffffffffL
    foreach ($value in $Bytes) {
        $crc = ($crc -bxor [long]$value) -band 0xffffffffL
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 1) -ne 0) {
                $crc = (($crc -shr 1) -bxor 0xedb88320L) -band 0xffffffffL
            } else {
                $crc = ($crc -shr 1) -band 0xffffffffL
            }
        }
    }
    return ((-bnot $crc) -band 0xffffffffL)
}

function Assert-GptBackups {
    param([string]$Directory)
    $primaryPath = Join-Path $Directory "gpt-primary.bin"
    $backupPath = Join-Path $Directory "gpt-backup.bin"
    foreach ($item in @(
        @{ Path = $primaryPath; Bytes = $PrimaryGptBytes },
        @{ Path = $backupPath; Bytes = $BackupGptBytes }
    )) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or
            (Get-Item -LiteralPath $item.Path).Length -ne $item.Bytes) {
            throw "GPT 备份不存在或尺寸错误：$($item.Path)"
        }
    }

    [byte[]]$primary = [IO.File]::ReadAllBytes($primaryPath)
    [byte[]]$backup = [IO.File]::ReadAllBytes($backupPath)
    $signature = [Text.Encoding]::ASCII.GetBytes("EFI PART")
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($primary[512 + $index] -ne $signature[$index] -or
            $backup[16384 + $index] -ne $signature[$index]) {
            throw "主 GPT 或备 GPT 签名错误"
        }
    }

    $primaryHeaderSize = Get-UInt32LE $primary 524
    $backupHeaderSize = Get-UInt32LE $backup 16396
    if ($primaryHeaderSize -ne 92 -or $backupHeaderSize -ne 92) {
        throw "GPT header_size 不是 92"
    }
    [byte[]]$primaryHeader = New-Object byte[] $primaryHeaderSize
    [byte[]]$backupHeader = New-Object byte[] $backupHeaderSize
    [Array]::Copy($primary, 512, $primaryHeader, 0, $primaryHeaderSize)
    [Array]::Copy($backup, 16384, $backupHeader, 0, $backupHeaderSize)
    $primaryHeaderCrc = Get-UInt32LE $primaryHeader 16
    $backupHeaderCrc = Get-UInt32LE $backupHeader 16
    [Array]::Clear($primaryHeader, 16, 4)
    [Array]::Clear($backupHeader, 16, 4)
    if ((Get-Crc32 $primaryHeader) -ne $primaryHeaderCrc -or
        (Get-Crc32 $backupHeader) -ne $backupHeaderCrc) {
        throw "主 GPT 或备 GPT header CRC32 错误"
    }

    if ((Get-UInt64LE $primary 536) -ne 1 -or
        (Get-UInt64LE $primary 544) -ne ($DiskSectors - 1) -or
        (Get-UInt64LE $primary 552) -ne 34 -or
        (Get-UInt64LE $primary 560) -ne 7569374 -or
        (Get-UInt64LE $primary 584) -ne 2 -or
        (Get-UInt32LE $primary 592) -ne 32 -or
        (Get-UInt32LE $primary 596) -ne 128) {
        throw "主 GPT header 几何不匹配"
    }
    if ((Get-UInt64LE $backup 16408) -ne ($DiskSectors - 1) -or
        (Get-UInt64LE $backup 16416) -ne 1 -or
        (Get-UInt64LE $backup 16424) -ne 34 -or
        (Get-UInt64LE $backup 16432) -ne 7569374 -or
        (Get-UInt64LE $backup 16456) -ne 7569375 -or
        (Get-UInt32LE $backup 16464) -ne 32 -or
        (Get-UInt32LE $backup 16468) -ne 128) {
        throw "备 GPT header 几何不匹配"
    }

    for ($index = 0; $index -lt 16; $index++) {
        if ($primary[568 + $index] -ne $backup[16440 + $index]) {
            throw "主备 GPT 磁盘 GUID 不一致"
        }
    }
    [byte[]]$primaryEntries = New-Object byte[] 4096
    [byte[]]$backupEntries = New-Object byte[] 4096
    [Array]::Copy($primary, 1024, $primaryEntries, 0, 4096)
    [Array]::Copy($backup, 0, $backupEntries, 0, 4096)
    $entriesCrc = Get-UInt32LE $primary 600
    if ((Get-Crc32 $primaryEntries) -ne $entriesCrc -or
        (Get-UInt32LE $backup 16472) -ne $entriesCrc -or
        (Get-Crc32 $backupEntries) -ne $entriesCrc) {
        throw "主 GPT 或备 GPT partition array CRC32 错误"
    }
    for ($index = 0; $index -lt 4096; $index++) {
        if ($primaryEntries[$index] -ne $backupEntries[$index]) {
            throw "主备 GPT 分区条目不一致"
        }
    }

    $expectedPartitions = @(
        @{ Number = 1; Name = "modem"; Start = 131072L; Last = 262143L },
        @{ Number = 2; Name = "sbl1"; Start = 262144L; Last = 263167L },
        @{ Number = 3; Name = "sbl1bak"; Start = 263168L; Last = 264191L },
        @{ Number = 4; Name = "aboot"; Start = 264192L; Last = 266239L },
        @{ Number = 5; Name = "abootbak"; Start = 266240L; Last = 268287L },
        @{ Number = 6; Name = "rpm"; Start = 268288L; Last = 269311L },
        @{ Number = 7; Name = "rpmbak"; Start = 269312L; Last = 270335L },
        @{ Number = 8; Name = "tz"; Start = 270336L; Last = 271871L },
        @{ Number = 9; Name = "tzbak"; Start = 271872L; Last = 273407L },
        @{ Number = 10; Name = "pad"; Start = 273408L; Last = 275455L },
        @{ Number = 11; Name = "modemst1"; Start = 275456L; Last = 278527L },
        @{ Number = 12; Name = "modemst2"; Start = 278528L; Last = 281599L },
        @{ Number = 13; Name = "misc"; Start = 281600L; Last = 283647L },
        @{ Number = 14; Name = "fsc"; Start = 283648L; Last = 283649L },
        @{ Number = 15; Name = "ssd"; Start = 283650L; Last = 283665L },
        @{ Number = 16; Name = "splash"; Start = 283666L; Last = 304145L },
        @{ Number = 17; Name = "DDR"; Start = 393216L; Last = 393279L },
        @{ Number = 18; Name = "fsg"; Start = 393280L; Last = 396351L },
        @{ Number = 19; Name = "sec"; Start = 396352L; Last = 396383L },
        @{ Number = 20; Name = "boot"; Start = 396384L; Last = 461919L },
        @{ Number = 21; Name = "system"; Start = 461920L; Last = 2978503L },
        @{ Number = 22; Name = "persist"; Start = 2978504L; Last = 3044039L },
        @{ Number = 23; Name = "cache"; Start = 3044040L; Last = 3568327L },
        @{ Number = 24; Name = "recovery"; Start = 3568328L; Last = 3633863L },
        @{ Number = 25; Name = "devinfo"; Start = 3633864L; Last = 3635911L },
        @{ Number = 26; Name = "keystore"; Start = 3670016L; Last = 3671039L },
        @{ Number = 27; Name = "oem"; Start = 3671040L; Last = 3802111L },
        @{ Number = 28; Name = "config"; Start = 3802112L; Last = 3803135L },
        @{ Number = 29; Name = "userdata"; Start = 3803136L; Last = 7569374L }
    )
    foreach ($expected in $expectedPartitions) {
        $offset = 1024 + (($expected.Number - 1) * 128)
        $name = [Text.Encoding]::Unicode.GetString($primary, $offset + 56, 72).Trim([char]0)
        if ($name -ne $expected.Name -or
            (Get-UInt64LE $primary ($offset + 32)) -ne $expected.Start -or
            (Get-UInt64LE $primary ($offset + 40)) -ne $expected.Last) {
            throw "GPT 第 $($expected.Number) 分区几何不匹配：$name"
        }
    }

    return [pscustomobject]@{
        PrimaryPath = $primaryPath
        BackupPath = $backupPath
        PrimarySha256 = (Get-FileHash -LiteralPath $primaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        BackupSha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Save-AndroidBoot {
    param([string]$Serial, [string]$Destination)
    $remote = "/data/local/tmp/ufi210-boot-backup.img"
    Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $Serial, "shell",
        "su -c 'dd if=/dev/block/bootdevice/by-name/boot of=$remote bs=1048576 2>/dev/null && chmod 0644 $remote'"
    ) | Out-Null
    try {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "pull", $remote, $Destination) | Out-Null
    } finally {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "shell", "su -c 'rm -f $remote'") -AllowFailure | Out-Null
    }
    if ((Get-Item -LiteralPath $Destination).Length -ne $BootPartitionBytes) {
        throw "boot 备份尺寸错误：$Destination"
    }
}

function Save-DebianBoot {
    param([string]$Serial, [string]$Destination)
    $remote = "/tmp/ufi210-boot-backup.img"
    Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $Serial, "shell",
        "dd if=/dev/mmcblk0p20 of=$remote bs=1048576 2>/dev/null && chmod 0644 $remote"
    ) | Out-Null
    try {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "pull", $remote, $Destination) | Out-Null
    } finally {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "shell", "rm -f $remote") -AllowFailure | Out-Null
    }
    if ((Get-Item -LiteralPath $Destination).Length -ne $BootPartitionBytes) {
        throw "boot 备份尺寸错误：$Destination"
    }
}

function Save-GptBackups {
    param([string]$Serial, [string]$Destination, [switch]$Android)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $primary = Join-Path $Destination "gpt-primary.bin"
    $backup = Join-Path $Destination "gpt-backup.bin"
    if ($Android) {
        $remoteRoot = "/data/local/tmp/ufi210-recovery"
        $create = "su -c 'mkdir -p $remoteRoot && dd if=/dev/block/mmcblk0 of=$remoteRoot/gpt-primary.bin bs=512 count=34 2>/dev/null && dd if=/dev/block/mmcblk0 of=$remoteRoot/gpt-backup.bin bs=512 skip=7569375 count=33 2>/dev/null && chmod 0644 $remoteRoot/gpt-primary.bin $remoteRoot/gpt-backup.bin'"
        $cleanup = "su -c 'rm -rf $remoteRoot'"
    } else {
        $remoteRoot = "/tmp/ufi210-recovery"
        $create = "mkdir -p $remoteRoot && dd if=/dev/mmcblk0 of=$remoteRoot/gpt-primary.bin bs=512 count=34 2>/dev/null && dd if=/dev/mmcblk0 of=$remoteRoot/gpt-backup.bin bs=512 skip=7569375 count=33 2>/dev/null && chmod 0644 $remoteRoot/gpt-primary.bin $remoteRoot/gpt-backup.bin"
        $cleanup = "rm -rf $remoteRoot"
    }
    Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "shell", $create) | Out-Null
    try {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "pull", "$remoteRoot/gpt-primary.bin", $primary) | Out-Null
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "pull", "$remoteRoot/gpt-backup.bin", $backup) | Out-Null
    } finally {
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $Serial, "shell", $cleanup) -AllowFailure | Out-Null
    }
    return Assert-GptBackups $Destination
}

if ($ValidateRecoveryOnly) {
    if (-not $RecoveryBackupDirectory) {
        throw "-ValidateRecoveryOnly 必须同时指定 -RecoveryBackupDirectory"
    }
    $validated = Assert-GptBackups $RecoveryBackupDirectory
    Write-Host "设备 GPT 恢复基线校验通过"
    Write-Host "primary_sha256=$($validated.PrimarySha256)"
    Write-Host "backup_sha256=$($validated.BackupSha256)"
    return
}

function Assert-DebianRuntime {
    param([string]$Phase)
    Wait-TcpAdb $LinuxTimeoutSeconds
    $command = @'
set -eu
test "$(cat /sys/devices/soc0/soc_id)" = 245
test "$(hostname)" = ufi210
test "$(findmnt -nro SOURCE /)" = /dev/mapper/ufi210-root
test "$(findmnt -nro FSTYPE /)" = ext4
test "$(findmnt -nro UUID /)" = __ROOT_FILESYSTEM_UUID__
test "$(cat /sys/kernel/reboot/mode)" = warm
test "$(blockdev --getsize64 /dev/mapper/ufi210-root)" = __ROOT_DEVICE_BYTES__
test "$(dmsetup table ufi210-root | wc -l)" = 3
system_dev=$(cat /sys/class/block/mmcblk0p21/dev)
cache_dev=$(cat /sys/class/block/mmcblk0p23/dev)
userdata_dev=$(cat /sys/class/block/mmcblk0p29/dev)
dmsetup table ufi210-root | awk -v system_dev="$system_dev" -v cache_dev="$cache_dev" -v userdata_dev="$userdata_dev" '
NR == 1 {ok = ($1 == 0 && $2 == 2516584 && $3 == "linear" && $4 == system_dev && $5 == 0)}
NR == 2 {ok = ok && ($1 == 2516584 && $2 == 524288 && $3 == "linear" && $4 == cache_dev && $5 == 0)}
NR == 3 {ok = ok && ($1 == 3040872 && $2 == 3766239 && $3 == "linear" && $4 == userdata_dev && $5 == 0)}
END {exit !ok}'
test "$(cat /sys/class/block/mmcblk0p21/start)" = 461920
test "$(cat /sys/class/block/mmcblk0p21/size)" = 2516584
test "$(cat /sys/class/block/mmcblk0p23/start)" = 3044040
test "$(cat /sys/class/block/mmcblk0p23/size)" = 524288
test "$(cat /sys/class/block/mmcblk0p29/start)" = 3803136
test "$(cat /sys/class/block/mmcblk0p29/size)" = 3766239
boot_prefix_hash=$(head -c __BOOT_IMAGE_BYTES__ /dev/mmcblk0p20 | sha256sum | cut -d ' ' -f1)
test "$boot_prefix_hash" = __BOOT_IMAGE_SHA256__
fs_block_count=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block count:[[:space:]]*//p')
fs_block_size=$(dumpe2fs -h /dev/mapper/ufi210-root 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
test "$fs_block_count" -gt 0
test "$fs_block_size" -gt 0
test "$((fs_block_count * fs_block_size))" = __ROOT_FILESYSTEM_BYTES__
! mountpoint -q /data
test "$(stat -c %a /data/local/tmp)" = 1777
root_probe="/var/tmp/.ufi210-install-write-test-$$"
printf 'ok\n' > "$root_probe"
test "$(cat "$root_probe")" = ok
rm -f "$root_probe"
systemctl is-active NetworkManager ssh adbd zu02-usb-watchdog.timer zu02-wcnss zu02-mpss ModemManager fstrim.timer
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
echo LARGE_ROOTFS_RUNTIME_OK
'@
    $command = $command.Replace("__BOOT_IMAGE_BYTES__", "$((Get-Item -LiteralPath $BootImage).Length)")
    $command = $command.Replace("__BOOT_IMAGE_SHA256__", $bootHash)
    $command = $command.Replace("__ROOT_FILESYSTEM_UUID__", $LargeRootFilesystemUuid)
    $command = $command.Replace("__ROOT_DEVICE_BYTES__", "$LargeRootBytes")
    $command = $command.Replace("__ROOT_FILESYSTEM_BYTES__", "$LargeRootFilesystemBytes")
    $commandBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
    $remoteCommand = "printf %s $commandBase64 | base64 -d | /bin/sh"
    $deadline = (Get-Date).AddSeconds($LinuxTimeoutSeconds)
    $attempt = 0
    do {
        $attempt++
        $result = Invoke-Native -Executable $Adb -CommandArgs @(
            "-s", $TcpAdbSerial, "shell", $remoteCommand
        ) -AllowFailure
        if ($result.ExitCode -eq 0 -and $result.Text -match '(?m)^LARGE_ROOTFS_RUNTIME_OK\r?$') {
            Write-Utf8File (Join-Path $OutputDir "runtime-$Phase.txt") ($result.Text + "`r`n")
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Debian 大根卷运行验收失败：$Phase`r`nattempts=$attempt`r`nlast_exit_code=$($result.ExitCode)`r`nlogs=$OutputDir`r`n$($result.Text)"
}

function Invoke-PersistentRuntimeValidation {
    param([string]$InitialPhase)

    Assert-DebianRuntime $InitialPhase
    $firstBootId = (Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $TcpAdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id"
    )).Text.Trim()
    if ($firstBootId -notmatch '^[0-9a-f-]{36}$') {
        throw "无法读取首次启动 boot_id：$firstBootId"
    }

    Write-Host "执行普通 warm reboot，验证持久 boot 无需插拔自动返回 Debian。"
    Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $TcpAdbSerial, "shell", "sync; reboot"
    ) -AllowFailure | Out-Null
    Wait-TcpAdbOffline 30
    Assert-DebianRuntime "ordinary-reboot"
    $secondBootId = (Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $TcpAdbSerial, "shell", "cat /proc/sys/kernel/random/boot_id"
    )).Text.Trim()
    if ($secondBootId -notmatch '^[0-9a-f-]{36}$' -or $secondBootId -eq $firstBootId) {
        throw "普通 reboot 后 boot_id 未变化：before=$firstBootId after=$secondBootId"
    }

    return [pscustomobject]@{
        FirstBootId = $firstBootId
        SecondBootId = $secondBootId
    }
}

foreach ($tool in @($Adb, $Fastboot)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "缺少工具：$tool" }
}
if (-not $ResumePostInstallValidation) {
    if (-not $ConfirmPersistentInstall) {
        throw "本脚本会持久覆盖 system、cache、userdata 和 boot；确认目标和恢复准备后使用 -ConfirmPersistentInstall"
    }
    if (-not $ConfirmEraseCacheAndUserdata) {
        throw "本脚本会永久清除 cache 和 userdata 的全部原有内容；确认无需保留后使用 -ConfirmEraseCacheAndUserdata"
    }
}

$manifest = Read-KeyValues $ManifestPath
$required = [ordered]@{
    architecture = "armhf"
    hostname = "ufi210"
    target_partition = "large-rootfs"
    target_partition_bytes = "$LargeRootBytes"
    rootfs_device = "/dev/mapper/ufi210-root"
    rootfs_label = "ufi210-root"
    rootfs_auto_grow = "disabled"
    rootfs_segments = "complete-prebuilt-filesystem"
    data_mount = "none"
    adbd_shell_tmpdir = "/data/local/tmp"
    adbd_shell_tmpdir_storage = "rootfs"
    storage_layout = "dm-linear-system-cache-userdata"
    dm_name = "ufi210-root"
    dm_total_sectors = "6807111"
    dm_total_bytes = "$LargeRootBytes"
    dm_filesystem_bytes = "$LargeRootFilesystemBytes"
    dm_system_sectors = "2516584"
    dm_cache_sectors = "524288"
    dm_userdata_sectors = "3766239"
    dm_system_start = "461920"
    dm_cache_start = "3044040"
    dm_userdata_start = "3803136"
    dm_table = "0 2516584 linear PARTLABEL=system 0;2516584 524288 linear PARTLABEL=cache 0;3040872 3766239 linear PARTLABEL=userdata 0"
    gpt_changes = "none"
    cache_previous_contents = "erased-by-installer"
    userdata_previous_contents = "erased-by-installer"
    fstrim = "weekly-systemd-timer"
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
$rootfsSystemHash = Assert-Hash $RootfsSystemImage $manifest.rootfs_system_image_sha256
$rootfsCacheHash = Assert-Hash $RootfsCacheImage $manifest.rootfs_cache_image_sha256
$rootfsUserdataHash = Assert-Hash $RootfsUserdataImage $manifest.rootfs_userdata_image_sha256
$bootHash = Assert-Hash $BootImage $manifest.boot_image_sha256
if ((Get-Item -LiteralPath $RootfsSystemImage).Length -ne $SystemPartitionBytes) {
    throw "system 根卷分段大小错误"
}
if ((Get-Item -LiteralPath $RootfsCacheImage).Length -ne $CachePartitionBytes) {
    throw "cache 根卷分段大小错误"
}
if ((Get-Item -LiteralPath $RootfsUserdataImage).Length -ne
    ($LargeRootFilesystemBytes - $SystemPartitionBytes - $CachePartitionBytes)) {
    throw "userdata 根卷分段大小错误"
}
if ((Get-Item -LiteralPath $BootImage).Length -ge $BootPartitionBytes) {
    throw "boot image 不小于 boot 分区"
}

if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\persistent-install" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if ($ResumePostInstallValidation) {
    if (-not $BootBackupPath -or -not $RecoveryBackupDirectory) {
        throw "恢复安装后验收必须同时指定 -BootBackupPath 和 -RecoveryBackupDirectory"
    }
    if (-not (Test-Path -LiteralPath $BootBackupPath -PathType Leaf) -or
        (Get-Item -LiteralPath $BootBackupPath).Length -ne $BootPartitionBytes) {
        throw "boot 备份不存在或尺寸不是 32 MiB：$BootBackupPath"
    }
    $bootBackupHash = (Get-FileHash -LiteralPath $BootBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $gptBackup = Assert-GptBackups $RecoveryBackupDirectory
    Invoke-Native -Executable $Adb -CommandArgs @("connect", $TcpAdbSerial) -AllowFailure | Out-Null
    $resumeAdbDevices = @(Get-AdbDevices)
    if ($resumeAdbDevices.Count -ne 1 -or $resumeAdbDevices[0] -ne $TcpAdbSerial) {
        throw "恢复安装后验收只允许目标 TCP ADB 在线：$($resumeAdbDevices -join ', ')"
    }
    if (Get-FastbootDevice) {
        throw "恢复安装后验收检测到 Fastboot 设备，拒绝继续"
    }

    $runtime = Invoke-PersistentRuntimeValidation "resume-current"
    $summary = @(
        "UFI210 Debian 大根卷持久安装恢复验收通过",
        "validation_mode=resume-post-install-no-flash",
        "persistent_partitions=boot,system,cache,userdata", "gpt_changes=none",
        "root=/dev/mapper/ufi210-root", "root_bytes=$LargeRootBytes", "reboot_mode=warm",
        "first_boot_id=$($runtime.FirstBootId)", "ordinary_reboot_boot_id=$($runtime.SecondBootId)",
        "boot_sha256=$bootHash", "rootfs_logical_sha256=$($manifest.rootfs_image_sha256)",
        "rootfs_system_sha256=$rootfsSystemHash", "rootfs_cache_sha256=$rootfsCacheHash",
        "rootfs_userdata_sha256=$rootfsUserdataHash",
        "boot_backup=$BootBackupPath", "boot_backup_sha256=$bootBackupHash",
        "gpt_primary_sha256=$($gptBackup.PrimarySha256)", "gpt_backup_sha256=$($gptBackup.BackupSha256)",
        "ssh=${DeviceIp}:22", "adb_tcp=$TcpAdbSerial", "logs=$OutputDir"
    ) -join "`r`n"
    Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
    Write-Host $summary
    return
}

Invoke-Native -Executable $Adb -CommandArgs @("connect", $TcpAdbSerial) -AllowFailure | Out-Null
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
    $debianProbe = Invoke-Native -Executable $Adb -CommandArgs @(
        "-s", $selectedAdbSerial, "shell",
        'echo "hostname=$(hostname)"; echo "soc_id=$(cat /sys/devices/soc0/soc_id 2>/dev/null)"; echo "root=$(findmnt -nro SOURCE / 2>/dev/null)"; echo "disk_sectors=$(cat /sys/class/block/mmcblk0/size 2>/dev/null)"; echo "boot_start=$(cat /sys/class/block/mmcblk0p20/start 2>/dev/null)"; echo "boot_sectors=$(cat /sys/class/block/mmcblk0p20/size 2>/dev/null)"; echo "system_start=$(cat /sys/class/block/mmcblk0p21/start 2>/dev/null)"; echo "system_sectors=$(cat /sys/class/block/mmcblk0p21/size 2>/dev/null)"; echo "cache_start=$(cat /sys/class/block/mmcblk0p23/start 2>/dev/null)"; echo "cache_sectors=$(cat /sys/class/block/mmcblk0p23/size 2>/dev/null)"; echo "userdata_start=$(cat /sys/class/block/mmcblk0p29/start 2>/dev/null)"; echo "userdata_sectors=$(cat /sys/class/block/mmcblk0p29/size 2>/dev/null)"; test -x /system/bin/reboot && echo "reboot_compat=yes"'
    ) -AllowFailure
    $isDebian = $debianProbe.ExitCode -eq 0 -and
        $debianProbe.Text -match '(?m)^hostname=ufi210\r?$' -and
        $debianProbe.Text -match '(?m)^soc_id=245\r?$' -and
        $debianProbe.Text -match '(?m)^root=(?:/dev/mmcblk0p21|/dev/mapper/ufi210-root)\r?$' -and
        $debianProbe.Text -match '(?m)^disk_sectors=7569408\r?$' -and
        $debianProbe.Text -match '(?m)^boot_start=396384\r?$' -and
        $debianProbe.Text -match '(?m)^boot_sectors=65536\r?$' -and
        $debianProbe.Text -match '(?m)^system_start=461920\r?$' -and
        $debianProbe.Text -match '(?m)^system_sectors=2516584\r?$' -and
        $debianProbe.Text -match '(?m)^cache_start=3044040\r?$' -and
        $debianProbe.Text -match '(?m)^cache_sectors=524288\r?$' -and
        $debianProbe.Text -match '(?m)^userdata_start=3803136\r?$' -and
        $debianProbe.Text -match '(?m)^userdata_sectors=3766239\r?$' -and
        $debianProbe.Text -match '(?m)^reboot_compat=yes\r?$'

    if ($isDebian) {
        if (-not $BootBackupPath) {
            $BootBackupPath = Join-Path $OutputDir "boot-before-install.img"
            Save-DebianBoot $selectedAdbSerial $BootBackupPath
        }
        if (-not $RecoveryBackupDirectory) {
            $RecoveryBackupDirectory = Join-Path $OutputDir "device-recovery"
            $gptBackup = Save-GptBackups $selectedAdbSerial $RecoveryBackupDirectory
        } else {
            $gptBackup = Assert-GptBackups $RecoveryBackupDirectory
        }
        $rebootResult = Invoke-Native -Executable $Adb -CommandArgs @(
            "-s", $selectedAdbSerial, "shell", "/system/bin/reboot", "bootloader"
        ) -AllowFailure
        Write-Utf8File (Join-Path $OutputDir "debian-reboot-fastboot.txt") ((@(
            "exit_code=$($rebootResult.ExitCode)", $rebootResult.Text
        ) -join "`r`n") + "`r`n")
        $fastbootSerial = Wait-Fastboot $FastbootTimeoutSeconds
        if (-not $fastbootSerial) { throw "Debian 重启后 fastboot 未出现；尚未写入分区" }
    } else {
        $probe = Invoke-Native -Executable $Adb -CommandArgs @(
            "-s", $selectedAdbSerial, "shell",
            'echo "device=$(getprop ro.product.device)"; echo "soc_id=$(cat /sys/devices/soc0/soc_id)"; echo "boot_completed=$(getprop sys.boot_completed)"; echo "disk_sectors=$(cat /sys/class/block/mmcblk0/size)"; echo "boot_start=$(cat /sys/class/block/mmcblk0p20/start)"; echo "boot_sectors=$(cat /sys/class/block/mmcblk0p20/size)"; echo "system_start=$(cat /sys/class/block/mmcblk0p21/start)"; echo "system_sectors=$(cat /sys/class/block/mmcblk0p21/size)"; echo "cache_start=$(cat /sys/class/block/mmcblk0p23/start)"; echo "cache_sectors=$(cat /sys/class/block/mmcblk0p23/size)"; echo "userdata_start=$(cat /sys/class/block/mmcblk0p29/start)"; echo "userdata_sectors=$(cat /sys/class/block/mmcblk0p29/size)"'
        )
        if ($probe.Text -notmatch '(?m)^device=msm8909\r?$' -or
            $probe.Text -notmatch '(?m)^soc_id=245\r?$' -or
            $probe.Text -notmatch '(?m)^boot_completed=1\r?$' -or
            $probe.Text -notmatch '(?m)^disk_sectors=7569408\r?$' -or
            $probe.Text -notmatch '(?m)^boot_start=396384\r?$' -or
            $probe.Text -notmatch '(?m)^boot_sectors=65536\r?$' -or
            $probe.Text -notmatch '(?m)^system_start=461920\r?$' -or
            $probe.Text -notmatch '(?m)^system_sectors=2516584\r?$' -or
            $probe.Text -notmatch '(?m)^cache_start=3044040\r?$' -or
            $probe.Text -notmatch '(?m)^cache_sectors=524288\r?$' -or
            $probe.Text -notmatch '(?m)^userdata_start=3803136\r?$' -or
            $probe.Text -notmatch '(?m)^userdata_sectors=3766239\r?$') {
            throw "目标 Android 身份或分区布局不匹配：`r`n$($probe.Text)"
        }
        if (-not $BootBackupPath) {
            $BootBackupPath = Join-Path $OutputDir "boot-before-install.img"
            Save-AndroidBoot $selectedAdbSerial $BootBackupPath
        }
        if (-not $RecoveryBackupDirectory) {
            $RecoveryBackupDirectory = Join-Path $OutputDir "device-recovery"
            $gptBackup = Save-GptBackups $selectedAdbSerial $RecoveryBackupDirectory -Android
        } else {
            $gptBackup = Assert-GptBackups $RecoveryBackupDirectory
        }
        Invoke-Native -Executable $Adb -CommandArgs @("-s", $selectedAdbSerial, "reboot", "bootloader") | Out-Null
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
if (-not $selectedAdbSerial) {
    if (-not $RecoveryBackupDirectory) {
        throw "从 fastboot 直接开始时必须使用 -RecoveryBackupDirectory 指定当前设备的主备 GPT 回读目录"
    }
    $gptBackup = Assert-GptBackups $RecoveryBackupDirectory
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
$cacheSize = Get-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:cache")
$dataSize = Get-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:userdata")
if ($product -notmatch '(?i)^MSM8909$' -or
    $bootSize -ne $BootPartitionBytes -or $systemSize -ne $SystemPartitionBytes -or
    $cacheSize -ne $CachePartitionBytes -or $dataSize -ne $UserdataPartitionBytes) {
    throw "fastboot 目标或分区布局不匹配：product=$product boot=$bootSize system=$systemSize cache=$cacheSize userdata=$dataSize"
}

Write-Utf8File (Join-Path $OutputDir "preflight.txt") ((@(
    "started_at=$(Get-Date -Format o)", "product=$product",
    "boot_partition_bytes=$bootSize", "boot_partition_size_source=$bootSizeSource",
    "system_partition_bytes=$systemSize",
    "cache_partition_bytes=$cacheSize",
    "userdata_partition_bytes=$dataSize",
    "disk_sectors=$DiskSectors", "gpt_changes=none",
    "rootfs_logical_sha256=$($manifest.rootfs_image_sha256)",
    "rootfs_system_sha256=$rootfsSystemHash", "rootfs_cache_sha256=$rootfsCacheHash",
    "rootfs_userdata_sha256=$rootfsUserdataHash", "boot_sha256=$bootHash",
    "boot_backup=$BootBackupPath", "boot_backup_sha256=$bootBackupHash",
    "gpt_primary_backup=$($gptBackup.PrimaryPath)", "gpt_primary_sha256=$($gptBackup.PrimarySha256)",
    "gpt_backup_backup=$($gptBackup.BackupPath)", "gpt_backup_sha256=$($gptBackup.BackupSha256)"
) -join "`r`n") + "`r`n")

Write-Host "清除 system、cache 和 userdata 原有内容；GPT 保持不变。"
$eraseSystem = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "erase", "system")
Write-Utf8File (Join-Path $OutputDir "erase-system.txt") ($eraseSystem.Text + "`r`n")
$eraseCache = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "erase", "cache")
Write-Utf8File (Join-Path $OutputDir "erase-cache.txt") ($eraseCache.Text + "`r`n")
$eraseData = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "erase", "userdata")
Write-Utf8File (Join-Path $OutputDir "erase-userdata.txt") ($eraseData.Text + "`r`n")

Write-Host "写入预构建 Debian 大根卷的 system、cache 和 userdata 三个分段。"
$flashSystem = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "flash", "system", $RootfsSystemImage)
Write-Utf8File (Join-Path $OutputDir "flash-system.txt") ($flashSystem.Text + "`r`n")
$flashCache = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "flash", "cache", $RootfsCacheImage)
Write-Utf8File (Join-Path $OutputDir "flash-cache.txt") ($flashCache.Text + "`r`n")
$flashData = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "flash", "userdata", $RootfsUserdataImage)
Write-Utf8File (Join-Path $OutputDir "flash-userdata.txt") ($flashData.Text + "`r`n")

Write-Host "持久写入已通过 QCDT 直启验证的 Debian boot。"
$flashBoot = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "flash", "boot", $BootImage)
Write-Utf8File (Join-Path $OutputDir "flash-boot.txt") ($flashBoot.Text + "`r`n")

Write-Host "从 RAM 启动同一镜像，验证 dm-linear 大根卷。"
$ramBoot = Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "boot", $BootImage)
Write-Utf8File (Join-Path $OutputDir "fastboot-boot.txt") ($ramBoot.Text + "`r`n")
$runtime = Invoke-PersistentRuntimeValidation "first-boot"

$summary = @(
    "UFI210 Debian 大根卷持久安装与重启验收通过",
    "persistent_partitions=boot,system,cache,userdata", "gpt_changes=none",
    "root=/dev/mapper/ufi210-root", "root_bytes=$LargeRootBytes", "reboot_mode=warm",
    "first_boot_id=$($runtime.FirstBootId)", "ordinary_reboot_boot_id=$($runtime.SecondBootId)",
    "boot_sha256=$bootHash", "rootfs_logical_sha256=$($manifest.rootfs_image_sha256)",
    "rootfs_system_sha256=$rootfsSystemHash", "rootfs_cache_sha256=$rootfsCacheHash",
    "rootfs_userdata_sha256=$rootfsUserdataHash",
    "boot_backup=$BootBackupPath", "boot_backup_sha256=$bootBackupHash",
    "gpt_primary_sha256=$($gptBackup.PrimarySha256)", "gpt_backup_sha256=$($gptBackup.BackupSha256)",
    "ssh=${DeviceIp}:22", "adb_tcp=$TcpAdbSerial", "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
