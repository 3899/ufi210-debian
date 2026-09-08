[CmdletBinding()]
param(
    [ValidateSet("start", "status", "watch", "stop", "worker")]
    [string]$Action = "status",
    [ValidateRange(5, 1440)]
    [int]$TargetUptimeMinutes = 30,
    [ValidateRange(10, 300)]
    [int]$ProbeIntervalSeconds = 60,
    [ValidateRange(200, 2000)]
    [int]$PingIntervalMilliseconds = 500,
    [string]$DeviceIp = "192.168.68.1",
    [string]$OutputRoot = "",
    [string]$JobDir = "",
    [switch]$AllowUnregisteredModem
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\debian-large-rootfs-device-test"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$CurrentJobFile = Join-Path $OutputRoot "stability-background-current.txt"

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Write-JobStatus {
    param([string]$Directory, [string[]]$Lines)
    $statusPath = Join-Path $Directory "status.txt"
    $temporaryPath = "$statusPath.tmp"
    Write-Utf8File $temporaryPath (($Lines -join "`r`n") + "`r`n")
    Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
}

function Get-CurrentJobDirectory {
    if (-not (Test-Path -LiteralPath $CurrentJobFile -PathType Leaf)) {
        throw "没有后台稳定性测试记录：$CurrentJobFile"
    }
    $directory = [IO.File]::ReadAllText($CurrentJobFile).Trim()
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "后台稳定性测试目录无效：$directory"
    }
    return $directory
}

function Get-RecordedPid {
    param([string]$Directory)
    $pidPath = Join-Path $Directory "pid.txt"
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return 0 }
    $value = [IO.File]::ReadAllText($pidPath).Trim()
    $processId = 0
    if (-not [int]::TryParse($value, [ref]$processId)) { return 0 }
    return $processId
}

function Test-ProcessRunning {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Show-JobStatus {
    param([string]$Directory)
    $statusPath = Join-Path $Directory "status.txt"
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        Get-Content -LiteralPath $statusPath -Encoding UTF8
    } else {
        "state=unknown"
    }
    "job_dir=$Directory"
    "pid=$(Get-RecordedPid $Directory)"
}

if ($Action -eq "worker") {
    if (-not $JobDir) { throw "worker 缺少 -JobDir" }
    $JobDir = [IO.Path]::GetFullPath($JobDir)
    $readyPath = Join-Path $JobDir "launch.ready"
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ((Get-Date) -ge $deadline) { throw "后台启动握手超时" }
        Start-Sleep -Milliseconds 100
    }

    $runner = Join-Path $JobDir "monitor-runner.ps1"
    $exitCode = 0
    $result = "passed"
    try {
        $runnerParameters = @{
            TargetUptimeMinutes = $TargetUptimeMinutes
            ProbeIntervalSeconds = $ProbeIntervalSeconds
            PingIntervalMilliseconds = $PingIntervalMilliseconds
            DeviceIp = $DeviceIp
            OutputRoot = $JobDir
            ProjectRoot = $ProjectRoot
        }
        if ($AllowUnregisteredModem) {
            $runnerParameters.AllowUnregisteredModem = $true
        }
        & $runner @runnerParameters
    } catch {
        $exitCode = 1
        $result = "failed"
        [Console]::Error.WriteLine($_.Exception.ToString())
    } finally {
        Write-JobStatus $JobDir @(
            "state=$result"
            "exit_code=$exitCode"
            "finished_at=$(Get-Date -Format o)"
        )
    }
    exit $exitCode
}

if ($Action -eq "start") {
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    if (Test-Path -LiteralPath $CurrentJobFile -PathType Leaf) {
        $existingDirectory = [IO.File]::ReadAllText($CurrentJobFile).Trim()
        if ($existingDirectory -and (Test-Path -LiteralPath $existingDirectory -PathType Container)) {
            $existingPid = Get-RecordedPid $existingDirectory
            if (Test-ProcessRunning $existingPid) {
                throw "已有后台稳定性测试正在运行：pid=$existingPid job_dir=$existingDirectory"
            }
        }
    }

    $JobDir = Join-Path $OutputRoot ("stability-background-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $JobDir | Out-Null
    $runnerSource = Join-Path $PSScriptRoot "monitor_debian_stability.ps1"
    $runner = Join-Path $JobDir "monitor-runner.ps1"
    Copy-Item -LiteralPath $runnerSource -Destination $runner
    Write-Utf8File (Join-Path $JobDir "parameters.txt") ((@(
        "started_at=$(Get-Date -Format o)"
        "target_uptime_minutes=$TargetUptimeMinutes"
        "probe_interval_seconds=$ProbeIntervalSeconds"
        "ping_interval_milliseconds=$PingIntervalMilliseconds"
        "device_ip=$DeviceIp"
        "allow_unregistered_modem=$($AllowUnregisteredModem.ToString().ToLowerInvariant())"
        "runner_sha256=$((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant())"
    ) -join "`r`n") + "`r`n")
    Write-JobStatus $JobDir @("state=starting", "exit_code=")

    $arguments = @(
        "-NoProfile"
        "-NonInteractive"
        "-ExecutionPolicy", "Bypass"
        "-File", ('"{0}"' -f $PSCommandPath)
        "-Action", "worker"
        "-JobDir", ('"{0}"' -f $JobDir)
        "-TargetUptimeMinutes", $TargetUptimeMinutes
        "-ProbeIntervalSeconds", $ProbeIntervalSeconds
        "-PingIntervalMilliseconds", $PingIntervalMilliseconds
        "-DeviceIp", $DeviceIp
    )
    if ($AllowUnregisteredModem) { $arguments += "-AllowUnregisteredModem" }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $JobDir "stdout.log") `
        -RedirectStandardError (Join-Path $JobDir "stderr.log")
    Write-Utf8File (Join-Path $JobDir "pid.txt") ("$($process.Id)`r`n")
    Write-JobStatus $JobDir @(
        "state=running"
        "exit_code="
        "started_at=$(Get-Date -Format o)"
    )
    Write-Utf8File $CurrentJobFile ("$JobDir`r`n")
    Write-Utf8File (Join-Path $JobDir "launch.ready") "ready`r`n"
    Show-JobStatus $JobDir
    exit 0
}

$JobDir = Get-CurrentJobDirectory
$recordedPid = Get-RecordedPid $JobDir
if ($Action -eq "stop") {
    if (Test-ProcessRunning $recordedPid) {
        Stop-Process -Id $recordedPid -Force
        Wait-Process -Id $recordedPid -ErrorAction SilentlyContinue
    }
    Write-JobStatus $JobDir @(
        "state=canceled"
        "exit_code=130"
        "finished_at=$(Get-Date -Format o)"
        "reason=stopped-by-user"
    )
    Show-JobStatus $JobDir
    exit 0
}
if ($Action -eq "watch" -and (Test-ProcessRunning $recordedPid)) {
    Wait-Process -Id $recordedPid
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $status = if (Test-Path -LiteralPath (Join-Path $JobDir "status.txt")) {
            [IO.File]::ReadAllText((Join-Path $JobDir "status.txt"))
        } else { "" }
        if ($status -match '(?m)^state=(?:passed|failed)\r?$') { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
}

Show-JobStatus $JobDir
$finalStatus = [IO.File]::ReadAllText((Join-Path $JobDir "status.txt"))
if ($finalStatus -match '(?m)^state=failed\r?$') { exit 1 }
if ($Action -eq "watch" -and $finalStatus -notmatch '(?m)^state=passed\r?$') { exit 2 }
