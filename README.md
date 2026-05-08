# AI Usage Node

A Cinnamon panel applet that surfaces your **Claude Code subscription usage** where you actually look — the toolbar.

It reads the OAuth token that `claude` already stores in `~/.claude/.credentials.json` and polls `/api/oauth/usage` (the same endpoint the `/usage` slash command uses), so the numbers are exactly what you'd see inside a Claude session — **percentages, not dollars**. No API key, no extra spend.

![Linux Mint](https://img.shields.io/badge/Linux%20Mint-22%2B-87CF3E?logo=linuxmint)
![Cinnamon](https://img.shields.io/badge/Cinnamon-6.x-04B060)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **Real subscription quota %, not token-cost estimates** — uses the same `/api/oauth/usage` endpoint as Claude Code's `/usage` command.
- **Rate-limit-friendly by default** — fetches once at startup, then only when you click the icon (with a small debounce so rapid clicks don't pile up). Auto-refresh on a timer is opt-in, hidden behind a toggle, defaults to 10-minute intervals when enabled.
- **Per-window breakdown** — 5-hour, 7-day all-models, 7-day Opus, 7-day Sonnet, plus Extra Usage credits when enabled.
- **Reset times shown both ways** — absolute clock-time with smart formatting (*"today at 6:10 PM"* / *"tomorrow at…"* / *"Mon May 12 at 2:00 AM"*) **and** a live countdown (*"in 4h 50m"*).
- **Color-coded sparkle icon** — Claude orange → amber → red as you cross configurable warn/alert thresholds. The icon shape stays consistent; only the color changes.
- **Optional icon-only mode** — hide the panel-label percentage for a minimal look; click the icon for full detail.
- **Friendly error states** — detects HTTP 429 (rate limited) and 401/403 (token expired) and surfaces what you need to do.
- **One-click "Open Claude in terminal"** action.
- **Configurable** — refresh mode, label format (5h/7d, 5h-only, 7d-only, max-of-all), thresholds, terminal command.
- **No API key required** — reuses your existing Claude Code OAuth login.
- **Zero dependencies** beyond `curl` (already on every Linux Mint install).

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/CustomerNode/AIUsageNode/main/install.sh | bash
```

### From a clone

```bash
git clone https://github.com/CustomerNode/AIUsageNode.git
cd AIUsageNode
./install.sh
```

After install, **right-click your panel → Applets → AI Usage Node → Add to panel**, or run the `install.sh` script with the `--add` flag to drop it into the right side of your bottom panel automatically.

## Configure

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

The popup itself shows a status line like `Updated just now · 2:48 PM · click to refresh` (or `auto every 10 min` when timer mode is on) so it's always obvious how stale the data is.

## How it works

`claude` stores an OAuth access token in `~/.claude/.credentials.json` after you log in with your subscription. This applet reads that token and calls:

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

That's it. The applet caches nothing, stores nothing, and never sends anything anywhere except that one Anthropic request. If the token expires, run `claude` once in a terminal to refresh it; the applet recovers on its next poll.

## Uninstall

```bash
./uninstall.sh
```

Or manually:

```bash
rm -rf ~/.local/share/cinnamon/applets/aiusagenode@CustomerNode
```

…then remove it from the panel via right-click → *Remove from panel*.

## Compatibility

- **Linux Mint 22.x** with **Cinnamon 6.x** — tested on Mint 22.3 / Cinnamon 6.6.7.
- Should work on any Cinnamon ≥ 5.x; if you find a regression on an older version please open an issue.
- Requires `claude` (Claude Code CLI) to be installed and logged in. <https://docs.claude.com/claude-code>

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC. This applet uses the public OAuth endpoint your own Claude Code CLI already calls; it does not bypass, scrape, or modify anything.
