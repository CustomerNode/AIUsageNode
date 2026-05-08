// Claude Quota — Cinnamon panel applet
// Reads ~/.claude/.credentials.json and calls
// https://api.anthropic.com/api/oauth/usage (same endpoint Claude Code's
// /usage slash command uses) to display percentage-based subscription usage.

const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Settings = imports.ui.settings;
const Util = imports.misc.util;
const St = imports.gi.St;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const Mainloop = imports.mainloop;

const UUID = "aiusagenode@CustomerNode";
const APPLET_DIR = GLib.get_user_data_dir() + "/cinnamon/applets/" + UUID;
const ICON_OK    = APPLET_DIR + "/icon-ok.svg";
const ICON_WARN  = APPLET_DIR + "/icon-warn.svg";
const ICON_ALERT = APPLET_DIR + "/icon-alert.svg";
const CREDS_PATH = GLib.get_home_dir() + "/.claude/.credentials.json";
const ENDPOINT   = "https://api.anthropic.com/api/oauth/usage";

function _bytesToString(bytes) {
    try {
        if (typeof bytes === "string") return bytes;
        // Modern GJS
        if (typeof TextDecoder !== "undefined") {
            return new TextDecoder("utf-8").decode(bytes);
        }
    } catch (e) { /* fall through */ }
    try {
        return imports.byteArray.toString(bytes);
    } catch (e) {
        return String(bytes);
    }
}

function _color(util) {
    if (util == null) return "#888";
    if (util >= 90) return "#ff5252";
    if (util >= 75) return "#ffa726";
    if (util >= 50) return "#ffd54f";
    return "#7ed957";
}

function _countdown(iso) {
    if (!iso) return "—";
    try {
        const d = new Date(iso);
        const ms = d.getTime() - Date.now();
        if (isNaN(ms)) return "—";
        if (ms <= 0) return "any moment";
        const s = Math.floor(ms / 1000);
        if (s < 3600) return Math.floor(s / 60) + "m";
        if (s < 86400) {
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            return h + "h " + m + "m";
        }
        const d2 = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        return d2 + "d " + h + "h";
    } catch (e) {
        return "—";
    }
}

function _absoluteReset(iso) {
    if (!iso) return "";
    try {
        const d = new Date(iso);
        if (isNaN(d.getTime())) return "";
        const now = new Date();
        const sameDay =
            d.getFullYear() === now.getFullYear() &&
            d.getMonth() === now.getMonth() &&
            d.getDate() === now.getDate();
        const tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
        const isTomorrow =
            d.getFullYear() === tomorrow.getFullYear() &&
            d.getMonth() === tomorrow.getMonth() &&
            d.getDate() === tomorrow.getDate();
        const time = d.toLocaleTimeString([], {
            hour: "numeric", minute: "2-digit"
        });
        if (sameDay)    return "today at " + time;
        if (isTomorrow) return "tomorrow at " + time;
        const dayName = d.toLocaleDateString([], { weekday: "short" });
        const date    = d.toLocaleDateString([], { month: "short", day: "numeric" });
        return dayName + " " + date + " at " + time;
    } catch (e) {
        return "";
    }
}

function _pickPct(obj) {
    return obj && (typeof obj.utilization === "number") ? obj.utilization : null;
}

