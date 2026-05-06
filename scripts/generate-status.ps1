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
    $psi.Arguments = "-a $($ServerHost):$($Port) -p `"$Password`" `"$Command`""
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

function Format-Uptime {
    param(
        [Parameter(Mandatory = $true)][timespan]$Elapsed
    )

    return "{0}d {1:D2}h {2:D2}m {3:D2}s" -f $Elapsed.Days, $Elapsed.Hours, $Elapsed.Minutes, $Elapsed.Seconds
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
            Uptime        = "N/A"
            ErrorMessage  = ""
        }
    }

    $pidList = $matching.Id | Sort-Object
    $nameList = $matching.ProcessName | Sort-Object -Unique
    $memoryBytes = ($matching | Measure-Object -Property WorkingSet64 -Sum).Sum
    $memoryMb = [math]::Round(($memoryBytes / 1MB), 2)

    $TotalSec = (New-TimeSpan -Start $matching.StartTime).TotalSeconds
    $Usage = ($matching.CPU / ([Environment]::ProcessorCount * $TotalSec)) * 100
    $cpuPercent = [Math]::Round($Usage, 1)
    $oldestStartTime = ($matching.StartTime | Sort-Object | Select-Object -First 1)
    $uptime = Format-Uptime -Elapsed (New-TimeSpan -Start $oldestStartTime -End (Get-Date))

    return [pscustomobject]@{
        Found         = $true
        ProcessIds    = ($pidList -join ", ")
        ProcessNames  = ($nameList -join ", ")
        CpuPercent    = $cpuPercent
        MemoryMb      = $memoryMb.ToString()
        Uptime        = $uptime
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
        Uptime        = $processInfo.Uptime
        ErrorHint     = if ($errors.Count -gt 0) { ($errors -join " | ") } else { "" }
        DisplayOrder  = if ($Game.displayOrder -ne $null) { [int]$Game.displayOrder } else { 9999 }
    }
}

