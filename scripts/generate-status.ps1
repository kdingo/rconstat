#!/usr/bin/pwsh
# uses rcon from https://github.com/gorcon/rcon-cli
#
param(
    [string]$ConfigPath = "config/games.json",
    [string]$OutputPath = "public/index.html",
    [string]$RconBinary = "rcon"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$unixtime = [Math]::Round((Get-Date).ToUniversalTime().Subtract((Get-Date "1970-01-01")).TotalSeconds) * 1000


function Escape-Html {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) {
        return ""
    }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Invoke-RconCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][string]$ServerHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Binary
    $psi.Arguments = "-H $ServerHost -P $Port -p `"$Password`" `"$Command`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
    }
    catch {
        return [pscustomobject]@{
            Success  = $false
            ExitCode = -1
            Output   = ""
            Error    = "Failed to start rcon binary '$Binary': $($_.Exception.Message)"
        }
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill($true)
        }
        catch {
        }
        return [pscustomobject]@{
            Success  = $false
            ExitCode = -1
            Output   = ""
            Error    = "RCON timeout after $TimeoutSeconds second(s)"
        }
    }

    $stdout = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()
    $success = ($process.ExitCode -eq 0)

    return [pscustomobject]@{
        Success  = $success
        ExitCode = $process.ExitCode
        Output   = $stdout
        Error    = $stderr
    }
}

function Parse-CommandResult {
    param(
        [AllowNull()][string]$Output,
        [AllowNull()][string]$Regex,
        [int]$Group = 0
    )

    if ([string]::IsNullOrWhiteSpace($Regex)) {
        return $Output
    }
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $null
    }

    $match = [regex]::Match($Output, $Regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }
    if ($Group -ge $match.Groups.Count) {
        return $null
    }
    return $match.Groups[$Group].Value
}

function Get-ProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessNamePattern
    )

    $all = Get-Process -ErrorAction SilentlyContinue
    $matching = $all | Where-Object { $_.CommandLine -match $ProcessNamePattern }
    if (-not $matching) {
        return [pscustomobject]@{
            Found         = $false
            ProcessIds    = "N/A"
            ProcessNames  = "N/A"
            CpuPercent    = "N/A"
            MemoryMb      = "N/A"
            ProcessStatus = "Not Running"
            ErrorMessage  = ""
        }
    }

    $pidList = $matching.Id | Sort-Object
    $nameList = $matching.ProcessName | Sort-Object -Unique
    $memoryBytes = ($matching | Measure-Object -Property WorkingSet64 -Sum).Sum
    $memoryMb = [math]::Round(($memoryBytes / 1MB), 2)

    $cpuPercent = "N/A"
    try {
        $cpuValues = @()
        foreach ($pid in $pidList) {
            $raw = & ps -p $pid -o %cpu= 2>$null
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = 0.0
                if ([double]::TryParse($raw.Trim(), [ref]$parsed)) {
                    $cpuValues += $parsed
                }
            }
        }
        if ($cpuValues.Count -gt 0) {
            $cpuPercent = [math]::Round((($cpuValues | Measure-Object -Sum).Sum), 2).ToString()
        }
    }
    catch {
        $cpuPercent = "N/A"
    }

    return [pscustomobject]@{
        Found         = $true
        ProcessIds    = ($pidList -join ", ")
        ProcessNames  = ($nameList -join ", ")
        CpuPercent    = $cpuPercent
        MemoryMb      = $memoryMb.ToString()
        ProcessStatus = "Running"
        ErrorMessage  = ""
    }
}

function Get-GameStatus {
    param(
        [Parameter(Mandatory = $true)]$Game,
        [Parameter(Mandatory = $true)][string]$RconBinaryPath
    )

    $timeoutSeconds = 5
    if ($Game.timeoutSeconds) {
        $timeoutSeconds = [int]$Game.timeoutSeconds
    }

    $processInfo = Get-ProcessSnapshot -ProcessNamePattern $Game.processNamePattern
    $errors = [System.Collections.Generic.List[string]]::new()

    $playerCountResult = $null
    $versionResult = $null

    $commands = @{
        playerCount = $Game.commands.playerCount
        version = $Game.commands.version
    }

    foreach ($key in @("playerCount", "version")) {
        $cmdSpec = $commands[$key]
        if ($null -eq $cmdSpec -or [string]::IsNullOrWhiteSpace($cmdSpec.command)) {
            $errors.Add("Missing '$key' command config")
            continue
        }

        $invocation = Invoke-RconCommand -Binary $RconBinaryPath -ServerHost $Game.host -Port ([int]$Game.port) -Password $Game.password -Command $cmdSpec.command -TimeoutSeconds $timeoutSeconds
        if (-not $invocation.Success) {
            $errors.Add("$key command failed: $($invocation.Error)")
            continue
        }

        $group = 0
        if ($cmdSpec.group -ne $null) {
            $group = [int]$cmdSpec.group
        }
        $parsed = Parse-CommandResult -Output $invocation.Output -Regex $cmdSpec.regex -Group $group
        switch ($key) {
            "playerCount" { $playerCountResult = $parsed }
            "version" { $versionResult = $parsed }
        }
    }

    $isUp = if ($processInfo.Found) { "UP" } else { "DOWN" }

    if ([string]::IsNullOrWhiteSpace($playerCountResult)) {
        $playerCountResult = "0"
    }
    if ([string]::IsNullOrWhiteSpace($versionResult)) {
        $versionResult = "Unknown"
    }

    return [pscustomobject]@{
        Name          = $Game.name
        UpStatus      = $isUp
        PlayerCount   = $playerCountResult
        Version       = $versionResult
        ProcessIds    = $processInfo.ProcessIds
        ProcessNames  = $processInfo.ProcessNames
        CpuPercent    = $processInfo.CpuPercent
        MemoryMb      = $processInfo.MemoryMb
        ProcessStatus = $processInfo.ProcessStatus
        ErrorHint     = if ($errors.Count -gt 0) { ($errors -join " | ") } else { "" }
        DisplayOrder  = if ($Game.displayOrder -ne $null) { [int]$Game.displayOrder } else { 9999 }
    }
}