class ClaudeQuotaApplet extends Applet.TextIconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this.metadata = metadata;
        this._refreshTimeout = 0;
        this._lastData = null;
        this._lastError = null;
        this._lastFetchAt = 0;     // ms epoch of last successful fetch
        this._inFlight = false;    // network call currently running
        this._cooldownUntil = 0;   // ms epoch; refuse to fetch before this
        this._cooldownTickTimeout = 0;

        this.set_applet_icon_path(ICON_OK);
        this.set_applet_label(" …");
        this.set_applet_tooltip("Claude usage — click to load");

        // Settings (must come before menu construction so terminalCommand is bound)
        this.settings = new Settings.AppletSettings(this, UUID, instanceId);
        this.settings.bind("auto-refresh",          "autoRefresh",         () => this._scheduleRefresh());
        this.settings.bind("refresh-seconds",       "refreshSeconds",      () => this._scheduleRefresh());
        this.settings.bind("click-debounce-seconds","clickDebounceSeconds",() => {});
        this.settings.bind("show-panel-label",      "showPanelLabel",      () => this._render());
        this.settings.bind("label-format",          "labelFormat",         () => this._render());
        this.settings.bind("warn-threshold",        "warnThreshold",       () => this._render());
        this.settings.bind("alert-threshold",       "alertThreshold",      () => this._render());
        this.settings.bind("terminal-command",      "terminalCommand",     () => {});

        // Popup menu
        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);
        this._buildMenu();

        // Initial fetch on load (so the panel shows real numbers right away),
        // then auto-refresh only if user opted in.
        this._refresh();
    }

    on_applet_clicked(event) {
        // Open the popup immediately, then maybe trigger a refresh in the
        // background. Any new data updates the popup in place.
        this.menu.toggle();
        this._refreshIfStale();
    }

    on_applet_removed_from_panel() {
        if (this._refreshTimeout > 0) {
            Mainloop.source_remove(this._refreshTimeout);
            this._refreshTimeout = 0;
        }
        if (this._cooldownTickTimeout > 0) {
            Mainloop.source_remove(this._cooldownTickTimeout);
            this._cooldownTickTimeout = 0;
        }
        try { this.settings.finalize(); } catch (e) { /* ignore */ }
    }

    _refreshIfStale() {
        // In a rate-limit cooldown? Don't even try — show the age/cooldown line.
        if (Date.now() < this._cooldownUntil) {
            this._updateAgeLine();
            return;
        }
        const debounce = (this.clickDebounceSeconds == null) ? 5 : this.clickDebounceSeconds;
        const ageMs = Date.now() - this._lastFetchAt;
        if (this._lastFetchAt && ageMs < debounce * 1000) {
            // Recently fetched — skip the network call but make sure age line is fresh.
            this._updateAgeLine();
            return;
        }
        this._refresh();
    }

    _updateAgeLine() {
        if (!this._statusItem) return;

        // Cooldown after a 429 takes priority — we want the user to know.
        const remainCool = Math.ceil((this._cooldownUntil - Date.now()) / 1000);
        if (remainCool > 0) {
            const m = Math.floor(remainCool / 60);
            const s = remainCool % 60;
            const fmt = m > 0 ? (m + "m " + s + "s") : (s + "s");
            this._statusItem.label.set_text(
                "Rate-limited — cooling down · retry in " + fmt);
            return;
        }
        if (!this._lastFetchAt) {
            this._statusItem.label.set_text("Click the icon to load.");
            return;
        }
        const ageS = Math.floor((Date.now() - this._lastFetchAt) / 1000);
        let ageText;
        if (ageS < 5)         ageText = "just now";
        else if (ageS < 60)   ageText = ageS + " s ago";
        else if (ageS < 3600) ageText = Math.floor(ageS / 60) + " min ago";
        else                  ageText = Math.floor(ageS / 3600) + " h ago";
        const stamp = new Date(this._lastFetchAt).toLocaleTimeString([], {
            hour: "numeric", minute: "2-digit"
        });
        const mode = this.autoRefresh
            ? ("auto every " + Math.round((this.refreshSeconds || 600) / 60) + " min")
            : "click to refresh";
        this._statusItem.label.set_text(
            "Updated " + ageText + " · " + stamp + " · " + mode);
    }

    // ----------------------------------------------------------------
    // Menu
    // ----------------------------------------------------------------
    _buildMenu() {
        this.menu.removeAll();

        this._headerItem = new PopupMenu.PopupMenuItem("Claude Usage", { reactive: false });
        this._headerItem.label.set_style("font-weight: bold; font-size: 12pt;");
        this.menu.addMenuItem(this._headerItem);

        this._statusItem = new PopupMenu.PopupMenuItem("Loading…", { reactive: false });
        this._statusItem.label.set_style("font-size: 9pt; color: #aaa;");
        this.menu.addMenuItem(this._statusItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._barSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._barSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const refreshItem = new PopupMenu.PopupMenuItem("Refresh now");
        refreshItem.connect("activate", () => this._refresh());
        this.menu.addMenuItem(refreshItem);

        const termItem = new PopupMenu.PopupMenuItem("Open Claude in terminal");
        termItem.connect("activate", () => this._openTerminal());
        this.menu.addMenuItem(termItem);

        const settingsItem = new PopupMenu.PopupMenuItem("Configure…");
        settingsItem.connect("activate", () =>
            Util.spawnCommandLine("xlet-settings applet " + UUID));
        this.menu.addMenuItem(settingsItem);
    }

    // ----------------------------------------------------------------
    // Refresh
    // ----------------------------------------------------------------
    _scheduleRefresh() {
        // Cancel any existing timer first.
        if (this._refreshTimeout > 0) {
            Mainloop.source_remove(this._refreshTimeout);
            this._refreshTimeout = 0;
        }
        // Only schedule when the user has opted into auto-refresh.
        if (!this.autoRefresh) return;
        const s = Math.max(60, this.refreshSeconds || 600);
        this._refreshTimeout = Mainloop.timeout_add_seconds(s, () => {
            this._refresh();
            return true;
        });
    }

    _readToken() {
        try {
            const [ok, content] = GLib.file_get_contents(CREDS_PATH);
            if (!ok) return null;
            const text = _bytesToString(content);
            const j = JSON.parse(text);
            if (j.claudeAiOauth && j.claudeAiOauth.accessToken) {
                return j.claudeAiOauth.accessToken;
            }
            return null;
        } catch (e) {
            global.logError("[claude-quota] readToken: " + e.message);
            return null;
        }
    }

    _refresh() {
        // Guard against overlapping fetches (e.g. user clicking rapidly).
        if (this._inFlight) return;

        // Honor the 429 cooldown so we don't keep poking the same wall.
        if (Date.now() < this._cooldownUntil) {
            this._updateAgeLine();
            return;
        }

        const token = this._readToken();
        if (!token) {
            this._showError("No Claude credentials",
                "Run `claude` once in a terminal to log in.");
            return;
        }

        // Use -w to capture the HTTP status code on its own line so we can
        // detect 429 / 401 even when curl is silenced.
        const argv = [
            "/usr/bin/curl", "-sS", "--max-time", "10",
            "-H", "Authorization: Bearer " + token,
            "-H", "User-Agent: claude-quota-applet/1.0",
            "-w", "\n__HTTP__%{http_code}",
            ENDPOINT
        ];
        this._inFlight = true;
        if (this._statusItem) this._statusItem.label.set_text("Fetching…");
        try {
            const proc = new Gio.Subprocess({
                argv: argv,
                flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            });
            proc.init(null);
            proc.communicate_utf8_async(null, null, (p, res) => {
                this._inFlight = false;
                let raw = "", stderr = "";
                try {
                    const r = p.communicate_utf8_finish(res);
                    raw = r[1] || "";
                    stderr = r[2] || "";
                } catch (e) {
                    this._showError("curl failed", e.message);
                    return;
                }
                // Split body and HTTP code (added by -w "\n__HTTP__%{http_code}").
                let body = raw, httpCode = 0;
                const m = raw.match(/^([\s\S]*)\n__HTTP__(\d+)\s*$/);
                if (m) {
                    body = m[1];
                    httpCode = parseInt(m[2], 10);
                }

                if (httpCode === 429) {
                    // Enter a 2-minute cooldown so further clicks don't pile on.
                    // If auto-refresh is on, also schedule a longer wait.
                    this._cooldownUntil = Date.now() + 120 * 1000;
                    this._showError("Rate limited (429)",
                        "Cooling down for 2 min. Turn off auto-refresh if it's on.");
                    // Schedule a one-shot tick so the countdown updates while the
                    // popup stays open.
                    this._scheduleCooldownTicks();
                    return;
                }
                if (httpCode === 401 || httpCode === 403) {
                    this._showError("Auth expired (" + httpCode + ")",
                        "Run `claude` in a terminal to refresh your token.");
                    return;
                }
                if (httpCode && (httpCode < 200 || httpCode >= 300)) {
                    this._showError("HTTP " + httpCode,
                        body.slice(0, 80) || stderr.slice(0, 80));
                    return;
                }
                if (!body || !body.trim()) {
                    this._showError("API: empty response", stderr.slice(0, 80));
                    return;
                }
                try {
                    const data = JSON.parse(body);
                    if (data && (data.error || data.type === "error")) {
                        const msg = (data.error && data.error.message) ||
                                    data.message || data.type || "unknown error";
                        this._showError("API error", String(msg).slice(0, 100));
                        return;
                    }
                    this._lastData = data;
                    this._lastError = null;
                    this._lastFetchAt = Date.now();
                    this._render();
                } catch (e) {
                    this._showError("Parse error", e.message);
                }
            });
        } catch (e) {
            this._inFlight = false;
            this._showError("Spawn error", e.message);
        }
    }

    _showError(title, detail) {
        this._lastError = title + (detail ? ": " + detail : "");

        // If we have prior good data, KEEP showing it in the panel — flagging
        // staleness with the alert icon and the popup status line. This way a
        // transient 429 doesn't wipe your real numbers.
        if (this._lastData) {
            // Re-run the normal render (preserves panel label / bars), then
            // override the icon to alert and the tooltip to surface the error.
            this._render();
            this.set_applet_icon_path(ICON_ALERT);
            this.set_applet_tooltip("Claude quota — " + title +
                (detail ? "\n" + detail : "") +
                "\n(showing last cached values)");
            if (this._statusItem) {
                this._statusItem.label.set_text(this._lastError);
            }
            // The cooldown line, if any, takes priority — refresh after the
            // override so the user sees the countdown.
            this._updateAgeLine();
            return;
        }

        // No prior data — fall back to the visible error state.
        this.set_applet_label(" ?");
        this.set_applet_icon_path(ICON_ALERT);
        this.set_applet_tooltip("Claude quota — " + title +
            (detail ? "\n" + detail : ""));
        if (this._statusItem) {
            this._statusItem.label.set_text(this._lastError);
        }
    }

    _scheduleCooldownTicks() {
        if (this._cooldownTickTimeout > 0) {
            Mainloop.source_remove(this._cooldownTickTimeout);
            this._cooldownTickTimeout = 0;
        }
        const tick = () => {
            this._updateAgeLine();
            if (Date.now() >= this._cooldownUntil) {
                this._cooldownTickTimeout = 0;
                // Cooldown ended; if popup is open, gently restore the icon
                // to its data-driven color (don't auto-fetch — user can click).
                if (this._lastData) this._render();
                return false; // stop
            }
            return true;
        };
        this._cooldownTickTimeout = Mainloop.timeout_add_seconds(1, tick);
    }

    // ----------------------------------------------------------------
    // Render
    // ----------------------------------------------------------------
    _render() {
        const d = this._lastData;
        if (!d) return;

        const fiveH = _pickPct(d.five_hour);
        const sevenD = _pickPct(d.seven_day);
        const sevenOpus = _pickPct(d.seven_day_opus);
        const sevenSonnet = _pickPct(d.seven_day_sonnet);

        // Panel label (icon-only mode hides this entirely)
        if (this.showPanelLabel === false) {
            this.set_applet_label("");
        } else {
            const fmt = this.labelFormat || "5h_and_7d";
            let label;
            switch (fmt) {
                case "5h_only":
                    label = (fiveH != null ? Math.round(fiveH) + "%" : "?");
                    break;
                case "7d_only":
                    label = (sevenD != null ? Math.round(sevenD) + "%" : "?");
                    break;
                case "max": {
                    const m = Math.max(fiveH || 0, sevenD || 0, sevenOpus || 0, sevenSonnet || 0);
                    label = Math.round(m) + "%";
                    break;
                }
                default:
                    label = (fiveH != null ? Math.round(fiveH) : "?") + "/" +
                            (sevenD != null ? Math.round(sevenD) : "?") + "%";
            }
            this.set_applet_label(" " + label);
        }

        // Icon by max severity (Claude orange / amber / red sparkle)
        const maxUtil = Math.max(
            fiveH || 0, sevenD || 0, sevenOpus || 0, sevenSonnet || 0
        );
        const warn = (this.warnThreshold == null) ? 75 : this.warnThreshold;
        const alert = (this.alertThreshold == null) ? 90 : this.alertThreshold;
        let iconPath = ICON_OK;
        if (maxUtil >= alert)     iconPath = ICON_ALERT;
        else if (maxUtil >= warn) iconPath = ICON_WARN;
        this.set_applet_icon_path(iconPath);

        // Tooltip — both countdown and absolute time on each line
        const tt = ["Claude usage"];
        const ttLine = (label, info) => {
            if (info == null || typeof info.utilization !== "number") return;
            const abs = _absoluteReset(info.resets_at);
            tt.push("  " + label + ": " + info.utilization.toFixed(0) +
                    "%  ·  resets in " + _countdown(info.resets_at) +
                    (abs ? " (" + abs + ")" : ""));
        };
        ttLine("5-hour",       d.five_hour);
        ttLine("7-day all",    d.seven_day);
        ttLine("7-day Opus",   d.seven_day_opus);
        ttLine("7-day Sonnet", d.seven_day_sonnet);
        this.set_applet_tooltip(tt.join("\n"));

        // Status / age line ("Updated just now" / "Updated 8 min ago")
        this._updateAgeLine();

        // Bars
        this._barSection.removeAll();
        this._addBar("5-hour window",   d.five_hour);
        this._addBar("7-day all models", d.seven_day);
        if (d.seven_day_opus)   this._addBar("7-day Opus",   d.seven_day_opus);
        if (d.seven_day_sonnet) this._addBar("7-day Sonnet", d.seven_day_sonnet);
        if (d.extra_usage && d.extra_usage.is_enabled) {
            this._addExtraUsage(d.extra_usage);
        }
    }

    _addBar(name, info) {
        if (!info) return;
        const util  = (typeof info.utilization === "number") ? info.utilization : null;
        const reset = info.resets_at;

        const item = new PopupMenu.PopupBaseMenuItem({ reactive: false });
        const box = new St.BoxLayout({
            vertical: true,
            style: "spacing: 3px; padding: 6px 4px; min-width: 320px;"
        });

        // ---- Header line:  name ............................. NN% ----
        const headLine = new St.BoxLayout({
            vertical: false,
            style: "spacing: 8px;"
        });
        const nameLabel = new St.Label({
            text: name,
            style: "font-size: 10.5pt; color: #e8e8e8; font-weight: 500;"
        });
        const pctLabel = new St.Label({
            text: (util != null ? util.toFixed(0) + "%" : "—"),
            style: "font-size: 11pt; font-weight: bold; color: " + _color(util) + ";"
        });
        headLine.add(nameLabel, { expand: true });
        headLine.add(pctLabel);
        box.add(headLine);

        // ---- Progress bar (rounded, with subtle inset background) ----
        const barW = 320;
        const barOuter = new St.BoxLayout({
            style:
                "background-color: rgba(255,255,255,0.08);" +
                "height: 7px;" +
                "width: " + barW + "px;" +
                "border-radius: 4px;" +
                "margin-top: 1px;" +
                "margin-bottom: 1px;"
        });
        const fillW = Math.max(0, Math.min(barW,
            Math.round(barW * ((util || 0) / 100))));
        const barFill = new St.Bin({
            style:
                "background-color: " + _color(util) + ";" +
                "height: 7px;" +
                "width: " + fillW + "px;" +
                "border-radius: 4px;"
        });
        barOuter.add(barFill, { expand: false });
        box.add(barOuter);

        // ---- Reset line:  "Resets today at 6:10 PM   ·   in 4h 50m" ----
        const abs = _absoluteReset(reset);
        const cd  = _countdown(reset);
        const resetText = abs
            ? "Resets " + abs + "  ·  in " + cd
            : "Resets in " + cd;
        const resetLabel = new St.Label({
            text: resetText,
            style: "font-size: 9pt; color: #999;"
        });
        box.add(resetLabel);

        item.addActor(box, { expand: true });
        this._barSection.addMenuItem(item);
    }

    _addExtraUsage(info) {
        const item = new PopupMenu.PopupMenuItem("", { reactive: false });
        const used = info.used_credits || 0;
        const limit = info.monthly_limit || 0;
        const cur = info.currency || "$";
        const text = "Extra credits: " + used.toFixed(2) + " / " +
                     limit.toFixed(2) + " " + cur +
                     (info.utilization != null ? " (" + info.utilization.toFixed(0) + "%)" : "");
        item.label.set_text(text);
        item.label.set_style("font-size: 9pt; color: #bbb;");
        this._barSection.addMenuItem(item);
    }

    // ----------------------------------------------------------------
    // Actions
    // ----------------------------------------------------------------
    _openTerminal() {
        const cmd = this.terminalCommand || "gnome-terminal -- bash -lc 'claude'";
        try {
            Util.spawnCommandLine(cmd);
        } catch (e) {
            global.logError("[claude-quota] terminal launch: " + e.message);
        }
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new ClaudeQuotaApplet(metadata, orientation, panelHeight, instanceId);
}
