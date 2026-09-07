[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int]$FastbootTimeoutSeconds = 90,
    [ValidateRange(30, 300)]
    [int]$RescueTimeoutSeconds = 120,
    [ValidateRange(60, 600)]
    [int]$DebianTimeoutSeconds = 240,
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$ArtifactRoot = "",
    [string]$OutputRoot = "",
    [switch]$PrepareOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $ArtifactRoot) {
    $ArtifactRoot = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs"
}
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test"
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$BootImage = Join-Path $ArtifactRoot "boot-debian-large-rootfs.img"
$ManifestPath = Join-Path $ArtifactRoot "BUILD-MANIFEST.txt"
$AnalyzeBoot = Join-Path $ProjectRoot "scripts\analyze_bootimg.py"
$RepackBoot = Join-Path $ProjectRoot "scripts\repack_android_boot.py"
$Adb = Join-Path $ProjectRoot "adb.exe"
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$MissingPartLabel = "absent"
$OutputDir = Join-Path $OutputRoot ("initramfs-rescue-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$RescueImage = Join-Path $OutputDir "boot-initramfs-rescue-test.img"
$EnteredTemporaryBoot = $false
$ReturnedToDebian = $false

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Resolve-Tool {
    param([string]$BundledPath, [string]$CommandName)
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) { return $BundledPath }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "缺少工具：$CommandName"
}

function Resolve-Python {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        return [pscustomobject]@{ Path = $launcher.Source; Prefix = @("-3") }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) {
        return [pscustomobject]@{ Path = $python.Source; Prefix = @() }
    }
    throw "缺少 Python 3"
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$CommandArgs, [switch]$AllowFailure)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$([IO.Path]::GetFileName($FilePath)) 失败（$exitCode）：`r`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Invoke-Python {
    param([string[]]$CommandArgs)
    return Invoke-Native $Python.Path @($Python.Prefix + $CommandArgs)
}

function Read-KeyValues {
    param([string]$Path)
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Get-AdbDevices {
    $result = Invoke-Native $Adb @("devices", "-l") -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device(?:\s+.*)?$') { $Matches[1] }
    })
}

function Get-FastbootDevices {
    $result = Invoke-Native $Fastboot @("devices") -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+fastboot\s*$') { $Matches[1] }
    })
}

function Wait-FastbootDevice {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $devices = @(Get-FastbootDevices)
        if ($devices.Count -eq 1) { return $devices[0] }
        if ($devices.Count -gt 1) { throw "检测到多个 fastboot 设备，拒绝继续" }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "设备未在 $TimeoutSeconds 秒内进入 fastboot"
}

function Wait-DebianAdb {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Invoke-Native $Adb @("connect", $AdbSerial) -AllowFailure | Out-Null
        if ((Get-AdbDevices) -contains $AdbSerial) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Debian TCP ADB 未在 $TimeoutSeconds 秒内恢复：$AdbSerial"
}

function Get-FastbootVariable {
    param([string]$Serial, [string]$Name, [switch]$AllowEmpty)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "getvar", $Name) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "无法读取 fastboot getvar ${Name}：`r`n$($result.Text)"
    }
    $escapedName = [regex]::Escape($Name)
    foreach ($line in $result.Text -split "`r?`n") {
        if ($line -match "^(?:\(bootloader\)[ `t]*)?${escapedName}:[ `t]*(.*?)[ `t]*$") {
            $value = $Matches[1].Trim()
            if (-not $AllowEmpty -and -not $value) {
                throw "fastboot getvar ${Name} 返回空值"
            }
            return $value
        }
    }
    throw "无法解析 fastboot getvar ${Name}：`r`n$($result.Text)"
}

function Get-RescueAcmPort {
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_18D1&PID_D001&MI_02\\' -and $_.Class -eq "Ports"
    })
    if ($devices.Count -gt 1) { throw "检测到多个 UFI210 ACM 端口，拒绝继续" }
    if ($devices.Count -eq 0) { return $null }
    if ($devices[0].FriendlyName -notmatch '\((COM[0-9]+)\)') {
        throw "无法从 PnP 名称解析 ACM 端口：$($devices[0].FriendlyName)"
    }
    return $Matches[1]
}

