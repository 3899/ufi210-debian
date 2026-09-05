[CmdletBinding()]
param(
    [string]$AdbPath = "",
    [string]$Serial = "",
    [string]$OutputRoot = "",
    [switch]$UseSu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

trap {
    Write-Host ("采集失败：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Resolve-AdbExecutable {
    param([string]$RequestedPath)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }

    $workspaceRootAdb = Join-Path $ProjectRoot "adb.exe"
    $workspaceOutAdb = Join-Path $ProjectRoot "out\adb.exe"
    $candidates.Add($workspaceRootAdb)
    $candidates.Add($workspaceOutAdb)

    $pathAdb = Get-Command adb -ErrorAction SilentlyContinue
    if ($pathAdb) {
        $candidates.Add($pathAdb.Source)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "未找到 adb.exe。请使用 -AdbPath 指定 Android platform-tools 中的 adb.exe。"
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandArgs,
        [switch]$AllowFailure
    )

    $allArgs = @($script:AdbSelector) + $CommandArgs
    $result = & $script:AdbExecutable @allArgs 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($result | ForEach-Object { $_.ToString() }) -join "`r`n"

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "adb 命令失败（退出码 $exitCode）：adb $($CommandArgs -join ' ')`r`n$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Get-ConnectedDevice {
    param([string]$RequestedSerial)

    $raw = & $script:AdbExecutable devices -l 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "无法执行 adb devices：$($raw -join ' ')"
    }

    $devices = @()
    $blocked = @()
    foreach ($lineObject in $raw) {
        $line = $lineObject.ToString().Trim()
        if ($line -match '^([^\s]+)\s+(device|unauthorized|offline)(?:\s+.*)?$') {
            $entry = [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
            if ($entry.State -eq "device") {
                $devices += $entry
            } else {
                $blocked += $entry
            }
        }
    }

    if ($RequestedSerial) {
        $selected = $devices | Where-Object { $_.Serial -eq $RequestedSerial }
        if (-not $selected) {
            throw "未找到已授权设备 $RequestedSerial。当前 adb 输出：`r`n$($raw -join "`r`n")"
        }
        return $selected | Select-Object -First 1
    }

    if ($devices.Count -eq 0) {
        if ($blocked.Count -gt 0) {
            throw "检测到设备但状态不是 device。请在 Android 上允许 USB 调试授权：`r`n$($raw -join "`r`n")"
        }
        throw "没有检测到 ADB 设备。请先启动目标 Android、开启 USB 调试并连接数据线。"
    }

    if ($devices.Count -gt 1) {
        throw "检测到多个 ADB 设备，请用 -Serial 指定：$($devices.Serial -join ', ')"
    }

    return $devices[0]
}

function Convert-DtProperty {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("[$Name]")
    $lines.Add("length=$($bytes.Length)")

    if ($bytes.Length -eq 0) {
        $lines.Add("value=<empty>")
        return ($lines -join "`r`n")
    }

    $printable = $true
    $hasLetter = $false
    foreach ($byte in $bytes) {
        if ($byte -ne 0 -and ($byte -lt 32 -or $byte -gt 126)) {
            $printable = $false
            break
        }
        if (($byte -ge 65 -and $byte -le 90) -or ($byte -ge 97 -and $byte -le 122)) {
            $hasLetter = $true
        }
    }

    if ($printable -and $hasLetter) {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes).Trim([char]0)
        $values = $text -split "`0" | Where-Object { $_ -ne "" }
        $lines.Add("strings=$($values -join ' | ')")
    } elseif (($bytes.Length % 4) -eq 0) {
        $cells = New-Object System.Collections.Generic.List[string]
        for ($offset = 0; $offset -lt $bytes.Length; $offset += 4) {
            [uint32]$value = (([uint32]$bytes[$offset] -shl 24) -bor
                ([uint32]$bytes[$offset + 1] -shl 16) -bor
                ([uint32]$bytes[$offset + 2] -shl 8) -bor
                [uint32]$bytes[$offset + 3])
            $cells.Add(("0x{0:X8} ({1})" -f $value, $value))
        }
        $lines.Add("be32=$($cells -join ', ')")
    } else {
        $hex = [System.BitConverter]::ToString($bytes).Replace("-", "")
        $lines.Add("hex=$hex")
    }

    return ($lines -join "`r`n")
}

$script:AdbExecutable = Resolve-AdbExecutable -RequestedPath $AdbPath
$selectedDevice = Get-ConnectedDevice -RequestedSerial $Serial
$script:AdbSelector = @("-s", $selectedDevice.Serial)

$state = Invoke-Adb -CommandArgs @("get-state")
if ($state.Text.Trim() -ne "device") {
    throw "ADB 设备状态异常：$($state.Text)"
}

$safeSerial = $selectedDevice.Serial -replace '[^A-Za-z0-9._-]', '_'
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\hardware-probe"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$OutputDir = Join-Path $OutputRoot "$timestamp-$safeSerial"
$DtDir = Join-Path $OutputDir "device-tree"
New-Item -ItemType Directory -Path $DtDir -Force | Out-Null

$adbVersion = & $script:AdbExecutable version 2>&1
$identity = Invoke-Adb -CommandArgs @("shell", "id") -AllowFailure
$runWithSu = $false
if ($UseSu -and $identity.Text -notmatch 'uid=0') {
    $suIdentity = Invoke-Adb -CommandArgs @("shell", "su", "-c", "id") -AllowFailure
    if ($suIdentity.ExitCode -ne 0 -or $suIdentity.Text -notmatch 'uid=0') {
        throw "-UseSu 已启用，但设备没有可用 su 或授权未通过：$($suIdentity.Text)"
    }
    $runWithSu = $true
}

