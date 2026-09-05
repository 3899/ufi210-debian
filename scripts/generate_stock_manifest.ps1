[CmdletBinding()]
param(
    [string]$SourceRoot = "",
    [string]$OutputPath = "",
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

trap {
    Write-Host ("生成清单失败：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $SourceRoot) {
    $SourceRoot = Join-Path $projectRoot "resource\backup"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot "out\manifests\stock-backup.sha256"
}

$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$output = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $output
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$files = Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName
if ($files.Count -eq 0) {
    throw "备份目录中没有文件：$source"
}

if ($Verify) {
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "待核验清单不存在：$output"
    }

    $manifestLines = Get-Content -LiteralPath $output -Encoding UTF8 | Where-Object { $_.Trim() -ne "" }
    if ($manifestLines.Count -ne $files.Count) {
        throw "清单文件数为 $($manifestLines.Count)，备份目录文件数为 $($files.Count)，二者不一致。"
    }

    $failures = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $index = 0
    foreach ($line in $manifestLines) {
        $index++
        if ($line -notmatch '^([0-9a-fA-F]{64}) \*(resource/backup/.+)$') {
            $failures.Add("格式错误：$line")
            continue
        }

        $expected = $Matches[1].ToLowerInvariant()
        $manifestPath = $Matches[2]
        if ($seen.ContainsKey($manifestPath)) {
            $failures.Add("重复路径：$manifestPath")
            continue
        }
        $seen[$manifestPath] = $true

        $filePath = Join-Path $projectRoot ($manifestPath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $failures.Add("文件不存在：$manifestPath")
            continue
        }

        Write-Progress -Activity "核验原厂备份 SHA256" -Status "$index / $($manifestLines.Count): $manifestPath" -PercentComplete (($index * 100) / $manifestLines.Count)
        $actual = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            $failures.Add("哈希不匹配：$manifestPath expected=$expected actual=$actual")
        }
    }
    Write-Progress -Activity "核验原厂备份 SHA256" -Completed

    if ($failures.Count -gt 0) {
        throw "清单核验失败：`r`n$($failures -join "`r`n")"
    }

    Write-Host "清单核验通过：$output"
    Write-Host "文件数：$($manifestLines.Count)"
    exit 0
}

$lines = New-Object System.Collections.Generic.List[string]
$index = 0
foreach ($file in $files) {
    $index++
    $relative = $file.FullName.Substring($source.Length).TrimStart('\').Replace('\', '/')
    Write-Progress -Activity "计算原厂备份 SHA256" -Status "$index / $($files.Count): $relative" -PercentComplete (($index * 100) / $files.Count)
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add("$hash *resource/backup/$relative")
}
Write-Progress -Activity "计算原厂备份 SHA256" -Completed

$content = ($lines -join "`n") + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($output, $content, $utf8NoBom)

Write-Host "已生成：$output"
Write-Host "文件数：$($files.Count)"