function Wait-RescueAcmPort {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $port = Get-RescueAcmPort
        if ($port) {
            try {
                $probe = [IO.Ports.SerialPort]::new($port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                $probe.Open()
                $probe.Close()
                $probe.Dispose()
                return $port
            } catch {
                if ($probe) { $probe.Dispose() }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "initramfs USB ACM 未在 $TimeoutSeconds 秒内出现"
}

function Write-SerialChunked {
    param([IO.Ports.SerialPort]$Serial, [string]$Text)
    for ($offset = 0; $offset -lt $Text.Length; $offset += 4) {
        $count = [Math]::Min(4, $Text.Length - $offset)
        $Serial.Write($Text.Substring($offset, $count))
        Start-Sleep -Milliseconds 5
    }
}

function Invoke-RescueSerialCommand {
    param([string]$PortName, [string]$Command, [int]$TimeoutSeconds)
    $marker = "CODEX_" + [Guid]::NewGuid().ToString("N")
    $endMarker = "${marker}_END"
    $wireCommand = "echo ${marker}_BEGIN; ${Command}; rc=`$?; echo ${marker}_RC=`$rc; echo $endMarker"
    $serial = [IO.Ports.SerialPort]::new(
        $PortName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One
    )
    $serial.ReadTimeout = 250
    $serial.WriteTimeout = 1000
    $serial.DtrEnable = $true
    $serial.RtsEnable = $true
    $output = [Text.StringBuilder]::new()
    try {
        $serial.Open()
        Start-Sleep -Milliseconds 500
        [void]$output.Append($serial.ReadExisting())
        Write-SerialChunked $serial "`r"
        Start-Sleep -Milliseconds 200
        [void]$output.Append($serial.ReadExisting())
        Write-SerialChunked $serial ($wireCommand + "`r")
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 100
            [void]$output.Append($serial.ReadExisting())
            if ($output.ToString() -match "(?m)^$([regex]::Escape($endMarker))`r?$") {
                return [pscustomobject]@{ Marker = $marker; Text = $output.ToString() }
            }
        } while ((Get-Date) -lt $deadline)
        throw "ACM 命令未在 $TimeoutSeconds 秒内返回结束标记：`r`n$($output.ToString())"
    } finally {
        if ($serial.IsOpen) { $serial.Close() }
        $serial.Dispose()
    }
}

function Send-RescueReboot {
    param([string]$PortName)
    $serial = [IO.Ports.SerialPort]::new(
        $PortName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One
    )
    $serial.ReadTimeout = 250
    $serial.WriteTimeout = 1000
    $serial.DtrEnable = $true
    $serial.RtsEnable = $true
    $output = [Text.StringBuilder]::new()
    try {
        $serial.Open()
        Start-Sleep -Milliseconds 300
        [void]$output.Append($serial.ReadExisting())
        Write-SerialChunked $serial "`r/system/bin/reboot bootloader`r"
        $deadline = (Get-Date).AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            try { [void]$output.Append($serial.ReadExisting()) } catch { break }
            if ((Get-FastbootDevices).Count -gt 0) { break }
        } while ((Get-Date) -lt $deadline)
    } finally {
        if ($serial.IsOpen) { $serial.Close() }
        $serial.Dispose()
    }
    return $output.ToString()
}

function Assert-FastbootTarget {
    param([string]$Serial)
    $product = Get-FastbootVariable $Serial "product"
    $systemSize = Get-FastbootVariable $Serial "partition-size:system"
    $cacheSize = Get-FastbootVariable $Serial "partition-size:cache"
    $userdataSize = Get-FastbootVariable $Serial "partition-size:userdata"
    foreach ($value in @($systemSize, $cacheSize, $userdataSize)) {
        if ($value -notmatch '^0x[0-9a-fA-F]+$') {
            throw "fastboot 分区容量格式无效：$value"
        }
    }
    $systemBytes = [Convert]::ToInt64($systemSize.Substring(2), 16)
    $cacheBytes = [Convert]::ToInt64($cacheSize.Substring(2), 16)
    $userdataBytes = [Convert]::ToInt64($userdataSize.Substring(2), 16)
    if ($product -notmatch '(?i)^MSM8909$' -or
        $systemBytes -ne 1288491008L -or $cacheBytes -ne 268435456L -or
        $userdataBytes -ne 1928314368L) {
        throw "fastboot 目标不匹配：product=$product system=$systemSize cache=$cacheSize userdata=$userdataSize"
    }
    return "serial=$Serial`r`nproduct=$product`r`nsystem_size=$systemSize`r`ncache_size=$cacheSize`r`nuserdata_size=$userdataSize`r`n"
}

function Start-ExactDebianBoot {
    param([string]$Serial, [string]$LogName)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "boot", $BootImage)
    Write-Utf8File (Join-Path $OutputDir $LogName) ($result.Text + "`r`n")
    Wait-DebianAdb $DebianTimeoutSeconds
    $probeCommand = @'
set -eu
test "$(hostname)" = ufi210
test "$(cat /sys/devices/soc0/soc_id)" = 245
test "$(uname -m)" = armv7l
test "$(uname -r)" = 7.0.0-msm8909
test "$(findmnt -nro SOURCE /)" = /dev/mapper/ufi210-root
grep -q 'root=/dev/mapper/ufi210-root' /proc/cmdline
test "$(systemctl is-system-running)" = running
test "$(systemctl --failed --no-legend --plain | wc -l)" = 0
systemctl is-active NetworkManager ssh adbd zu02-wcnss zu02-mpss ModemManager >/dev/null
echo UFI210_DEBIAN_OK
'@
    $probe = Invoke-Native $Adb @("-s", $AdbSerial, "shell", $probeCommand)
    if ($probe.Text -notmatch '(?m)^UFI210_DEBIAN_OK\r?$') {
        throw "返回 Debian 后运行验收失败：`r`n$($probe.Text)"
    }
    Write-Utf8File (Join-Path $OutputDir "debian-after.txt") ($probe.Text + "`r`n")
}

