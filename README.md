# AI Usage Node

Surface your **Claude Code subscription usage** where you actually look — your toolbar / system tray.

It reads the OAuth token that `claude` already stores in `~/.claude/.credentials.json` and polls `/api/oauth/usage` (the same endpoint the `/usage` slash command uses), so the numbers are exactly what you'd see inside a Claude session — **percentages, not dollars**. No API key, no extra spend.

![Linux Mint](https://img.shields.io/badge/Linux%20Mint-22%2B-87CF3E?logo=linuxmint)
![Cinnamon](https://img.shields.io/badge/Cinnamon-6.x-04B060)
![Windows 11](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows)
![License](https://img.shields.io/badge/License-MIT-blue)

## Platforms

| Platform | Host | Location |
|---|---|---|
| **Linux Mint 22.x / Cinnamon 6.x** | Cinnamon panel applet (JavaScript) | [`aiusagenode@CustomerNode/`](aiusagenode@CustomerNode/) |
| **Windows 10 / 11** | System-tray app (PowerShell + WinForms) | [`windows/`](windows/) |

Both clients hit the same Anthropic endpoint, parse the same JSON shape, and render the same metrics. Pick the section below for your platform.

## Features

- **Real subscription quota %, not token-cost estimates** — uses the same `/api/oauth/usage` endpoint as Claude Code's `/usage` command.
- **Rate-limit-friendly by default** — fetches once at startup, then only when you click the icon (with a small debounce so rapid clicks don't pile up). Auto-refresh on a timer is opt-in, hidden behind a toggle, defaults to 10-minute intervals when enabled.
- **Per-window breakdown** — 5-hour, 7-day all-models, 7-day Opus, 7-day Sonnet, plus Extra Usage credits when enabled.
- **Reset times shown both ways** — absolute clock-time with smart formatting (*"today at 6:10 PM"* / *"tomorrow at…"* / *"Mon May 12 at 2:00 AM"*) **and** a live countdown (*"in 4h 50m"*).
- **Color-coded sparkle icon** — green → amber → red as you cross configurable warn/alert thresholds. The icon shape stays consistent; only the color changes.
- **Friendly error states** — detects HTTP 429 (rate limited) and 401/403 (token expired) and surfaces what you need to do.
- **One-click "Open Claude in terminal"** action.
- **Configurable** — refresh mode, label format (5h/7d, 5h-only, 7d-only, max-of-all), thresholds, terminal command.
- **No API key required** — reuses your existing Claude Code OAuth login.
- **Zero extra dependencies** — `curl` on Linux (always present on Mint); on Windows, just whatever PowerShell ships in-box.

---

## Linux Mint / Cinnamon

### Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/CustomerNode/AIUsageNode/main/install.sh | bash
```

From a clone:

```bash
git clone https://github.com/CustomerNode/AIUsageNode.git
cd AIUsageNode
./install.sh
```

After install, **right-click your panel → Applets → AI Usage Node → Add to panel**, or run the `install.sh` script with the `--add` flag to drop it into the right side of your bottom panel automatically.

### Configure

Right-click the sparkle in your panel → **Configure…**

| Setting | Default | What it does |
|---|---|---|
| Auto-refresh on a timer | **off** | When off, the applet only fetches when you click the icon (or pick *Refresh now*). When on, also polls automatically. |
| Auto-refresh interval | 600 s (10 min) | Used only when *Auto-refresh* is on. Min 60 s, max 1 h. |
| Skip refetch if data is newer than | 5 s | When you click the icon, skip the network call if the cached data is fresher than this. Set to 0 to always refetch on click. |
| Show percentage in panel | on | When off, panel shows only the colored sparkle icon. |
| Panel label format | `5h / 7d` | Choose between combined, 5-hour only, 7-day only, or max-of-all. |
| Warn threshold | 75 % | Icon turns amber at this level. |
| Alert threshold | 90 % | Icon turns red at this level. |
| Terminal command | `gnome-terminal -- bash -lc 'claude'` | Run by *Open Claude in terminal*. |

### Uninstall

```bash
./uninstall.sh
```

Or manually:

```bash
rm -rf ~/.local/share/cinnamon/applets/aiusagenode@CustomerNode
```

…then remove it from the panel via right-click → *Remove from panel*.

### Compatibility

- **Linux Mint 22.x** with **Cinnamon 6.x** — tested on Mint 22.3 / Cinnamon 6.6.7.
- Should work on any Cinnamon ≥ 5.x; if you find a regression on an older version please open an issue.

---

## Windows 10 / 11

A small PowerShell-hosted system-tray app — same colored sparkle, same metrics, same OAuth-token-only design. No `.exe` to compile, no extra dependencies beyond what Windows ships in-box.

### Install

From a clone (recommended):

```powershell
git clone https://github.com/CustomerNode/AIUsageNode.git
cd AIUsageNode\windows
.\install.ps1 -Start
```

`install.ps1` does three things:

1. Copies `AIUsageNode.ps1`, `start-aiusagenode.vbs`, and `uninstall.ps1` to `%LOCALAPPDATA%\AIUsageNode\`.
2. Registers `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\AIUsageNode` so the tray app autostarts at every login (skip with `-NoAutostart`).
3. With `-Start`, launches the tray app immediately via the silent VBS launcher.

If PowerShell blocks the script with an execution-policy error, allow it for your user once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Pin to the visible taskbar (Windows 11)

By default Windows 11 hides new tray icons under the `^` overflow chevron. You have two options:

- **GUI**: open the overflow tray, drag the colored sparkle onto the visible taskbar.
- **Programmatic**: the install script doesn't flip this for you (Microsoft considers it user choice), but you can do it after the icon shows up once. The relevant registry value is `HKCU\Control Panel\NotifyIconSettings\<UID>\IsPromoted` — set it to `1`, then restart the tray app. PowerShell:

  ```powershell
  $key = Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' |
      Where-Object { (Get-ItemProperty $_.PSPath).InitialTooltip -like 'AI Usage Node*' } |
      Select-Object -First 1
  Set-ItemProperty -Path $key.PSPath -Name 'IsPromoted' -Value 1 -Type DWord
  # then restart the tray:
  Get-Process pwsh | Where-Object { $_.CommandLine -like '*AIUsageNode*' } | Stop-Process -Force
  Start-Process wscript.exe "`"$env:LOCALAPPDATA\AIUsageNode\start-aiusagenode.vbs`""
  ```

### Interact with the tray icon

| Gesture | Action |
|---|---|
| Hover | Tooltip shows the headline percentages |
| Single left-click | Popup with bars + reset times (toggle — clicking again closes; clicking outside closes; Esc closes). Triggers a fetch **only** when there is no cached data yet and no active cooldown — never on every click. |
| Double left-click | Force a refresh (respecting the debounce setting) |
| Right-click | Context menu: Refresh now / Open Claude in terminal / Edit settings / Reload settings / Exit |

### Rate-limit behavior

`/api/oauth/usage` rate-limits aggressively — usually `Retry-After: 3600` after a 429. The Windows tray is built to **not** make that worse:

- **No background retry-on-error.** When a fetch fails (429 or anything else), the icon turns red and the tooltip explains why; the script never auto-retries. The only outbound HTTP calls are the one-shot fetch at startup, your explicit click, or your opt-in auto-refresh timer.
- **Cooldown is honored exactly as the server states.** A 429 with `Retry-After: 3600` produces a 1-hour cooldown; during that window every refresh path is a no-op. The full 429 response (headers + body) is dumped to `%LOCALAPPDATA%\AIUsageNode\last-429.json` for inspection.
- **Cooldown survives restarts.** Killing and relaunching the tray will not "reset" the backoff and trigger another 429 against the same wall.
- **Last successful response is cached on disk** at `%LOCALAPPDATA%\AIUsageNode\last-data.json`. Restarting the tray after a successful fetch shows the cached numbers instantly; if the cache is younger than five minutes, the startup auto-fetch is skipped entirely — the data is good, no point spending a request-slot on it. Older cache is still shown immediately on launch, then refreshed in the normal way.
- **Event log** at `%LOCALAPPDATA%\AIUsageNode\events.log` records every click, fetch decision, and HTTP result with millisecond timestamps so you can see exactly what the tray did, when, and why.

### Configure

Right-click the sparkle → **Edit settings** to open `%LOCALAPPDATA%\AIUsageNode\settings.json` in Notepad. Edit, save, then right-click → **Reload settings** (no restart needed).

| Key | Default | What it does |
|---|---|---|
| `auto-refresh` | `false` | When `true`, polls on a timer in addition to manual refreshes. |
| `refresh-seconds` | `600` | Auto-refresh interval. Min 60. |
| `click-debounce-seconds` | `5` | On double-click, skip refetch if data is fresher than this. |
| `show-panel-label` | `true` | (Reserved — Windows tray icons can't show inline text labels; left in for parity.) |
| `label-format` | `5h_and_7d` | `5h_and_7d` / `5h_only` / `7d_only` / `max`. |
| `warn-threshold` | `75` | Icon turns amber at this level. |
| `alert-threshold` | `90` | Icon turns red at this level. |
| `terminal-command` | `wt.exe pwsh -NoExit -Command claude` | Run by *Open Claude in terminal*. Change to `cmd.exe /K claude` or your preferred shell. |

### Uninstall

From the cloned repo:

```powershell
cd AIUsageNode\windows
.\uninstall.ps1
```

Or from the installed copy:

```powershell
& "$env:LOCALAPPDATA\AIUsageNode\uninstall.ps1"
```

The uninstaller stops the running tray, removes the autostart entry, and deletes `%LOCALAPPDATA%\AIUsageNode\`.

### Compatibility

- **Windows 11** (any build) and **Windows 10 1809+** — anywhere the modern `NotifyIcon` and `HKCU\...\NotifyIconSettings` exist.
- Works with the in-box **Windows PowerShell 5.1**; if **PowerShell 7+** (`pwsh.exe`) is installed, the launcher uses it automatically.
- Requires `claude` (Claude Code CLI) to be installed and logged in. <https://docs.claude.com/claude-code>

---

## How it works (both platforms)

`claude` stores an OAuth access token in `~/.claude/.credentials.json` (Linux/macOS) or `%USERPROFILE%\.claude\.credentials.json` (Windows) after you log in with your subscription. This applet reads that token and calls:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token>
```

The response looks like:

```json
{
  "five_hour":        { "utilization": 22.0, "resets_at": "2026-05-08T22:10:00Z" },
  "seven_day":        { "utilization": 15.0, "resets_at": "2026-05-12T06:00:00Z" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization":  0.0, "resets_at": "2026-05-12T06:00:00Z" },
  "extra_usage":      { "is_enabled": false, ... }
}
```

That's it. Neither client sends anything anywhere except that one Anthropic request. The Linux applet keeps state in memory; the Windows tray additionally caches the last successful response, rate-limit cooldown state, and an event log under `%LOCALAPPDATA%\AIUsageNode\` so a restart doesn't blank the display or trip the same rate-limit. Nothing is uploaded — all caching is local. If the token expires, run `claude` once in a terminal to refresh it; the icon recovers on its next poll.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC. These clients use the public OAuth endpoint your own Claude Code CLI already calls; they do not bypass, scrape, or modify anything.
