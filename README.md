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
  - `regex`: parser pattern for command output
  - `group`: capture group index to extract

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
