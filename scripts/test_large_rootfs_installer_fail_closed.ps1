[CmdletBinding()]
param(
    [string]$ManifestPath = "",
    [string]$RecoveryBackupDirectory = "",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Installer = Join-Path $ProjectRoot "scripts\install_debian_large_rootfs.ps1"
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $ProjectRoot "out\mainline\debian-large-rootfs\BUILD-MANIFEST.txt"
}
if (-not $RecoveryBackupDirectory) {
    $RecoveryBackupDirectory = Join-Path $ProjectRoot "resource\backup\gpt-20260907"
}
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $ProjectRoot "out\large-rootfs-installer-fault-injection"
}
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$RecoveryBackupDirectory = [IO.Path]::GetFullPath($RecoveryBackupDirectory)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$RunRoot = Join-Path $OutputRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$PowerShellExecutable = (Get-Process -Id $PID).Path

foreach ($path in @($Installer, $ManifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少输入文件：$path" }
}
foreach ($name in @("gpt-primary.bin", "gpt-backup.bin")) {
    $path = Join-Path $RecoveryBackupDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少设备专属 GPT 回读：$path" }
}

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Invoke-ExpectedFailure {
    param(
        [string]$Name,
        [string[]]$CommandArgs,
        [string]$ExpectedPattern
    )
    $caseDirectory = Join-Path $RunRoot $Name
    New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $PowerShellExecutable -NoLogo -NoProfile @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"
    Write-Utf8File (Join-Path $caseDirectory "output.txt") ((@(
        "exit_code=$exitCode", "expected_pattern=$ExpectedPattern", $text
    ) -join "`r`n") + "`r`n")
    if ($exitCode -eq 0 -or $text -notmatch $ExpectedPattern) {
        throw "故障注入未在预期门槛失败：$Name`r`n$text"
    }
    return "case=$Name result=passed exit_code=$exitCode"
}

function Copy-GptFixture {
    param([string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath (Join-Path $RecoveryBackupDirectory "gpt-primary.bin") `
        -Destination (Join-Path $Destination "gpt-primary.bin")
    Copy-Item -LiteralPath (Join-Path $RecoveryBackupDirectory "gpt-backup.bin") `
        -Destination (Join-Path $Destination "gpt-backup.bin")
}

function Flip-Byte {
    param([string]$Path, [int64]$Offset)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $stream.Position = $Offset
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw "故障注入偏移越过文件末尾：$Path@$Offset" }
        $stream.Position = $Offset
        $stream.WriteByte($value -bxor 1)
    } finally {
        $stream.Dispose()
    }
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

function Set-PrimaryGptDiskSectors {
    param([string]$Path, [uint64]$DiskSectors)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    [BitConverter]::GetBytes($DiskSectors - 1).CopyTo($bytes, 544)
    [Array]::Clear($bytes, 528, 4)
    [byte[]]$header = $bytes[512..603]
    [BitConverter]::GetBytes([uint32](Get-Crc32 $header)).CopyTo($bytes, 528)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-InstallerFixture {
    param([string]$Name, [ValidateSet("wrong-manifest", "wrong-hash", "truncated")][string]$Mode)
    $fixture = Join-Path $RunRoot $Name
    $fixtureScripts = Join-Path $fixture "scripts"
    New-Item -ItemType Directory -Force -Path $fixtureScripts | Out-Null
    Copy-Item -LiteralPath $Installer -Destination (Join-Path $fixtureScripts "install_debian_large_rootfs.ps1")
    [IO.File]::WriteAllBytes((Join-Path $fixture "adb.exe"), [byte[]]@(0))
    [IO.File]::WriteAllBytes((Join-Path $fixture "fastboot.exe"), [byte[]]@(0))
    foreach ($name in @(
        "debian-bookworm-armhf-large-rootfs-system.img",
        "debian-bookworm-armhf-large-rootfs-cache.img",
        "debian-bookworm-armhf-large-rootfs-userdata.img",
        "boot-debian-large-rootfs.img"
    )) {
        [IO.File]::WriteAllBytes((Join-Path $fixture $name), [byte[]]@(0))
    }
    $manifest = [IO.File]::ReadAllText($ManifestPath)
    switch ($Mode) {
        "wrong-manifest" {
            $manifest = $manifest -replace '(?m)^target_partition=large-rootfs$', 'target_partition=system'
        }
        "truncated" {
            $zeroHash = (Get-FileHash -LiteralPath (Join-Path $fixture "boot-debian-large-rootfs.img") `
                -Algorithm SHA256).Hash.ToLowerInvariant()
            foreach ($key in @(
                "rootfs_system_image_sha256", "rootfs_cache_image_sha256",
                "rootfs_userdata_image_sha256", "boot_image_sha256"
            )) {
                $manifest = $manifest -replace "(?m)^${key}=[0-9a-f]{64}$", "${key}=$zeroHash"
            }
        }
    }
    Write-Utf8File (Join-Path $fixture "INSTALL-MANIFEST.txt") $manifest
    return $fixture
}

New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
$results = [Collections.Generic.List[string]]::new()

$missingDirectory = Join-Path $RunRoot "missing-gpt"
$results.Add((Invoke-ExpectedFailure "missing-gpt" @(
    "-File", $Installer, "-ValidateRecoveryOnly", "-RecoveryBackupDirectory", $missingDirectory
) 'GPT 备份不存在或尺寸错误'))

$badPrimary = Join-Path $RunRoot "bad-primary-gpt"
Copy-GptFixture $badPrimary
Flip-Byte (Join-Path $badPrimary "gpt-primary.bin") 600
$results.Add((Invoke-ExpectedFailure "bad-primary-gpt-result" @(
    "-File", $Installer, "-ValidateRecoveryOnly", "-RecoveryBackupDirectory", $badPrimary
) '主 GPT 或备 GPT header CRC32 错误'))

$badBackup = Join-Path $RunRoot "bad-backup-gpt"
Copy-GptFixture $badBackup
Flip-Byte (Join-Path $badBackup "gpt-backup.bin") 16
$results.Add((Invoke-ExpectedFailure "bad-backup-gpt-result" @(
    "-File", $Installer, "-ValidateRecoveryOnly", "-RecoveryBackupDirectory", $badBackup
) '主 GPT 或备 GPT partition array CRC32 错误'))

$wrongDisk = Join-Path $RunRoot "wrong-disk-sectors"
Copy-GptFixture $wrongDisk
Set-PrimaryGptDiskSectors (Join-Path $wrongDisk "gpt-primary.bin") 7569407
$results.Add((Invoke-ExpectedFailure "wrong-disk-sectors-result" @(
    "-File", $Installer, "-ValidateRecoveryOnly", "-RecoveryBackupDirectory", $wrongDisk
) '主 GPT header 几何不匹配'))

$wrongManifest = New-InstallerFixture "wrong-manifest-fixture" "wrong-manifest"
$results.Add((Invoke-ExpectedFailure "wrong-manifest-result" @(
    "-File", (Join-Path $wrongManifest "scripts\install_debian_large_rootfs.ps1"),
    "-ConfirmPersistentInstall", "-ConfirmEraseCacheAndUserdata"
) '安装清单字段不匹配：target_partition'))

$wrongHash = New-InstallerFixture "wrong-hash-fixture" "wrong-hash"
$results.Add((Invoke-ExpectedFailure "wrong-hash-result" @(
    "-File", (Join-Path $wrongHash "scripts\install_debian_large_rootfs.ps1"),
    "-ConfirmPersistentInstall", "-ConfirmEraseCacheAndUserdata"
) 'SHA256 不匹配'))

$truncated = New-InstallerFixture "truncated-fixture" "truncated"
$results.Add((Invoke-ExpectedFailure "truncated-result" @(
    "-File", (Join-Path $truncated "scripts\install_debian_large_rootfs.ps1"),
    "-ConfirmPersistentInstall", "-ConfirmEraseCacheAndUserdata"
) 'system 根卷分段大小错误'))

$summaryLines = @(
    "large-rootfs 安装器故障注入通过",
    "cases=$($results.Count)",
    "device_access=none",
    "fastboot_erase_or_flash=none"
)
$summaryLines += $results.ToArray()
$summaryLines += @(
    "completed=$(Get-Date -Format o)",
    "logs=$RunRoot"
)
$summary = $summaryLines -join "`r`n"
Write-Utf8File (Join-Path $RunRoot "SUMMARY.txt") ($summary + "`r`n")
Write-Host $summary
