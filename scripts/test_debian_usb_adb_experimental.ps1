param(
    [ValidateSet('rndis-adb', 'acm-adb', 'rndis-acm-adb')]
    [string]$Mode = 'rndis-adb',
    [ValidateRange(120, 600)]
    [int]$DurationSeconds = 150,
    [ValidateRange(60, 180)]
    [int]$PostRestartObservationSeconds = 75,
    [ValidateRange(30, 180)]
    [int]$TcpTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Adb = Join-Path $ProjectRoot 'adb.exe'
$TcpSerial = '192.168.68.1:5555'
$UsbVidPid = 'USB\VID_18D1&PID_D002'
$RemoteScript = '/usr/sbin/zu02-usb-adb-experiment'

function Invoke-Adb {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Adb @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "adb 失败 ($LASTEXITCODE): $($output -join "`n")"
    }
    return ($output -join "`n")
}

function Get-AdbDevices {
    return Invoke-Adb @('devices', '-l')
}

function Test-TcpAdb {
    $devices = Invoke-Adb @('devices', '-l') -AllowFailure
    if ($devices -match "(?m)^$([regex]::Escape($TcpSerial))\s+device\b") {
        return $true
    }
    Invoke-Adb @('disconnect', $TcpSerial) -AllowFailure | Out-Null
    Invoke-Adb @('connect', $TcpSerial) -AllowFailure | Out-Null
    $devices = Invoke-Adb @('devices', '-l') -AllowFailure
    return $devices -match "(?m)^$([regex]::Escape($TcpSerial))\s+device\b"
}

function Wait-UsbAdb {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $devices = Invoke-Adb @('devices', '-l') -AllowFailure
        if ($devices -match '(?m)^ZU02-DW01\s+device\b') { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-TcpAdb {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-TcpAdb) { return $true }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $false
}

if (-not (Test-Path -LiteralPath $Adb)) { throw "缺少 adb.exe：$Adb" }
Invoke-Adb @('connect', $TcpSerial) | Out-Null
$devices = Invoke-Adb @('devices')
if ($devices -notmatch "(?m)^$([regex]::Escape($TcpSerial))\s+device\s*$") {
    throw "目标 UFI210 的 TCP ADB 不可用；未向其他序列号发送命令。`n$devices"
}
$identity = Invoke-Adb @('-s', $TcpSerial, 'shell', 'hostname; uname -r')
if ($identity -notmatch '(?m)^ufi210\r?$' -or $identity -notmatch '(?m)^7\.0\.0-msm8909\r?$') {
    throw "目标身份校验失败，拒绝继续：`n$identity"
}

$unit = "zu02-usb-adb-experiment-$([guid]::NewGuid().ToString('N'))"
$remote = "systemd-run --unit=$unit --collect --no-block $RemoteScript $Mode $DurationSeconds"
$experimentStarted = Get-Date
Write-Host "启动有限时长 USB ADB 实验：$Mode，${DurationSeconds}s"
Invoke-Adb @('-s', $TcpSerial, 'shell', $remote) | Out-Null

$deadline = (Get-Date).AddSeconds($TcpTimeoutSeconds)
$adbUsb = $false
do {
    $present = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "$UsbVidPid*" }
    if ($present) {
        $adbUsb = [bool]($present | Where-Object { $_.FriendlyName -match 'ADB|Android' })
        if ($adbUsb) { break }
    }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

$present | Format-Table -Auto Status,Class,FriendlyName,InstanceId
$experimentError = $null
try {
    if (-not $adbUsb) {
        throw 'Windows 未枚举 Android ADB 接口。'
    }
    if (-not (Wait-UsbAdb 15)) {
        throw "PnP 出现 ADB 接口，但 adb 未建立 ZU02-DW01 USB transport：`n$(Get-AdbDevices)"
    }
    if ($Mode -like 'rndis-*' -and -not (Wait-TcpAdb 15)) {
        throw 'USB ADB 出现后 TCP ADB 未保持可用。'
    }
    Write-Host 'USB ADB 与 TCP 回退入口均已建立，触发一次 experimental adbd 热重启。'
    $restart = 'systemd-run --quiet --collect --on-active=1s /usr/bin/systemctl restart zu02-usb-adbd-experiment.service'
    Invoke-Adb @('-s', 'ZU02-DW01', 'shell', $restart) | Out-Null
    if (-not (Wait-UsbAdb 15)) {
        throw '热重启后 USB ADB 未在 15 秒内恢复。'
    }
    if ($Mode -like 'rndis-*' -and -not (Wait-TcpAdb 15)) {
        throw '热重启后 TCP ADB 未在 15 秒内恢复。'
    }
    $deadline = (Get-Date).AddSeconds($PostRestartObservationSeconds)
    do {
        if (-not (Wait-UsbAdb 2)) { throw '热重启观察期间 USB ADB 消失。' }
        if ($Mode -like 'rndis-*' -and -not (Test-TcpAdb)) {
            throw '热重启观察期间 TCP ADB 消失。'
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Write-Host "adbd 热重启后的 ${PostRestartObservationSeconds}s 观察通过。"
} catch {
    $experimentError = $_.Exception.Message
    Write-Warning "$experimentError 等待设备端自动恢复正式配置。"
}

$elapsed = [int][Math]::Ceiling(((Get-Date) - $experimentStarted).TotalSeconds)
$restoreTimeout = [Math]::Max(60, $DurationSeconds - $elapsed + 60)
if (-not (Wait-TcpAdb $restoreTimeout)) {
    throw "实验结束后固定 TCP ADB 未在 ${restoreTimeout}s 内恢复。实验错误：$experimentError"
}
$final = Invoke-Adb @('-s', $TcpSerial, 'shell', 'find /sys/kernel/config/usb_gadget/g1/configs/c.1 -maxdepth 1 -type l -printf "%f\n" | sort; mountpoint -q /dev/usb-ffs/adb; echo ffs_mount=$?; systemctl is-active adbd zu02-usb-watchdog.timer')
if ($final -notmatch '(?ms)^acm\.usb0\r?\nrndis\.usb0\r?\nffs_mount=1\r?\nactive\r?\nactive\s*$') {
    throw "实验结束后的默认 gadget 未完整恢复：`n$final"
}
Write-Host '实验完成，默认 RNDIS + ACM + TCP ADB 已恢复。'
if ($experimentError) { throw $experimentError }