function ConvertTo-StatusPageHtml {
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [string]$PageTitle = "Game Server Status"
    )

    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
    $showErrorHintColumn = ($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ErrorHint) } | Measure-Object).Count -gt 0
    $rowHtml = foreach ($row in ($Rows | Sort-Object -Property DisplayOrder, Name)) {
        $statusClass = if ($row.UpStatus -eq "UP") { "up" } else { "down" }
        $errorHintCell = ""
        if (-not [string]::IsNullOrWhiteSpace($row.ErrorHint)) {
            $errorId = "error-" + ([Guid]::NewGuid().ToString("N"))
            $encodedError = Escape-Html $row.ErrorHint
            $errorHintCell = "<button type=`"button`" class=`"error-icon`" onclick=`"toggleErrorHint('$errorId')`" aria-label=`"Show error hint`">!</button><div id=`"$errorId`" class=`"error-message`" style=`"display:none;`">$encodedError</div>"
        }
        $errorHintColumnHtml = ""
        if ($showErrorHintColumn) {
            $errorHintColumnHtml = "  <td data-label=`"Error Hint`">$errorHintCell</td>"
        }
        @"
<tr>
  <td data-label="Game">$(Escape-Html $row.Name)</td>
  <td data-label="Server"><span class="badge $statusClass">$(Escape-Html $row.UpStatus)</span></td>
  <td data-label="Players">$(Escape-Html $row.PlayerCount)</td>
  <td data-label="Version">$(Escape-Html $row.Version)</td>
  <td data-label="PID">$(Escape-Html $row.ProcessIds)</td>
  <td data-label="Process">$(Escape-Html $row.ProcessNames)</td>
  <td data-label="CPU (%)">$(Escape-Html $row.CpuPercent)</td>
  <td data-label="Memory (MB)">$(Escape-Html $row.MemoryMb)</td>
  <td data-label="Uptime">$(Escape-Html $row.Uptime)</td>
$errorHintColumnHtml
</tr>
"@
    }
    $errorHintHeaderHtml = ""
    if ($showErrorHintColumn) {
        $errorHintHeaderHtml = "        <th>Error Hint</th>"
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta http-equiv="refresh" content="60">
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$(Escape-Html $PageTitle)</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #05070f;
      --panel: rgba(17, 24, 39, 0.8);
      --panel-border: #2b3142;
      --text-primary: #e6edf7;
      --text-muted: #9fb0cc;
      --header-bg: #0f1626;
      --row-alt: rgba(148, 163, 184, 0.06);
      --badge-up: #14532d;
      --badge-up-text: #bbf7d0;
      --badge-down: #7f1d1d;
      --badge-down-text: #fecaca;
      --focus: #60a5fa;
      --error: #f59e0b;
      --error-hover: #fbbf24;
      --error-text: #fed7aa;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Inter", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: radial-gradient(circle at top, #131d35 0%, var(--bg) 55%);
      color: var(--text-primary);
    }

    .page-shell {
      max-width: 1200px;
      margin: 0 auto;
      padding: 2rem 1.25rem 2.5rem;
    }

    .status-card {
      background: var(--panel);
      border: 1px solid var(--panel-border);
      border-radius: 1rem;
      overflow: hidden;
      box-shadow: 0 18px 45px rgba(0, 0, 0, 0.4);
      backdrop-filter: blur(8px);
    }

    .status-header {
      padding: 1.25rem 1.4rem;
      display: flex;
      gap: 1rem;
      justify-content: space-between;
      align-items: flex-start;
      border-bottom: 1px solid var(--panel-border);
      background: rgba(15, 22, 38, 0.75);
    }

    h1 {
      margin: 0;
      font-size: 1.5rem;
      letter-spacing: 0.01em;
    }

    .timestamp {
      margin-top: 0.35rem;
      color: var(--text-muted);
      font-size: 0.92rem;
    }

    .timestamp-utc {
      margin-top: 0;
      text-align: right;
      white-space: nowrap;
    }

    .table-wrap {
      width: 100%;
      overflow-x: auto;
    }

    table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
    }

    th,
    td {
      padding: 0.72rem 0.82rem;
      text-align: left;
      vertical-align: top;
      border-bottom: 1px solid var(--panel-border);
      font-size: 0.94rem;
    }

    th {
      position: sticky;
      top: 0;
      z-index: 1;
      background: var(--header-bg);
      color: #c2d3f0;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      font-size: 0.75rem;
    }

    tbody tr:nth-child(even) td {
      background: var(--row-alt);
    }

    tbody tr:hover td {
      background: rgba(96, 165, 250, 0.08);
    }

    .badge {
      padding: 0.2rem 0.5rem;
      border-radius: 999px;
      font-weight: 700;
      display: inline-block;
      font-size: 0.76rem;
      letter-spacing: 0.04em;
    }

    .up {
      background: var(--badge-up);
      color: var(--badge-up-text);
    }

    .down {
      background: var(--badge-down);
      color: var(--badge-down-text);
    }

    .error-icon {
      width: 1.5rem;
      height: 1.5rem;
      border: none;
      border-radius: 50%;
      background: var(--error);
      color: #111827;
      font-weight: 800;
      cursor: pointer;
      line-height: 1;
      padding: 0;
    }

    .error-icon:hover {
      background: var(--error-hover);
    }

    .error-icon:focus-visible {
      outline: 2px solid var(--focus);
      outline-offset: 2px;
    }

    .error-message {
      margin-top: 0.42rem;
      color: var(--error-text);
      white-space: normal;
      word-break: break-word;
      max-width: 32rem;
      line-height: 1.35;
    }

    @media (max-width: 860px) {
      .page-shell {
        padding: 1rem 0.7rem 1.4rem;
      }

      .status-header {
        flex-direction: column;
      }

      .timestamp-utc {
        text-align: left;
      }

      .table-wrap {
        overflow-x: visible;
      }

      table,
      tbody,
      tr,
      td {
        display: block;
        width: 100%;
      }

      thead {
        display: none;
      }

      tbody {
        padding: 0.35rem;
      }

      tbody tr {
        margin: 0.6rem 0;
        border: 1px solid var(--panel-border);
        border-radius: 0.75rem;
        overflow: hidden;
        background: rgba(15, 22, 38, 0.75);
      }

      tbody tr:nth-child(even) td,
      tbody tr:hover td {
        background: transparent;
      }

      tbody td {
        border-bottom: 1px solid var(--panel-border);
        padding: 0.6rem 0.72rem 0.65rem;
      }

      tbody td:last-child {
        border-bottom: none;
      }

      tbody td::before {
        content: attr(data-label);
        display: block;
        margin-bottom: 0.2rem;
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.04em;
        font-size: 0.7rem;
        font-weight: 600;
      }
    }
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
          return ```${seconds} second`${seconds === 1 ? '' : 's'} ago``;
        } else if (timeDifference < hour) {
          const minutes = Math.floor(timeDifference / minute);
          return ```${minutes} minute`${minutes === 1 ? '' : 's'} ago``;
        } else if (timeDifference < day) {
          const hours = Math.floor(timeDifference / hour);
          return ```${hours} hour`${hours === 1 ? '' : 's'} ago``;
        } else if (timeDifference < week) {
          const days = Math.floor(timeDifference / day);
          return ```${days} day`${days === 1 ? '' : 's'} ago``;
        } else if (timeDifference < month) {
          const weeks = Math.floor(timeDifference / week);
          return ```${weeks} week`${weeks === 1 ? '' : 's'} ago``;
        } else if (timeDifference < year) {
          const months = Math.floor(timeDifference / month);
          return ```${months} month`${months === 1 ? '' : 's'} ago``;
        } else {
          const years = Math.floor(timeDifference / year);
          return ```${years} year`${years === 1 ? '' : 's'} ago``;
        }
   }
    function updateDisplay(timestamp) {
        const timeAgoDisplay = document.getElementById('timeAgoDisplay');
        timeAgoDisplay.textContent = timeAgo(timestamp);
    }
    function toggleErrorHint(elementId) {
        const errorMessage = document.getElementById(elementId);
        if (!errorMessage) {
            return;
        }
        errorMessage.style.display = errorMessage.style.display === "none" ? "block" : "none";
    }
    </script>