foreach ($required in @($BootImage, $ManifestPath, $AnalyzeBoot, $RepackBoot)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少输入文件：$required" }
}
$Adb = Resolve-Tool $Adb "adb.exe"
$Fastboot = Resolve-Tool $Fastboot "fastboot.exe"
$Python = Resolve-Python
$Manifest = Read-KeyValues $ManifestPath
$requiredManifest = [ordered]@{
    architecture = "armhf"
    hostname = "ufi210"
    target_partition = "large-rootfs"
    rootfs_device = "/dev/mapper/ufi210-root"
    usb_functions = "rndis-acm"
    usb_product_id = "0xD001"
    fastboot_reboot_command = "adb-shell-system-bin-reboot-bootloader"
}
foreach ($key in $requiredManifest.Keys) {
    if (-not $Manifest.ContainsKey($key) -or $Manifest[$key] -ne $requiredManifest[$key]) {
        throw "构建清单字段不匹配：$key"
    }
}
$bootHash = (Get-FileHash -LiteralPath $BootImage -Algorithm SHA256).Hash.ToLowerInvariant()
if ($bootHash -ne $Manifest.boot_image_sha256) { throw "boot 镜像与构建清单哈希不匹配" }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$analysisDir = Join-Path $OutputDir "source-boot"
$rescueAnalysisDir = Join-Path $OutputDir "rescue-boot"
$analysis = Invoke-Python @($AnalyzeBoot, "--boot", $BootImage, "--out", $analysisDir, "--no-decompile")
Write-Utf8File (Join-Path $OutputDir "analyze-source.txt") ($analysis.Text + "`r`n")
$sourceSummary = Get-Content -LiteralPath (Join-Path $analysisDir "summary.json") -Raw -Encoding UTF8 |
    ConvertFrom-Json
