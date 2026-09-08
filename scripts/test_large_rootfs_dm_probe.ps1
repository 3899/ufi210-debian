[CmdletBinding()]
param(
    [ValidateRange(30, 300)] [int]$FastbootTimeoutSeconds = 90,
    [ValidateRange(30, 300)] [int]$AcmTimeoutSeconds = 120,
    [ValidateRange(10, 120)] [int]$CommandTimeoutSeconds = 45,
    [string]$ProbeBoot = "",
    [string]$OutputRoot = "",
    [switch]$ReturnToCurrentOs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"
if (-not $ProbeBoot) {
    $ProbeBoot = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs\boot-debian-large-rootfs-dm-probe.img"
}
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test"
}
$ProbeBoot = [IO.Path]::GetFullPath($ProbeBoot)
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("dm-probe-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$EnteredProbe = $false
$ReturnedToFastboot = $false

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

function Get-FastbootDevices {
    $result = Invoke-Native $Fastboot @("devices") -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    @($result.Text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+fastboot\s*$') { $Matches[1] }
    })
}

function Wait-FastbootDevice {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $devices = @(Get-FastbootDevices)
        if ($devices.Count -eq 1) { return $devices[0] }
        if ($devices.Count -gt 1) { throw "检测到多个 fastboot 设备" }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "fastboot 未在 $TimeoutSeconds 秒内出现"
}

function Get-FastbootVariable {
    param([string]$Serial, [string]$Name)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "getvar", $Name) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "无法读取 fastboot getvar ${Name}" }
    $escaped = [regex]::Escape($Name)
    foreach ($line in $result.Text -split "`r?`n") {
        if ($line -match "^(?:\(bootloader\)[ `t]*)?${escaped}:[ `t]*(.*?)[ `t]*$") {
            return $Matches[1].Trim()
        }
    }
    throw "无法解析 fastboot getvar ${Name}"
}

function Convert-HexBytes {
    param([string]$Value)
    if ($Value -notmatch '^0x([0-9a-fA-F]+)$') { throw "fastboot 容量格式无效：$Value" }
    [Convert]::ToInt64($Matches[1], 16)
}

function Get-AcmPort {
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_18D1&PID_D001&MI_02\\' -and $_.Class -eq "Ports"
    })
    if ($devices.Count -gt 1) { throw "检测到多个 UFI210 ACM 端口" }
    if ($devices.Count -eq 0) { return $null }
    if ($devices[0].FriendlyName -notmatch '\((COM[0-9]+)\)') { throw "无法解析 ACM 端口" }
    $Matches[1]
}

