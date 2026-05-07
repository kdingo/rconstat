# rconstat

Static game server status page generator using PowerShell + RCON CLI.

## What it does

`scripts/generate-status.ps1` reads `config/games.json`, runs configured RCON commands per game, gathers process details, and generates a static page at `public/index.html`.

Each game row includes:

- server up/down (from `processNamePattern`, not RCON)
- logged-in player count
- server version
- process id(s)
- process name(s)
- CPU utilization
- memory usage (MB)
- process status
- error hint (if any polling step failed)

## Requirements

- `pwsh` (PowerShell 7+)
- `rcon` CLI available on `PATH` (or pass `-RconBinary` explicitly)
- host permissions to inspect processes and write output path

## Configuration

Edit `config/games.json` and add as many games as needed:

- `name`: display label
- `host`, `port`, `password`: RCON target
- `processNamePattern`: regex used against process name
- `displayOrder`: lower numbers render first
- `timeoutSeconds`: optional per-game command timeout
- `commands.playerCount`, `commands.version` (up/down follows `processNamePattern` match, not RCON):
  - `command`: RCON command string
  - `parseMode` (optional for `playerCount`): parsing strategy
    - `regex`: use `regex` + `group` (default when omitted)
    - `csv`: count non-empty player rows after CSV header
  - `regex`: parser pattern for command output (used by `parseMode: "regex"`)
  - `group`: capture group index to extract (used by `parseMode: "regex"`)

### `playerCount` parsing examples

Regex mode:

```json
"playerCount": {
  "command": "list",
  "parseMode": "regex",
  "regex": "There\\s+are\\s+(\\d+)\\s+of\\s+\\d+\\s+players\\s+online",
  "group": 1
}
```

CSV mode (PalWorld-style output):

```json
"playerCount": {
  "command": "showplayers",
  "parseMode": "csv"
}
```

For CSV mode, output is expected to have header `name,playeruid,steamid` followed by one row per player.

## Generate once

```bash
pwsh ./scripts/generate-status.ps1
```

Optional arguments:

```bash
pwsh ./scripts/generate-status.ps1 -ConfigPath ./config/games.json -OutputPath ./public/index.html -RconBinary rcon
```

## Cron example

Run every minute:

```cron
* * * * * /usr/bin/pwsh /home/dingo/Repos/rconstat/scripts/generate-status.ps1 -ConfigPath /home/dingo/Repos/rconstat/config/games.json -OutputPath /home/dingo/Repos/rconstat/public/index.html >> /home/dingo/Repos/rconstat/status-cron.log 2>&1
```

Serve `public/index.html` from any static web server.