$normalCmdline = (Get-Content -LiteralPath (Join-Path $analysisDir "cmdline.txt") -Raw -Encoding UTF8).Trim()
if ($normalCmdline -notmatch '(?:^| )root=/dev/mapper/ufi210-root(?: |$)') {
    throw "正式 boot cmdline 未选择 ufi210-root"
}
$rescueCmdline = $normalCmdline -replace '(?:^| )root=/dev/mapper/ufi210-root(?= |$)', " root=PARTLABEL=$MissingPartLabel"
$rescueCmdline = $rescueCmdline.Trim()
$repack = Invoke-Python @(
    $RepackBoot,
    "--original", $BootImage,
    "--kernel", (Join-Path $analysisDir "kernel"),
    "--ramdisk", (Join-Path $analysisDir "ramdisk.img"),
    "--qcdt", (Join-Path $analysisDir "qcdt.img"),
    "--output", $RescueImage,
    "--cmdline", $rescueCmdline,
    "--name", ([string]$sourceSummary.header.name)
)
Write-Utf8File (Join-Path $OutputDir "repack-rescue.txt") ($repack.Text + "`r`n")
Invoke-Python @($AnalyzeBoot, "--boot", $RescueImage, "--out", $rescueAnalysisDir, "--no-decompile") | Out-Null
$rescueSummary = Get-Content -LiteralPath (Join-Path $rescueAnalysisDir "summary.json") -Raw -Encoding UTF8 |
    ConvertFrom-Json