function Wait-AcmPort {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $port = Get-AcmPort
        if ($port) {
            $serial = $null
            try {
                $serial = [IO.Ports.SerialPort]::new($port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                $serial.Open()
                $serial.Close()
                $serial.Dispose()
                return $port
            } catch {
                if ($serial) { $serial.Dispose() }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "只读 dm 探测的 USB ACM 未在 $TimeoutSeconds 秒内出现"
}

function Write-SerialChunked {
    param([IO.Ports.SerialPort]$Serial, [string]$Text)
    for ($offset = 0; $offset -lt $Text.Length; $offset += 4) {
        $count = [Math]::Min(4, $Text.Length - $offset)
        $Serial.Write($Text.Substring($offset, $count))
        Start-Sleep -Milliseconds 5
    }
}

function Invoke-AcmCommand {
    param([string]$PortName, [string]$Command, [int]$TimeoutSeconds)
    $marker = "UFI210_" + [Guid]::NewGuid().ToString("N")
    $endMarker = "${marker}_END"
    $wire = 'echo {0}_BEGIN; {1}; rc=$?; echo {0}_RC=$rc; echo {2}' -f `
        $marker, $Command, $endMarker
    $serial = [IO.Ports.SerialPort]::new($PortName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
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
        Write-SerialChunked $serial ($wire + "`r")
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 100
            [void]$output.Append($serial.ReadExisting())
            if ($output.ToString() -match "(?m)^$([regex]::Escape($endMarker))`r?$") {
                return [pscustomobject]@{ Marker = $marker; Text = $output.ToString() }
            }
        } while ((Get-Date) -lt $deadline)
        throw "ACM 探测未返回结束标记：`r`n$($output.ToString())"
    } finally {
        if ($serial.IsOpen) { $serial.Close() }
        $serial.Dispose()
    }
}

function Send-AcmBootloaderReboot {
    param([string]$PortName)
    $serial = [IO.Ports.SerialPort]::new($PortName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
    $serial.DtrEnable = $true
    $serial.RtsEnable = $true
    try {
        $serial.Open()
        Start-Sleep -Milliseconds 300
        Write-SerialChunked $serial "`r/system/bin/reboot bootloader`r"
    } finally {
        if ($serial.IsOpen) { $serial.Close() }
        $serial.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ProbeBoot -PathType Leaf)) { throw "缺少只读 dm 探测 boot：$ProbeBoot" }
if (-not (Test-Path -LiteralPath $Fastboot -PathType Leaf)) {
    $command = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if (-not $command) { throw "缺少 fastboot.exe" }
    $Fastboot = $command.Source
}
$devices = @(Get-FastbootDevices)
if ($devices.Count -ne 1) { throw "必须且只能连接一台已进入 fastboot 的设备" }
$fastbootSerial = $devices[0]
$product = Get-FastbootVariable $fastbootSerial "product"
$systemBytes = Convert-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:system")
$cacheBytes = Convert-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:cache")
$userdataBytes = Convert-HexBytes (Get-FastbootVariable $fastbootSerial "partition-size:userdata")
if ($product -notmatch '(?i)^MSM8909$' -or $systemBytes -ne 1288491008L -or
    $cacheBytes -ne 268435456L -or $userdataBytes -ne 1928314368L) {
    throw "fastboot 目标或分区边界不匹配"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$probeHash = (Get-FileHash -LiteralPath $ProbeBoot -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Utf8File (Join-Path $OutputDir "preflight.txt") ((@(
    "product=$product", "fastboot_serial=$fastbootSerial", "system_bytes=$systemBytes",
    "cache_bytes=$cacheBytes", "userdata_bytes=$userdataBytes", "probe_boot_sha256=$probeHash",
    "device_writes=none", "fastboot_partition_operations=none"
) -join "`r`n") + "`r`n")

try {
    $boot = Invoke-Native $Fastboot @("-s", $fastbootSerial, "boot", $ProbeBoot)
    $EnteredProbe = $true
    Write-Utf8File (Join-Path $OutputDir "fastboot-boot.txt") ($boot.Text + "`r`n")
    $port = Wait-AcmPort $AcmTimeoutSeconds
    $command = @'
fail=0
grep -Fq 'ufi210.dm_probe=1' /proc/cmdline || fail=1
grep -Fq 'root=/dev/mapper/ufi210-root' /proc/cmdline || fail=1
test "$(readlink /proc/1/exe)" = /bin/busybox || fail=1
test "$(blockdev --getro /dev/mapper/ufi210-root)" = 1 || fail=1
test "$(blockdev --getsz /dev/mapper/ufi210-root)" = 6807111 || fail=1
test "$(cat /sys/class/block/mmcblk0p21/start)" = 461920 || fail=1
test "$(cat /sys/class/block/mmcblk0p21/size)" = 2516584 || fail=1
test "$(cat /sys/class/block/mmcblk0p23/start)" = 3044040 || fail=1
test "$(cat /sys/class/block/mmcblk0p23/size)" = 524288 || fail=1
test "$(cat /sys/class/block/mmcblk0p29/start)" = 3803136 || fail=1
test "$(cat /sys/class/block/mmcblk0p29/size)" = 3766239 || fail=1
system_dev=$(cat /sys/class/block/mmcblk0p21/dev)
cache_dev=$(cat /sys/class/block/mmcblk0p23/dev)
userdata_dev=$(cat /sys/class/block/mmcblk0p29/dev)
dmsetup table ufi210-root > /run/ufi210-dm-table
sed -n '1p' /run/ufi210-dm-table | grep -Fx "0 2516584 linear $system_dev 0" || fail=1
sed -n '2p' /run/ufi210-dm-table | grep -Fx "2516584 524288 linear $cache_dev 0" || fail=1
sed -n '3p' /run/ufi210-dm-table | grep -Fx "3040872 3766239 linear $userdata_dev 0" || fail=1
test "$(wc -l < /run/ufi210-dm-table)" = 3 || fail=1
mountpoint -q /sysroot && fail=1
cat /run/ufi210-dm-table
printf 'DM_READONLY='; blockdev --getro /dev/mapper/ufi210-root
printf 'DM_SECTORS='; blockdev --getsz /dev/mapper/ufi210-root
if test "$fail" -eq 0; then echo UFI210_DM_PROBE_OK; true; else echo UFI210_DM_PROBE_FAILED; false; fi
'@
    $probe = Invoke-AcmCommand $port $command $CommandTimeoutSeconds
    Write-Utf8File (Join-Path $OutputDir "acm-probe.txt") $probe.Text
    if ($probe.Text -notmatch '(?m)^UFI210_DM_PROBE_OK\r?$' -or
        $probe.Text -notmatch '(?m)^DM_READONLY=1\r?$' -or
        $probe.Text -notmatch '(?m)^DM_SECTORS=6807111\r?$' -or
        $probe.Text -notmatch "(?m)^$([regex]::Escape($probe.Marker))_RC=0\r?$") {
        throw "只读 dm 探测不匹配：`r`n$($probe.Text)"
    }
    Send-AcmBootloaderReboot $port
    $fastbootSerial = Wait-FastbootDevice $FastbootTimeoutSeconds
    $ReturnedToFastboot = $true
    if ((Get-FastbootVariable $fastbootSerial "product") -notmatch '(?i)^MSM8909$') {
        throw "探测后返回的 fastboot 目标不匹配"
    }
    if ($ReturnToCurrentOs) {
        Invoke-Native $Fastboot @("-s", $fastbootSerial, "reboot") | Out-Null
        $ReturnedToFastboot = $false
    }
    $summary = @(
        "UFI210 large-rootfs 只读 dm-linear RAM 探测通过",
        "fastboot_partition_operations=none", "device_writes=none",
        "dm_name=ufi210-root", "dm_readonly=true", "dm_sectors=6807111",
        "dm_segments=system,cache,userdata", "rootfs_mount=none",
        "probe_boot_sha256=$probeHash", "returned_to_fastboot=$((-not $ReturnToCurrentOs).ToString().ToLowerInvariant())",
        "completed=$(Get-Date -Format o)", "logs=$OutputDir"
    ) -join "`r`n"
    Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
    Write-Host $summary
} finally {
    if ($EnteredProbe -and -not $ReturnedToFastboot -and -not $ReturnToCurrentOs) {
        $recoveryPort = Get-AcmPort
        if ($recoveryPort) {
            try { Send-AcmBootloaderReboot $recoveryPort } catch { }
        }
    }
}
