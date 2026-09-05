[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^COM[0-9]+$')]
    [string]$ComPort,
    [Parameter(Mandatory = $true)]
    [string]$Programmer,
    [switch]$ConfirmNoWriteProbe,
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedProgrammerSha256 = "",
    [string]$OutputRoot = "",
    [ValidateRange(30, 300)]
    [int]$DebianTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$QpstBin = "C:\Program Files (x86)\Qualcomm\QPST\bin"
$QSahara = Join-Path $QpstBin "QSaharaServer.exe"
$FhLoader = Join-Path $QpstBin "fh_loader.exe"
$Adb = Join-Path $ProjectRoot "adb.exe"
$ExpectedDiskSectors = 7569408L
$ExpectedSectorBytes = 512L
$ExpectedPhysicalPartitions = 3
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Invoke-Native {
    param(
        [string]$Executable,
        [string[]]$CommandArgs,
        [string]$LogPath,
        [switch]$AllowFailure
    )
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Executable @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    Write-Utf8File $LogPath ($text + "`r`n")
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$([IO.Path]::GetFileName($Executable)) 失败（$exitCode），日志：$LogPath"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

if (-not $ConfirmNoWriteProbe) {
    throw "本脚本会向 9008 设备加载 programmer；确认只读探测后使用 -ConfirmNoWriteProbe"
}
foreach ($tool in @($QSahara, $FhLoader)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "缺少 QPST 工具：$tool" }
}
$Programmer = [IO.Path]::GetFullPath($Programmer)
if (-not (Test-Path -LiteralPath $Programmer -PathType Leaf)) {
    throw "programmer 不存在：$Programmer"
}
$programmerInfo = Get-Item -LiteralPath $Programmer
if ($programmerInfo.Length -lt 65536 -or $programmerInfo.Length -gt 1048576) {
    throw "programmer 尺寸异常：$($programmerInfo.Length)"
}
$header = ([IO.File]::ReadAllBytes($Programmer))[0..3]
if ($header[0] -ne 0x7f -or $header[1] -ne 0x45 -or
    $header[2] -ne 0x4c -or $header[3] -ne 0x46) {
    throw "programmer 不是 ELF 镜像"
}
$programmerHash = (Get-FileHash -LiteralPath $Programmer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedProgrammerSha256 -and
    $programmerHash -ne $ExpectedProgrammerSha256.ToLowerInvariant()) {
    throw "programmer SHA256 不匹配"
}

$portNumber = [int]$ComPort.Substring(3)
$pnpDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object {
    $_.PNPDeviceID -match 'VID_05C6&PID_9008' -and $_.Name -match '\(COM([0-9]+)\)'
})
if ($pnpDevices.Count -ne 1) {
    throw "必须且只能连接一台 Qualcomm 9008 设备，当前数量：$($pnpDevices.Count)"
}
if ($pnpDevices[0].Name -notmatch "\(COM${portNumber}\)") {
    throw "9008 端口与参数不一致：$($pnpDevices[0].Name)"
}

if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\9008-programmer-probe" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$firehosePort = "\\.\$ComPort"

Write-Host "加载 programmer，只执行 Sahara 握手。"
$sahara = Invoke-Native $QSahara @(
    "-p", $firehosePort,
    "-s", "13:$Programmer",
    "-v", "1"
) (Join-Path $OutputDir "sahara.txt")
if ($sahara.Text -notmatch '(?i)Sahara protocol completed') {
    throw "Sahara 未明确报告完成，拒绝继续；设备仍应保持 9008"
}

Write-Host "读取 eMMC 几何信息，不发送任何写入 XML。"
Push-Location $OutputDir
try {
    $storage = Invoke-Native $FhLoader @(
        "--port=$firehosePort",
        "--getstorageinfo=0",
        "--noprompt",
        "--zlpawarehost=1",
        "--memoryname=emmc",
        "--porttracename=storage-port-trace.txt"
    ) (Join-Path $OutputDir "storage-console.txt")
} finally {
    Pop-Location
}
$storageTrace = Join-Path $OutputDir "storage-port-trace.txt"
if (-not (Test-Path -LiteralPath $storageTrace -PathType Leaf)) {
    throw "fh_loader 未生成 storage port trace"
}
$storageEvidence = $storage.Text + "`r`n" + [IO.File]::ReadAllText($storageTrace)
foreach ($expected in @(
    "num_partition_sectors=$ExpectedDiskSectors",
    "SECTOR_SIZE_IN_BYTES=$ExpectedSectorBytes",
    "num_physical_partitions=$ExpectedPhysicalPartitions",
    "All Finished Successfully"
)) {
    if ($storageEvidence -notmatch [regex]::Escape($expected)) {
        throw "eMMC 只读探测缺少证据：$expected"
    }
}
if ($storageEvidence -match '(?i)sendxml|<program\b|<erase\b|firmwarewrite') {
    throw "只读探测日志出现写入命令，停止并保留现场"
}

$targetName = "unknown"
if ($storageEvidence -match 'TargetName="([^"]+)"') { $targetName = $Matches[1] }
$manifest = @(
    "probe_result=passed",
    "probe_mode=sahara-and-getstorageinfo-only",
    "timestamp=$(Get-Date -Format o)",
    "com_port=$ComPort",
    "pnp_name=$($pnpDevices[0].Name)",
    "programmer_file=$([IO.Path]::GetFileName($Programmer))",
    "programmer_bytes=$($programmerInfo.Length)",
    "programmer_sha256=$programmerHash",
    "target_name=$targetName",
    "disk_sectors=$ExpectedDiskSectors",
    "sector_bytes=$ExpectedSectorBytes",
    "disk_bytes=$($ExpectedDiskSectors * $ExpectedSectorBytes)",
    "physical_partitions=$ExpectedPhysicalPartitions",
    "write_commands=none"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "PROBE-MANIFEST.txt") ($manifest + "`r`n")

Write-Host "只读探测通过，发送 firehose reset 返回已安装的 Debian。"
Push-Location $OutputDir
try {
    Invoke-Native $FhLoader @(
        "--port=$firehosePort",
        "--reset",
        "--noprompt",
        "--zlpawarehost=1",
        "--memoryname=emmc",
        "--porttracename=reset-port-trace.txt"
    ) (Join-Path $OutputDir "reset-console.txt") | Out-Null
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $Adb -PathType Leaf) {
    $deadline = (Get-Date).AddSeconds($DebianTimeoutSeconds)
    do {
        & $Adb connect 192.168.68.1:5555 2>&1 | Out-Null
        $probe = & $Adb -s 192.168.68.1:5555 shell `
            'test "$(hostname)" = ufi210 && test "$(findmnt -nro SOURCE /)" = /dev/mmcblk0p21 && echo DEBIAN_OK' `
            2>&1
        if ($LASTEXITCODE -eq 0 -and $probe -match 'DEBIAN_OK') {
            Write-Host "9008 programmer 只读探测及 Debian 返回验收通过。"
            Write-Host "programmer_sha256=$programmerHash"
            Write-Host "logs=$OutputDir"
            exit 0
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "firehose reset 后 Debian 未在 $DebianTimeoutSeconds 秒内恢复；请物理断电重启"
}

Write-Host "9008 programmer 只读探测通过；未找到 adb.exe，未自动验收 Debian 返回。"
Write-Host "programmer_sha256=$programmerHash"
Write-Host "logs=$OutputDir"
