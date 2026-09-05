param(
    [string]$PortName = "COM5",
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [string]$OutputPath = "",
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$marker = "CODEX_" + [Guid]::NewGuid().ToString("N")
$endMarker = "${marker}_END"
$wireCommand = "echo ${marker}_BEGIN; ${Command}; rc=`$?; echo ${marker}_RC=`$rc; echo $endMarker"
$serial = [IO.Ports.SerialPort]::new(
    $PortName,
    115200,
    [IO.Ports.Parity]::None,
    8,
    [IO.Ports.StopBits]::One
)
$serial.ReadTimeout = 250
$serial.WriteTimeout = 1000
$serial.DtrEnable = $true
$serial.RtsEnable = $true
$output = [Text.StringBuilder]::new()
$completed = $false
$cursorRequest = ([string][char]27) + "[6n"
$cursorResponse = ([string][char]27) + "[1;5R"
$script:cursorResponses = 0

function Drain-Serial {
    $data = $serial.ReadExisting()
    if ($data) {
        [void]$output.Append($data)
    }
    $requestCount = [regex]::Matches(
        $output.ToString(),
        [regex]::Escape($cursorRequest)
    ).Count
    while ($script:cursorResponses -lt $requestCount) {
        $serial.Write($cursorResponse)
        $script:cursorResponses++
    }
}

function Send-SerialText {
    param([string]$Text)

    for ($offset = 0; $offset -lt $Text.Length; $offset += 4) {
        $count = [Math]::Min(4, $Text.Length - $offset)
        $serial.Write($Text.Substring($offset, $count))
        [Threading.Thread]::Sleep(5)
        Drain-Serial
    }
}

try {
    $serial.Open()
    Start-Sleep -Milliseconds 200
    [void]$serial.ReadExisting()
    Send-SerialText ([string][char]4)
    Start-Sleep -Milliseconds 800
    Drain-Serial
    Start-Sleep -Milliseconds 200
    Send-SerialText "stty -echo`r"
    Start-Sleep -Milliseconds 200
    Drain-Serial
    Send-SerialText ($wireCommand + "`r")

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        Drain-Serial
        if ($output.ToString() -match "(?m)^${endMarker}`r?$") {
            $completed = $true
            break
        }
    }
    Send-SerialText "stty echo`r"
} finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
}

$text = $output.ToString()
if ($OutputPath) {
    $resolvedOutput = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
    $parent = Split-Path -Parent $resolvedOutput
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($resolvedOutput, $text, [Text.UTF8Encoding]::new($false))
}

$text
if (-not $completed) {
    Write-Error "Serial command did not return an end marker within ${TimeoutSeconds} seconds."
    exit 2
}
