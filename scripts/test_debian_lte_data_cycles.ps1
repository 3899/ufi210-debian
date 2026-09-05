[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$')]
    [string]$Apn,
    [ValidatePattern('^$|^[A-Za-z0-9@._-]{1,64}$')]
    [string]$CarrierUsername = "",
    [ValidatePattern('^$|^[A-Za-z0-9._-]{1,64}$')]
    [string]$CarrierPassword = "",
    [ValidateRange(1, 100)]
    [int]$Cycles = 20,
    [string]$AdbSerial = "192.168.68.1:5555",
    [string]$ProbeAddress = "1.1.1.1",
    [ValidateRange(1, 65535)]
    [int]$ProbePort = 53,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$SingleTest = Join-Path $PSScriptRoot "test_debian_lte_data.ps1"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

if (-not (Test-Path -LiteralPath $SingleTest -PathType Leaf)) {
    throw "缺少单次 LTE 数据验收脚本：$SingleTest"
}
if ([string]::IsNullOrEmpty($CarrierUsername) -ne [string]::IsNullOrEmpty($CarrierPassword)) {
    throw "运营商用户名和密码必须同时提供或同时省略"
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "out\debian-system-device-test" }
$OutputDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ("lte-data-cycles-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$rows = New-Object Collections.Generic.List[object]
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $started = Get-Date
    $existingTestDirs = @(Get-ChildItem -LiteralPath $OutputDir -Directory |
        Where-Object { $_.Name -like "lte-data-*" } |
        ForEach-Object { $_.FullName })
    $arguments = @{
        Apn = $Apn
        AdbSerial = $AdbSerial
        ProbeAddress = $ProbeAddress
        ProbePort = $ProbePort
        OutputRoot = $OutputDir
    }
    if ($CarrierUsername) {
        $arguments.CarrierUsername = $CarrierUsername
        $arguments.CarrierPassword = $CarrierPassword
    }
    & $SingleTest @arguments
    $newTestDirs = @(Get-ChildItem -LiteralPath $OutputDir -Directory |
        Where-Object { $_.Name -like "lte-data-*" -and $existingTestDirs -notcontains $_.FullName })
    if ($newTestDirs.Count -ne 1) {
        throw "第 $cycle 轮未生成唯一的单次测试日志目录：实际新增 $($newTestDirs.Count) 个"
    }
    $cycleSummaryPath = Join-Path $newTestDirs[0].FullName "SUMMARY.txt"
    if (-not (Test-Path -LiteralPath $cycleSummaryPath -PathType Leaf)) {
        throw "第 $cycle 轮缺少单次测试汇总：$cycleSummaryPath"
    }
    $cycleSummary = Get-Content -LiteralPath $cycleSummaryPath -Raw -Encoding UTF8
    if ($cycleSummary -notmatch '(?m)^ipv4_configuration=NetworkManager-dispatcher\r?$') {
        throw "第 $cycle 轮未使用正式 NetworkManager dispatcher 配置 IPv4：$cycleSummaryPath"
    }
    $seconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    $rows.Add([pscustomobject]@{
        Cycle = $cycle
        Seconds = $seconds
        Result = "pass"
        Ipv4Configuration = "NetworkManager-dispatcher"
    })
    $rows | Export-Csv -LiteralPath (Join-Path $OutputDir "cycles.csv") -NoTypeInformation -Encoding UTF8
    Write-Host "LTE_DATA_CYCLE_PASS=$cycle/$Cycles seconds=$seconds"
}

$summary = @(
    "Debian LTE 数据连接循环验收通过"
    "cycles=$Cycles"
    "apn=explicitly-supplied"
    "carrier_authentication=$(if ($CarrierUsername) { 'explicitly-supplied' } else { 'not-supplied' })"
    "management=USB RNDIS + TCP ADB only"
    "temporary_connections_deleted=$Cycles"
    "partition_hash_checks=$Cycles"
    "ipv4_configuration=NetworkManager-dispatcher"
    "failures=0"
    "logs=$OutputDir"
) -join "`r`n"
Write-Utf8File (Join-Path $OutputDir "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