$metadata = @(
    "采集时间=$(Get-Date -Format o)"
    "设备序列号=$($selectedDevice.Serial)"
    "ADB=$script:AdbExecutable"
    "ADB版本=$(($adbVersion | ForEach-Object { $_.ToString() }) -join ' | ')"
    "初始身份=$($identity.Text)"
    "使用su=$runWithSu"
    "脚本版本=3"
) -join "`r`n"
Write-Utf8File -Path (Join-Path $OutputDir "metadata.txt") -Content ($metadata + "`r`n")

$deviceScriptPath = Join-Path $PSScriptRoot "probe_stock_android.sh"
if (-not (Test-Path -LiteralPath $deviceScriptPath -PathType Leaf)) {
    throw "缺少设备侧脚本：$deviceScriptPath"
}
$deviceScript = [System.IO.File]::ReadAllText($deviceScriptPath).Replace("`r`n", "`n")
$normalizedDeviceScriptPath = Join-Path $OutputDir "probe-device.sh"
$remoteDeviceScriptPath = "/data/local/tmp/msm8909-hardware-probe-$safeSerial.sh"
Write-Utf8File -Path $normalizedDeviceScriptPath -Content $deviceScript

Write-Host "正在采集目标 Android 运行时信息（不验证系统来源），输出目录：$OutputDir"
$pushProbe = Invoke-Adb -CommandArgs @("push", $normalizedDeviceScriptPath, $remoteDeviceScriptPath) -AllowFailure
if ($pushProbe.ExitCode -ne 0) {
    throw "无法上传临时设备侧采集脚本：$($pushProbe.Text)"
}

try {
    if ($runWithSu) {
        $probe = Invoke-Adb -CommandArgs @("shell", "su -c 'sh $remoteDeviceScriptPath'") -AllowFailure
    } else {
        $probe = Invoke-Adb -CommandArgs @("shell", "sh", $remoteDeviceScriptPath) -AllowFailure
    }
} finally {
    $removeProbe = Invoke-Adb -CommandArgs @("shell", "rm", "-f", $remoteDeviceScriptPath) -AllowFailure
    if ($removeProbe.ExitCode -ne 0) {
        Write-Warning "未能删除设备侧临时脚本 $remoteDeviceScriptPath：$($removeProbe.Text)"
    }
}

$probeExitCode = $probe.ExitCode
$probeText = $probe.Text
Write-Utf8File -Path (Join-Path $OutputDir "android-probe.txt") -Content ($probeText + "`r`n")
if ($probeExitCode -ne 0) {
    throw "Android 侧采集脚本失败（退出码 $probeExitCode），已保留输出：$OutputDir"
}

$dtBaseResult = Invoke-Adb -CommandArgs @(
    "shell",
    "if [ -d /proc/device-tree ]; then echo /proc/device-tree; elif [ -d /sys/firmware/devicetree/base ]; then echo /sys/firmware/devicetree/base; fi"
) -AllowFailure
$dtBase = $dtBaseResult.Text.Trim()
$pullLog = New-Object System.Collections.Generic.List[string]
$decoded = New-Object System.Collections.Generic.List[string]

if ($dtBase) {
    $properties = @(
        "model",
        "compatible",
        "qcom,msm-id",
        "qcom,board-id",
        "qcom,pmic-id",
        "qcom,hardware-id",
        "serial-number",
        "memory/reg",
        "chosen/bootargs"
    )

    foreach ($property in $properties) {
        $remotePath = "$dtBase/$property"
        $readable = Invoke-Adb -CommandArgs @("shell", "if [ -r '$remotePath' ]; then echo yes; fi") -AllowFailure
        if ($readable.Text.Trim() -ne "yes") {
            $pullLog.Add("SKIP $remotePath")
            continue
        }

        $localName = ($property -replace '/', '__') + ".bin"
        $localPath = Join-Path $DtDir $localName
        $pull = Invoke-Adb -CommandArgs @("pull", $remotePath, $localPath) -AllowFailure
        $pullLog.Add("PULL $remotePath exit=$($pull.ExitCode) $($pull.Text)")
        if ($pull.ExitCode -eq 0 -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            $decoded.Add((Convert-DtProperty -Name $property -Path $localPath))
        }
    }
} else {
    $pullLog.Add("未找到 /proc/device-tree 或 /sys/firmware/devicetree/base")
}

$configPull = Invoke-Adb -CommandArgs @("pull", "/proc/config.gz", (Join-Path $OutputDir "proc-config.gz")) -AllowFailure
$pullLog.Add("PULL /proc/config.gz exit=$($configPull.ExitCode) $($configPull.Text)")

Write-Utf8File -Path (Join-Path $OutputDir "pull.log") -Content (($pullLog -join "`r`n") + "`r`n")
Write-Utf8File -Path (Join-Path $OutputDir "device-tree-properties.txt") -Content (($decoded -join "`r`n`r`n") + "`r`n")

$summary = @(
    "采集完成"
    "输出目录：$OutputDir"
    "设备：$($selectedDevice.Serial)"
    "身份：$($identity.Text)"
    "使用su：$runWithSu"
    "设备树入口：$dtBase"
    "下一步：检查 device-tree-properties.txt 和 android-probe.txt，再匹配 out/boot-analysis/qcdt-entries.csv。"
) -join "`r`n"
Write-Utf8File -Path (Join-Path $OutputDir "SUMMARY.txt") -Content ($summary + "`r`n")

Write-Host $summary