$parsedRescueCmdline = (Get-Content -LiteralPath (Join-Path $rescueAnalysisDir "cmdline.txt") -Raw -Encoding UTF8).Trim()
if ($parsedRescueCmdline -ne $rescueCmdline) { throw "救援 boot cmdline 回读不一致" }
foreach ($field in @("kernel_addr", "ramdisk_addr", "second_addr", "tags_addr", "page_size", "name")) {
    if ($sourceSummary.header.$field -ne $rescueSummary.header.$field) {
        throw "救援 boot 意外修改 header 字段：$field"
    }
}
foreach ($component in @("kernel", "ramdisk.img", "qcdt.img")) {
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $analysisDir $component) -Algorithm SHA256).Hash
    $rescueHash = (Get-FileHash -LiteralPath (Join-Path $rescueAnalysisDir $component) -Algorithm SHA256).Hash
    if ($sourceHash -ne $rescueHash) { throw "救援 boot 意外修改组件：$component" }
}
$rescueHash = (Get-FileHash -LiteralPath $RescueImage -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Utf8File (Join-Path $OutputDir "preflight.txt") ((@(
    "started=$(Get-Date -Format o)",
    "fastboot_partition_writes=none",
    "flash_or_erase=none",
    "source_boot=$BootImage",
    "source_boot_sha256=$bootHash",
    "rescue_boot_sha256=$rescueHash",
    "rescue_root_partlabel=$MissingPartLabel"
) -join "`r`n") + "`r`n")
if ($PrepareOnly) {
    $summary = @(
        "Debian initramfs 救援测试镜像离线验收通过",
        "device_access=none",
        "fastboot_partition_writes=none",
        "flash_or_erase=none",
        "source_boot_sha256=$bootHash",
        "rescue_boot_sha256=$rescueHash",
        "logs=$OutputDir"
    ) -join "`r`n"
    Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
    Write-Host $summary
    return
}

try {
    Wait-DebianAdb 30
    $before = Invoke-Native $Adb @(
        "-s", $AdbSerial, "shell",
        'test "$(hostname)" = ufi210 && test "$(cat /sys/devices/soc0/soc_id)" = 245 && test "$(findmnt -nro SOURCE /)" = /dev/mapper/ufi210-root && test -x /system/bin/reboot && echo UFI210_DEBIAN_BEFORE_OK'
    )
    Write-Utf8File (Join-Path $OutputDir "debian-before.txt") ($before.Text + "`r`n")

    $reboot = Invoke-Native $Adb @("-s", $AdbSerial, "shell", "/system/bin/reboot", "bootloader") -AllowFailure
    Write-Utf8File (Join-Path $OutputDir "enter-fastboot.txt") ((@(
        "exit_code=$($reboot.ExitCode)", $reboot.Text
    ) -join "`r`n") + "`r`n")
    $fastbootSerial = Wait-FastbootDevice $FastbootTimeoutSeconds
    Write-Utf8File (Join-Path $OutputDir "fastboot-target.txt") (Assert-FastbootTarget $fastbootSerial)

    $EnteredTemporaryBoot = $true
    $rescueBoot = Invoke-Native $Fastboot @("-s", $fastbootSerial, "boot", $RescueImage)
    Write-Utf8File (Join-Path $OutputDir "fastboot-boot-rescue.txt") ($rescueBoot.Text + "`r`n")
    $port = Wait-RescueAcmPort $RescueTimeoutSeconds
    $rescueCommand = (@'
fail=0; grep -Fq 'root=PARTLABEL=__MISSING_PARTLABEL__' /proc/cmdline || fail=1; test "$(readlink /proc/1/exe)" = /bin/busybox || fail=1; test -c /dev/ttyGS0 || fail=1; test -x /system/bin/reboot || fail=1; helper_rc=0; /system/bin/reboot unsupported >/run/reboot-helper-test.txt 2>&1 || helper_rc=$?; test "$helper_rc" -eq 2 || fail=1; /bin/busybox ps | grep '[t]elnetd' >/dev/null && fail=1; /bin/busybox netstat -lnt 2>/dev/null | grep -Eq '(^|[.:])23[[:space:]]' && fail=1; if test "$fail" -eq 0; then echo UFI210_INITRAMFS_RESCUE_OK; true; else echo UFI210_INITRAMFS_RESCUE_FAILED; false; fi
'@).Replace('__MISSING_PARTLABEL__', $MissingPartLabel)
    $serialCheck = Invoke-RescueSerialCommand $port $rescueCommand 30
    Write-Utf8File (Join-Path $OutputDir "acm-rescue-check.txt") $serialCheck.Text
    if ($serialCheck.Text -notmatch '(?m)^UFI210_INITRAMFS_RESCUE_OK\r?$' -or
        $serialCheck.Text -notmatch "(?m)^$([regex]::Escape($serialCheck.Marker))_RC=0\r?$") {
        throw "initramfs ACM 救援检查失败：`r`n$($serialCheck.Text)"
    }

    $rebootOutput = Send-RescueReboot $port
    Write-Utf8File (Join-Path $OutputDir "acm-reboot-bootloader.txt") $rebootOutput
    $fastbootSerial = Wait-FastbootDevice $FastbootTimeoutSeconds
    Write-Utf8File (Join-Path $OutputDir "fastboot-after-rescue.txt") (Assert-FastbootTarget $fastbootSerial)

    Start-ExactDebianBoot $fastbootSerial "fastboot-boot-final.txt"
    $ReturnedToDebian = $true
    $summary = @(
        "Debian initramfs USB ACM 救援验收通过",
        "fastboot_partition_writes=none",
        "flash_or_erase=none",
        "source_boot_sha256=$bootHash",
        "rescue_boot_sha256=$rescueHash",
        "rescue_trigger=missing-partlabel",
        "rescue_acm_port=$port",
        "unauthenticated_telnet=absent",
        "reboot_helper=static-arm-restart2",
        "return_path=acm-reboot-helper-fastboot-ram-boot",
        "completed=$(Get-Date -Format o)",
        "logs=$OutputDir"
    ) -join "`r`n"
    Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
    Write-Host $summary
} catch {
    Write-Utf8File (Join-Path $OutputDir "FAILURE.txt") ((@(
        "Debian initramfs USB ACM 救援验收失败",
        "fastboot_partition_writes=none",
        "flash_or_erase=none",
        "failed=$(Get-Date -Format o)",
        "error=$($_.Exception.Message)"
    ) -join "`r`n") + "`r`n")
    throw
} finally {
    if ($EnteredTemporaryBoot -and -not $ReturnedToDebian) {
        Write-Warning "验收中断，尝试在不写分区的前提下返回 Debian。"
        try {
            $devices = @(Get-FastbootDevices)
            if ($devices.Count -eq 0) {
                $recoveryPort = Get-RescueAcmPort
                if ($recoveryPort) {
                    Write-Utf8File (Join-Path $OutputDir "cleanup-acm.txt") (Send-RescueReboot $recoveryPort)
                    $devices = @(Wait-FastbootDevice 45)
                }
            }
            if ($devices.Count -eq 1) {
                Start-ExactDebianBoot $devices[0] "cleanup-fastboot-boot-final.txt"
                $ReturnedToDebian = $true
            }
        } catch {
            Write-Warning "自动返回 Debian 失败：$($_.Exception.Message)"
        }
    }
}