function ConvertTo-StatusPageHtml {
    param(
        [Parameter(Mandatory = $true)]$Rows
    )

    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
    $rowHtml = foreach ($row in ($Rows | Sort-Object -Property DisplayOrder, Name)) {
        $statusClass = if ($row.UpStatus -eq "UP") { "up" } else { "down" }
        @"
<tr>
  <td>$(Escape-Html $row.Name)</td>
  <td><span class="badge $statusClass">$(Escape-Html $row.UpStatus)</span></td>
  <td>$(Escape-Html $row.PlayerCount)</td>
  <td>$(Escape-Html $row.Version)</td>
  <td>$(Escape-Html $row.ProcessIds)</td>
  <td>$(Escape-Html $row.ProcessNames)</td>
  <td>$(Escape-Html $row.CpuPercent)</td>
  <td>$(Escape-Html $row.MemoryMb)</td>
  <td>$(Escape-Html $row.ProcessStatus)</td>
  <td>$(Escape-Html $row.ErrorHint)</td>
</tr>
"@
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Game Server Status</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; background: #111; color: #eee; }
    h1 { margin-bottom: 0.2rem; }
    .timestamp { color: #bbb; margin-bottom: 1rem; }
    table { width: 100%; border-collapse: collapse; }
    th, td { border: 1px solid #333; padding: 0.55rem; text-align: left; vertical-align: top; }
    th { background: #1d1d1d; }
    tr:nth-child(even) { background: #161616; }
    .badge { padding: 0.15rem 0.45rem; border-radius: 0.35rem; font-weight: 700; display: inline-block; }
    .up { background: #1c7f37; color: #fff; }
    .down { background: #9c2f2f; color: #fff; }
  </style>
<script>
    function timeAgo(timestamp) {
        const currentTimestamp = Date.now();
        const timeDifference = currentTimestamp - timestamp;
        // Define time intervals in milliseconds
        const minute = 60 * 1000;
        const hour = 60 * minute;
        const day = 24 * hour;
        const week = 7 * day;
        const month = 30 * day;
        const year = 365 * day;
      
        if (timeDifference < minute) {
          const seconds = Math.floor(timeDifference / 1000);
          return `${seconds} second${seconds === 1 ? '' : 's'} ago`;
        } else if (timeDifference < hour) {
          const minutes = Math.floor(timeDifference / minute);
          return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;
        } else if (timeDifference < day) {
          const hours = Math.floor(timeDifference / hour);
          return `${hours} hour${hours === 1 ? '' : 's'} ago`;
        } else if (timeDifference < week) {
          const days = Math.floor(timeDifference / day);
          return `${days} day${days === 1 ? '' : 's'} ago`;
        } else if (timeDifference < month) {
          const weeks = Math.floor(timeDifference / week);
          return `${weeks} week${weeks === 1 ? '' : 's'} ago`;
        } else if (timeDifference < year) {
          const months = Math.floor(timeDifference / month);
          return `${months} month${months === 1 ? '' : 's'} ago`;
        } else {
          const years = Math.floor(timeDifference / year);
          return `${years} year${years === 1 ? '' : 's'} ago`;
        }
    }
    function updateDisplay(timestamp) {
        const timeAgoDisplay = document.getElementById('timeAgoDisplay');
        timeAgoDisplay.textContent = timeAgo(timestamp);
    }
    </script>
</head>
<body>
  <h1>Game Server Status</h1>
  <div class="timestamp">Generated: $nowUtc</div>
  <table>
    <thead>
      <tr>
        <th>Game</th>
        <th>Server</th>
        <th>Players</th>
        <th>Version</th>
        <th>PID</th>
        <th>Process</th>
        <th>CPU (%)</th>
        <th>Memory (MB)</th>
        <th>Process Status</th>
        <th>Error Hint</th>
      </tr>
    </thead>
    <tbody>
      $($rowHtml -join [Environment]::NewLine)
    </tbody>
  </table>
<script>
        const timestamp = $unixtime;

        // Initial display
        updateDisplay(timestamp);

        // Update the display every second
        setInterval(function() {
          updateDisplay(timestamp);
        }, 1000);
    </script>
</body>
</html>
"@
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file '$ConfigPath' does not exist."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($null -eq $config.games -or $config.games.Count -eq 0) {
    throw "No games are configured in '$ConfigPath'."
}

$rows = foreach ($game in $config.games) {
    try {
        Get-GameStatus -Game $game -RconBinaryPath $RconBinary
    }
    catch {
        [pscustomobject]@{
            Name          = $game.name
            UpStatus      = "DOWN"
            PlayerCount   = "0"
            Version       = "Unknown"
            ProcessIds    = "N/A"
            ProcessNames  = "N/A"
            CpuPercent    = "N/A"
            MemoryMb      = "N/A"
            ProcessStatus = "Unknown"
            ErrorHint     = $_.Exception.Message
            DisplayOrder  = if ($game.displayOrder -ne $null) { [int]$game.displayOrder } else { 9999 }
        }
    }
}

$html = ConvertTo-StatusPageHtml -Rows $rows
$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$tmpPath = "$OutputPath.tmp"
Set-Content -LiteralPath $tmpPath -Value $html -Encoding UTF8
Move-Item -LiteralPath $tmpPath -Destination $OutputPath -Force

Write-Host "Wrote status page to $OutputPath"
