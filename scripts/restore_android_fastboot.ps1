[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [switch]$ConfirmRestoreAndroid,
    [switch]$RebootAfterRestore,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Fastboot = Join-Path $ProjectRoot "fastboot.exe"
$ExpectedProduct = "MSM8909"
$ExpectedPartitionBytes = [ordered]@{
    boot = 33554432L
    system = 1288491008L
    cache = 268435456L
    userdata = 1928314368L
    recovery = 33554432L
}
$BackupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)

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

function Get-FastbootVariable {
    param([string]$Serial, [string]$Name)
    $result = Invoke-Native $Fastboot @("-s", $Serial, "getvar", $Name) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "无法读取 fastboot getvar ${Name}：`r`n$($result.Text)" }
    $escaped = [regex]::Escape($Name)
    foreach ($line in $result.Text -split "`r?`n") {
        if ($line -match "^(?:\(bootloader\)[ `t]*)?${escaped}:[ `t]*(.*?)[ `t]*$") {
            return $Matches[1].Trim()
        }
    }
    throw "无法解析 fastboot getvar ${Name}：`r`n$($result.Text)"
}

function Convert-HexBytes {
    param([string]$Value)
    if ($Value -notmatch '^0x([0-9a-fA-F]+)$') { throw "fastboot 容量格式无效：$Value" }
    [Convert]::ToInt64($Matches[1], 16)
}

function Find-UniqueBackup {
    param([string]$Label)
    $matches = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter "*.$Label.img")
    if ($matches.Count -ne 1) { throw "备份目录中 $Label 镜像数量不是 1：$($matches.Count)" }
    $matches[0].FullName
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $Fastboot -PathType Leaf)) {
    $command = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if (-not $command) { throw "缺少 fastboot.exe" }
    $Fastboot = $command.Source
}
if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
    throw "备份目录不存在：$BackupDirectory"
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "备份 SHA256 清单不存在：$ManifestPath"
}
if (-not $ConfirmRestoreAndroid) {
    throw "本脚本会覆盖 Android 的 boot/system/cache/userdata/recovery；确认备份属于本机后使用 -ConfirmRestoreAndroid"
}

$expectedHashes = @{}
foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
    if (-not $line) { continue }
    if ($line -notmatch '^([0-9a-f]{64})  ([^/\\]+)$') {
        throw "备份 SHA256 清单格式错误：$line"
    }
    $name = $Matches[2]
    if ($expectedHashes.ContainsKey($name)) { throw "备份 SHA256 清单存在重复文件：$name" }
    $expectedHashes[$name] = $Matches[1]
}

$images = [ordered]@{}
foreach ($label in @("boot", "system", "cache", "userdata", "recovery")) {
    $path = Find-UniqueBackup $label
    $name = [IO.Path]::GetFileName($path)
    $length = (Get-Item -LiteralPath $path).Length
    if ($length -ne $ExpectedPartitionBytes[$label]) {
        throw "$label 备份尺寸错误：$length，预期 $($ExpectedPartitionBytes[$label])"
    }
    if (-not $expectedHashes.ContainsKey($name)) {
        throw "备份 SHA256 清单缺少：$name"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHashes[$name]) {
        throw "$label 备份 SHA256 不匹配：$path"
    }
    $images[$label] = [pscustomobject]@{
        Path = $path
        Bytes = $length
        Sha256 = $actualHash
    }
}

$deviceResult = Invoke-Native $Fastboot @("devices") -AllowFailure
$devices = @($deviceResult.Text -split "`r?`n" |
    Where-Object { $_ -match '^([^\s]+)\s+fastboot\s*$' } |
    ForEach-Object { $Matches[1] })
if ($devices.Count -ne 1) { throw "必须且只能连接一台 fastboot 设备" }
$serial = $devices[0]
$product = Get-FastbootVariable $serial "product"
if ($product -notmatch "(?i)^$ExpectedProduct$") {
    throw "fastboot product 不匹配：$product"
}

$partitionSizes = [ordered]@{}
foreach ($label in $ExpectedPartitionBytes.Keys) {
    $size = Convert-HexBytes (Get-FastbootVariable $serial "partition-size:$label")
    if ($size -ne $ExpectedPartitionBytes[$label]) {
        throw "$label 分区尺寸不匹配：$size，预期 $($ExpectedPartitionBytes[$label])"
    }
    $partitionSizes[$label] = $size
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\android-restore" }
$OutputDirectory = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$preflight = @(
    "product=$product", "fastboot_serial=$serial",
    "backup_manifest=$ManifestPath",
    "restore_partitions=boot,system,cache,userdata,recovery", "device_writes=not_started"
)
foreach ($label in $images.Keys) {
    $preflight += "$label`_path=$($images[$label].Path)"
    $preflight += "$label`_bytes=$($images[$label].Bytes)"
    $preflight += "$label`_sha256=$($images[$label].Sha256)"
}
Write-Utf8File (Join-Path $OutputDirectory "preflight.txt") (($preflight -join "`r`n") + "`r`n")

Write-Host "目标、容量和本机备份均已核对；按 system/cache/userdata/recovery/boot 顺序恢复。"
foreach ($label in @("system", "cache", "userdata", "recovery", "boot")) {
    $result = Invoke-Native $Fastboot @("-s", $serial, "flash", $label, $images[$label].Path)
    Write-Utf8File (Join-Path $OutputDirectory "flash-$label.txt") ($result.Text + "`r`n")
}

if ($RebootAfterRestore) {
    $result = Invoke-Native $Fastboot @("-s", $serial, "reboot")
    Write-Utf8File (Join-Path $OutputDirectory "reboot.txt") ($result.Text + "`r`n")
}

$summary = @(
    "Android fastboot 恢复完成",
    "product=$product",
    "restore_partitions=system,cache,userdata,recovery,boot",
    "reboot=$($RebootAfterRestore.ToString().ToLowerInvariant())",
    "logs=$OutputDirectory"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDirectory "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