</head>
<body>
  <main class="page-shell">
    <section class="status-card">
      <header class="status-header">
        <div>
          <h1>$(Escape-Html $PageTitle)</h1>
          <div class="timestamp">Last updated: <span id="timeAgoDisplay"></span></div>
        </div>
        <div class="timestamp timestamp-utc">Generated: $nowUtc</div>
      </header>
      <div class="table-wrap">
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
              <th>Uptime</th>
$errorHintHeaderHtml
            </tr>
          </thead>
          <tbody>
            $($rowHtml -join [Environment]::NewLine)
          </tbody>
        </table>
      </div>
    </section>
  </main>
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

$pageTitle = "Game Server Status"
if (-not [string]::IsNullOrWhiteSpace($config.pageTitle)) {
    $pageTitle = [string]$config.pageTitle
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
            Uptime        = "N/A"
            ErrorHint     = $_.Exception.Message
            DisplayOrder  = if ($game.displayOrder -ne $null) { [int]$game.displayOrder } else { 9999 }
        }
    }
}

$html = ConvertTo-StatusPageHtml -Rows $rows -PageTitle $pageTitle
$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$tmpPath = "$OutputPath.tmp"
Set-Content -LiteralPath $tmpPath -Value $html -Encoding UTF8
Move-Item -LiteralPath $tmpPath -Destination $OutputPath -Force

Write-Host "Wrote status page to $OutputPath"
