# AI Usage Node - Windows tray app
# Polls Claude Code's /api/oauth/usage endpoint (same as the /usage slash command)
# and displays subscription usage % in the Windows system tray.
#
# Reads ~/.claude/.credentials.json - same credentials file the Linux Cinnamon
# applet uses. No API key required, no token-cost estimates; pure subscription %.

#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== Constants =====
$script:AppName       = 'AI Usage Node'
$script:AppDir        = Join-Path $env:LOCALAPPDATA 'AIUsageNode'
$script:SettingsPath  = Join-Path $script:AppDir 'settings.json'
$script:RateStatePath = Join-Path $script:AppDir 'rate-state.json'
$script:CredsPath     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:Endpoint      = 'https://api.anthropic.com/api/oauth/usage'
$script:UserAgent     = 'claude-quota-applet-windows/1.0'

# ===== State =====
$script:LastData         = $null
$script:LastError        = $null
$script:LastFetchAt      = $null
$script:CooldownUntil    = $null
$script:CooldownSecs     = 0     # last cooldown duration (for display / next-backoff calc)
$script:Consecutive429s  = 0     # for exponential backoff
$script:InFlight         = $false
$script:LastRetryAt      = $null # last error-recovery retry attempt
$script:LastBalloonStatus = $null # last status we balloon-notified about (suppress repeats)

# ===== Settings =====
$script:DefaultSettings = [ordered]@{
    'auto-refresh'           = $false
    'refresh-seconds'        = 600
    'click-debounce-seconds' = 5
    'show-panel-label'       = $true
    'label-format'           = '5h_and_7d'  # 5h_and_7d | 5h_only | 7d_only | max
    'warn-threshold'         = 75
    'alert-threshold'        = 90
    'terminal-command'       = 'wt.exe pwsh -NoExit -Command claude'
}

function Load-Settings {
    if (-not (Test-Path $script:AppDir)) {
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    }
    $settings = [ordered]@{}
    foreach ($k in $script:DefaultSettings.Keys) { $settings[$k] = $script:DefaultSettings[$k] }
    if (Test-Path $script:SettingsPath) {
        try {
            $existing = Get-Content $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) {
                if ($settings.Contains($p.Name)) { $settings[$p.Name] = $p.Value }
            }
        } catch {
            # ignore parse errors, fall through to defaults
        }
    } else {
        Save-Settings $settings
    }
    return $settings
}

function Save-Settings($settings) {
    $settings | ConvertTo-Json -Depth 5 | Set-Content $script:SettingsPath -Encoding UTF8
}

$script:Settings = Load-Settings

# ===== Rate-limit state persistence =====
# Backoff state survives process restarts; otherwise restarting the tray
# while still rate-limited would reset the counter back to a 2-min cooldown
# even though the server is asking for much longer.
function Load-RateState {
    if (-not (Test-Path $script:RateStatePath)) { return }
    try {
        $j = Get-Content $script:RateStatePath -Raw | ConvertFrom-Json
        if ($j.consecutive429s) { $script:Consecutive429s = [int]$j.consecutive429s }
        if ($j.cooldownUntilUtc) {
            $u = [DateTime]::Parse($j.cooldownUntilUtc, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            if ($u -gt [DateTime]::UtcNow) {
                $script:CooldownUntil = $u
                $script:CooldownSecs  = [int]($u - [DateTime]::UtcNow).TotalSeconds
                $script:LastError     = @{ title='Rate limited (carried)'; detail='Cooling down (state restored from disk).' }
            }
        }
        # Forget very old state so we don't carry yesterday's backoff forever.
        if ($j.lastFailureAtUtc) {
            $last = [DateTime]::Parse($j.lastFailureAtUtc, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            if (([DateTime]::UtcNow - $last).TotalHours -gt 6) {
                $script:Consecutive429s = 0
                $script:CooldownUntil   = $null
            }
        }
    } catch {}
}

function Save-RateState {
    try {
        $state = [PSCustomObject]@{
            consecutive429s   = $script:Consecutive429s
            cooldownUntilUtc  = if ($script:CooldownUntil) { $script:CooldownUntil.ToString('o') } else { $null }
            lastFailureAtUtc  = [DateTime]::UtcNow.ToString('o')
        }
        $state | ConvertTo-Json | Set-Content $script:RateStatePath -Encoding UTF8
    } catch {}
}

function Clear-RateState {
    $script:Consecutive429s = 0
    $script:CooldownUntil   = $null
    $script:CooldownSecs    = 0
    if (Test-Path $script:RateStatePath) { Remove-Item $script:RateStatePath -Force -ErrorAction SilentlyContinue }
}

Load-RateState

# ===== Credential read =====
function Get-OAuthToken {
    if (-not (Test-Path $script:CredsPath)) { return $null }
    try {
        $j = Get-Content $script:CredsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.claudeAiOauth -and $j.claudeAiOauth.accessToken) {
            return $j.claudeAiOauth.accessToken
        }
    } catch { return $null }
    return $null
}

# ===== Helpers =====
function Format-Countdown($iso) {
    if (-not $iso) { return '-' }
    try {
        $d = [DateTimeOffset]::Parse($iso)
        $totalS = [int](($d.UtcDateTime - [DateTime]::UtcNow).TotalSeconds)
        if ($totalS -le 0) { return 'any moment' }
        if ($totalS -lt 3600) { return ("{0}m" -f [int]($totalS / 60)) }
        if ($totalS -lt 86400) {
            $h = [int]($totalS / 3600); $m = [int](($totalS % 3600) / 60)
            return ("{0}h {1}m" -f $h, $m)
        }
        $d2 = [int]($totalS / 86400); $h = [int](($totalS % 86400) / 3600)
        return ("{0}d {1}h" -f $d2, $h)
    } catch { return '-' }
}

function Format-AbsoluteReset($iso) {
    if (-not $iso) { return '' }
    try {
        $d = [DateTimeOffset]::Parse($iso).LocalDateTime
        $now = [DateTime]::Now
        $sameDay   = ($d.Date -eq $now.Date)
        $isTomorrow = ($d.Date -eq $now.Date.AddDays(1))
        $time = $d.ToString('h:mm tt')
        if ($sameDay)   { return "today at $time" }
        if ($isTomorrow) { return "tomorrow at $time" }
        return ($d.ToString('ddd MMM d') + " at $time")
    } catch { return '' }
}

function Get-Utilization($info) {
    if (-not $info) { return $null }
    $u = $info.utilization
    if ($null -eq $u) { return $null }
    try { return [double]$u } catch { return $null }
}

function Get-StatusColor($util) {
    if ($null -eq $util) { return [System.Drawing.Color]::FromArgb(136,136,136) }
    if ($util -ge 90)    { return [System.Drawing.Color]::FromArgb(255, 82, 82) }
    if ($util -ge 75)    { return [System.Drawing.Color]::FromArgb(255,167, 38) }
    if ($util -ge 50)    { return [System.Drawing.Color]::FromArgb(255,213, 79) }
    return [System.Drawing.Color]::FromArgb(126,217, 87)
}

# ===== Icon generation =====
$script:IconCache = @{}
function New-StatusIcon([System.Drawing.Color]$color) {
    $key = "$($color.R)_$($color.G)_$($color.B)"
    if ($script:IconCache.ContainsKey($key)) { return $script:IconCache[$key] }

    $size = 32
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush $color
    # 4-pointed sparkle (concave star)
    $c = $size / 2
    $outer = 14.0
    $inner = 4.5
    $points = @(
        [System.Drawing.PointF]::new([float]$c, [float]($c - $outer))
        [System.Drawing.PointF]::new([float]($c + $inner), [float]($c - $inner))
        [System.Drawing.PointF]::new([float]($c + $outer), [float]$c)
        [System.Drawing.PointF]::new([float]($c + $inner), [float]($c + $inner))
        [System.Drawing.PointF]::new([float]$c, [float]($c + $outer))
        [System.Drawing.PointF]::new([float]($c - $inner), [float]($c + $inner))
        [System.Drawing.PointF]::new([float]($c - $outer), [float]$c)
        [System.Drawing.PointF]::new([float]($c - $inner), [float]($c - $inner))
    )
    $g.FillPolygon($brush, $points)
    $brush.Dispose()
    $g.Dispose()

    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon)
    $script:IconCache[$key] = $icon
    return $icon
}

# ===== API fetch =====
# Uses System.Net.Http.HttpClient directly. This gives us a single response
# type (HttpResponseMessage) regardless of PowerShell version, so header and
# body reading work identically on Windows PowerShell 5.1 and PowerShell 7+.
# Critically, this is what lets us actually read the Retry-After header --
# the previous Invoke-WebRequest path silently lost headers when the response
# came back via HttpResponseException on PS7.

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Invoke-UsageFetch {
    # Returns @{ ok=$true; data=... } or @{ ok=$false; status=N; title=...; detail=... }
    if ($script:CooldownUntil -and ([DateTime]::UtcNow -lt $script:CooldownUntil)) {
        return @{ ok = $false; title = 'Cooling down'; detail = 'Rate-limit cooldown active.' }
    }
    if ($script:InFlight) {
        return @{ ok = $false; title = 'Busy'; detail = 'Previous fetch still in flight.' }
    }
    $token = Get-OAuthToken
    if (-not $token) {
        return @{ ok = $false; title = 'No Claude credentials'; detail = 'Run `claude` once in a terminal to log in.' }
    }

    $script:InFlight = $true
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(10)
        $req = New-Object System.Net.Http.HttpRequestMessage 'GET', $script:Endpoint
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue 'Bearer', $token
        $null = $req.Headers.UserAgent.TryParseAdd($script:UserAgent)

        try {
            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        } catch {
            return @{ ok = $false; title = 'Network error'; detail = $_.Exception.Message }
        }

        $code = [int]$resp.StatusCode
        $body = ''
        try { $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { $body = '' }

        # Collect every response header (and content header) for visibility.
        $headerDump = [ordered]@{}
        foreach ($pair in $resp.Headers) {
            $headerDump[$pair.Key] = ($pair.Value -join ', ')
        }
        if ($resp.Content -and $resp.Content.Headers) {
            foreach ($pair in $resp.Content.Headers) {
                $headerDump["content.$($pair.Key)"] = ($pair.Value -join ', ')
            }
        }

        if ($code -eq 429) {
            $serverWait = 0
            $serverWaitSource = 'none'
            $rawRetryAfter = $headerDump['Retry-After']

            # Path 1: strongly-typed property. Works on most PS versions but
            # PowerShell's binding of .NET nullable<T> properties has caused
            # silent zero-reads in the wild, so it's only the first attempt.
            try {
                $ra = $resp.Headers.RetryAfter
                if ($ra) {
                    $delta = $ra.Delta
                    if ($delta -and $delta.TotalSeconds -gt 0) {
                        $serverWait = [int]$delta.TotalSeconds
                        $serverWaitSource = 'Delta'
                    } else {
                        $date = $ra.Date
                        if ($date) {
                            $serverWait = [int]($date - [DateTimeOffset]::UtcNow).TotalSeconds
                            if ($serverWait -lt 0) { $serverWait = 0 }
                            $serverWaitSource = 'Date'
                        }
                    }
                }
            } catch {}

            # Path 2: fall back to manually parsing the raw header string we
            # already pulled into the dump. This is what saves us when the
            # typed accessor silently returns null.
            if ($serverWait -le 0 -and $rawRetryAfter) {
                $secInt = 0
                if ([int]::TryParse($rawRetryAfter, [ref]$secInt)) {
                    if ($secInt -gt 0) {
                        $serverWait = $secInt
                        $serverWaitSource = 'raw-seconds'
                    }
                } else {
                    try {
                        $until = [DateTimeOffset]::Parse($rawRetryAfter)
                        $diff = [int]($until - [DateTimeOffset]::UtcNow).TotalSeconds
                        if ($diff -gt 0) {
                            $serverWait = $diff
                            $serverWaitSource = 'raw-http-date'
                        }
                    } catch {}
                }
            }

            $script:Consecutive429s = $script:Consecutive429s + 1

            # STRICTLY honor the server. If Retry-After is present, use exactly
            # that. Only fall back to our own backoff when the server gives us
            # nothing to go on.
            if ($serverWait -gt 0) {
                $waitSec    = $serverWait
                $waitSource = "server Retry-After"
            } else {
                $waitSec    = [int]([Math]::Min(1800, [Math]::Pow(2, [Math]::Min($script:Consecutive429s, 8)) * 60))
                $waitSource = "local default (no Retry-After)"
            }

            $script:CooldownUntil = [DateTime]::UtcNow.AddSeconds($waitSec)
            $script:CooldownSecs  = $waitSec
            Save-RateState

            # Dump full 429 to disk for debugging and so the user can verify
            # we're honoring what the server actually sent.
            try {
                $dump = [PSCustomObject]@{
                    timestampUtc      = [DateTime]::UtcNow.ToString('o')
                    status            = $code
                    rawRetryAfter     = $rawRetryAfter
                    serverWaitSeconds = $serverWait
                    serverWaitSource  = $serverWaitSource
                    waitSecondsUsed   = $waitSec
                    waitSource        = $waitSource
                    consecutive429s   = $script:Consecutive429s
                    cooldownUntilUtc  = $script:CooldownUntil.ToString('o')
                    headers           = $headerDump
                    body              = $body
                }
                $dump | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:AppDir 'last-429.json') -Encoding UTF8
            } catch {}

            $note = "${waitSec}s ($waitSource)"
            if ($script:Consecutive429s -gt 1) { $note += "; #$($script:Consecutive429s) in a row" }
            return @{ ok = $false; status = 429; title = 'Rate limited (429)'; detail = $note }
        }

        if ($code -eq 401 -or $code -eq 403) {
            return @{ ok = $false; status = $code; title = "Auth expired ($code)"; detail = 'Run `claude` in a terminal to refresh your token.' }
        }
        if ($code -lt 200 -or $code -ge 300) {
            $snippet = if ($body) { $body.Substring(0, [Math]::Min(120, $body.Length)) } else { '' }
            return @{ ok = $false; status = $code; title = "HTTP $code"; detail = $snippet }
        }
        if (-not $body -or -not $body.Trim()) {
            return @{ ok = $false; title = 'API: empty response'; detail = '' }
        }
        try {
            $data = $body | ConvertFrom-Json
        } catch {
            return @{ ok = $false; title = 'Parse error'; detail = $_.Exception.Message }
        }
        if ($data.error -or $data.type -eq 'error') {
            $msg = ''
            if ($data.error -and $data.error.message) { $msg = $data.error.message }
            elseif ($data.message)                    { $msg = $data.message }
            elseif ($data.type)                       { $msg = $data.type }
            $msgStr = "$msg"
            return @{ ok = $false; title = 'API error'; detail = $msgStr.Substring(0, [Math]::Min(120, $msgStr.Length)) }
        }
        $script:LastData         = $data
        $script:LastError        = $null
        $script:LastFetchAt      = [DateTime]::UtcNow
        Clear-RateState          # reset backoff counter and on-disk state
        return @{ ok = $true; data = $data }
    }
    finally {
        $script:InFlight = $false
        if ($client) { $client.Dispose() }
    }
}

# ===== Render =====
function Get-LabelPercent {
    $data = $script:LastData
    if (-not $data) { return '?' }
    $fiveH       = Get-Utilization $data.five_hour
    $sevenD      = Get-Utilization $data.seven_day
    $sevenOpus   = Get-Utilization $data.seven_day_opus
    $sevenSonnet = Get-Utilization $data.seven_day_sonnet

    $fmt = $script:Settings['label-format']
    switch ($fmt) {
        '5h_only' {
            if ($null -eq $fiveH) { return '?' }
            return ("{0}%" -f [int][Math]::Round($fiveH))
        }
        '7d_only' {
            if ($null -eq $sevenD) { return '?' }
            return ("{0}%" -f [int][Math]::Round($sevenD))
        }
        'max' {
            $vals = @($fiveH, $sevenD, $sevenOpus, $sevenSonnet) | Where-Object { $null -ne $_ }
            if ($vals.Count -eq 0) { return '?' }
            return ("{0}%" -f [int][Math]::Round(($vals | Measure-Object -Maximum).Maximum))
        }
        default {
            $a = if ($null -ne $fiveH)  { [int][Math]::Round($fiveH) }  else { '?' }
            $b = if ($null -ne $sevenD) { [int][Math]::Round($sevenD) } else { '?' }
            return "$a/$b%"
        }
    }
}

function Format-CooldownRemaining {
    if (-not $script:CooldownUntil) { return $null }
    $rem = $script:CooldownUntil - [DateTime]::UtcNow
    if ($rem.TotalSeconds -le 0) { return $null }
    $until = $script:CooldownUntil.ToLocalTime().ToString('h:mm tt')
    if ($rem.TotalSeconds -lt 60) {
        return ("Cooling {0}s, until {1}" -f [int]$rem.TotalSeconds, $until)
    }
    if ($rem.TotalSeconds -lt 3600) {
        $m = [int][Math]::Floor($rem.TotalMinutes)
        $s = [int]($rem.TotalSeconds - $m * 60)
        return ("Cooling {0}m {1}s, until {2}" -f $m, $s, $until)
    }
    $h = [int][Math]::Floor($rem.TotalHours)
    $m = [int]($rem.TotalMinutes - $h * 60)
    return ("Cooling {0}h {1}m, until {2}" -f $h, $m, $until)
}

function Build-Tooltip($errorTitle, $errorDetail) {
    $data = $script:LastData
    $lines = New-Object System.Collections.Generic.List[string]
    $label = Get-LabelPercent
    $lines.Add("$script:AppName  $label")
    if ($data) {
        foreach ($pair in @(
            @{ name='5-hour';    info=$data.five_hour }
            @{ name='7-day';     info=$data.seven_day }
            @{ name='Opus 7d';   info=$data.seven_day_opus }
            @{ name='Sonnet 7d'; info=$data.seven_day_sonnet }
        )) {
            $info = $pair.info
            if (-not $info) { continue }
            $u = Get-Utilization $info
            if ($null -eq $u) { continue }
            $pct = [int][Math]::Round($u)
            $cd  = Format-Countdown $info.resets_at
            $lines.Add(("  {0}: {1}% (in {2})" -f $pair.name, $pct, $cd))
        }
        if ($data.extra_usage -and $data.extra_usage.is_enabled) {
            $used  = [double]$data.extra_usage.used_credits
            $limit = [double]$data.extra_usage.monthly_limit
            $cur   = $data.extra_usage.currency
            $lines.Add(("  Extra: {0:F2}/{1:F2} {2}" -f $used, $limit, $cur))
        }
    }
    if ($errorTitle) {
        $lines.Add('')
        $lines.Add("(!) $errorTitle")
        $cd = Format-CooldownRemaining
        if ($cd) { $lines.Add($cd) }
        if ($errorDetail) { $lines.Add($errorDetail) }
        if ($script:Consecutive429s -gt 0) { $lines.Add("Consecutive 429s: $($script:Consecutive429s)") }
    } else {
        $cd = Format-CooldownRemaining
        if ($cd) { $lines.Add($cd) }
    }
    return ($lines.ToArray() -join "`n")
}

function Update-Tray($notifyIcon) {
    $data = $script:LastData
    $maxUtil = 0.0
    if ($data) {
        foreach ($k in 'five_hour','seven_day','seven_day_opus','seven_day_sonnet') {
            $u = Get-Utilization $data.$k
            if ($null -ne $u -and $u -gt $maxUtil) { $maxUtil = $u }
        }
    }
    $warn  = [int]$script:Settings['warn-threshold']
    $alert = [int]$script:Settings['alert-threshold']
    if ($maxUtil -ge $alert)     { $color = [System.Drawing.Color]::FromArgb(255, 82, 82) }
    elseif ($maxUtil -ge $warn)  { $color = [System.Drawing.Color]::FromArgb(255,167, 38) }
    elseif ($data)               { $color = [System.Drawing.Color]::FromArgb(126,217, 87) }
    else                         { $color = [System.Drawing.Color]::FromArgb(136,136,136) }

    if ($script:LastError) { $color = [System.Drawing.Color]::FromArgb(255, 82, 82) }
    $notifyIcon.Icon = New-StatusIcon $color

    $errorTitle  = if ($script:LastError) { $script:LastError.title }  else { $null }
    $errorDetail = if ($script:LastError) { $script:LastError.detail } else { $null }
    $tt = Build-Tooltip $errorTitle $errorDetail
    # NotifyIcon.Text max is 127 chars on older Windows; truncate safely.
    if ($tt.Length -gt 127) { $tt = $tt.Substring(0, 124) + '...' }
    $notifyIcon.Text = $tt
}

# ===== Actions =====
function Invoke-Refresh($notifyIcon) {
    $result = Invoke-UsageFetch
    if (-not $result.ok) {
        $script:LastError = @{ title = $result.title; detail = $result.detail }
        # Balloon only on a NEW error type (suppress repeats of the same status).
        # The icon color + tooltip already convey the error state; we don't want
        # the OS popping toast every retry while we're stuck in a rate-limit loop.
        if ($result.status -in 401,403,429 -and $script:LastBalloonStatus -ne $result.status) {
            $notifyIcon.BalloonTipTitle = $result.title
            $notifyIcon.BalloonTipText  = $result.detail
            $notifyIcon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
            $notifyIcon.ShowBalloonTip(5000)
            $script:LastBalloonStatus = $result.status
        }
    } else {
        # Successful fetch clears the balloon-suppression latch so a future
        # error WILL produce a fresh notification.
        $script:LastBalloonStatus = $null
    }
    Update-Tray $notifyIcon
}

function Open-ClaudeTerminal {
    $cmd = $script:Settings['terminal-command']
    if (-not $cmd) { $cmd = 'wt.exe pwsh -NoExit -Command claude' }
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '', $cmd) -WindowStyle Hidden -ErrorAction Stop
    } catch {
        try {
            $parts = $cmd -split ' ', 2
            if ($parts.Count -eq 2) {
                Start-Process -FilePath $parts[0] -ArgumentList $parts[1] -ErrorAction Stop
            } else {
                Start-Process -FilePath $parts[0] -ErrorAction Stop
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to launch terminal: $($_.Exception.Message)`n`nConfigured: $cmd", $script:AppName) | Out-Null
        }
    }
}

function Open-SettingsFile {
    Start-Process notepad.exe -ArgumentList $script:SettingsPath
}

# ===== Popup window (left-click) =====
$script:PopupForm = $null

function Show-UsagePopup {
    if ($script:PopupForm -and -not $script:PopupForm.IsDisposed) {
        # Toggle: already open -> close it
        $script:PopupForm.Close()
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.Text            = 'Claude Usage'
    $form.Width           = 380
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.KeyPreview      = $true

    $y = 12

    # Header
    $header = New-Object System.Windows.Forms.Label
    $header.Text     = 'Claude Usage'
    $header.Font     = New-Object System.Drawing.Font 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold)
    $header.Location = New-Object System.Drawing.Point 14, $y
    $header.Size     = New-Object System.Drawing.Size 350, 26
    $header.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($header)
    $y += 30

    # Status line (one or two lines depending on whether a cooldown is active)
    $status = New-Object System.Windows.Forms.Label
    if ($script:LastError) {
        $status.Text = "(!) $($script:LastError.title)"
        $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    } elseif ($script:LastFetchAt) {
        $ageSec = [int]([DateTime]::UtcNow - $script:LastFetchAt).TotalSeconds
        if ($ageSec -lt 5)        { $ageText = 'just now' }
        elseif ($ageSec -lt 60)   { $ageText = "$ageSec s ago" }
        elseif ($ageSec -lt 3600) { $ageText = "$([int]($ageSec / 60)) min ago" }
        else                       { $ageText = "$([int]($ageSec / 3600)) h ago" }
        $mode = if ($script:Settings['auto-refresh']) { "auto every $([int]($script:Settings['refresh-seconds'] / 60)) min" } else { 'click icon to refresh' }
        $status.Text = "Updated $ageText  -  $mode"
        $status.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
    } else {
        $status.Text = 'Loading...'
        $status.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
    }
    $status.Font      = New-Object System.Drawing.Font 'Segoe UI', 8
    $status.Location  = New-Object System.Drawing.Point 14, $y
    $status.Size      = New-Object System.Drawing.Size 350, 16
    $status.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($status)
    $y += 20

    # Live cooldown line (only shown while CooldownUntil is in the future).
    # A 1-second timer scoped to this form updates the text in place.
    $cooldownLabel = New-Object System.Windows.Forms.Label
    $cooldownLabel.Font      = New-Object System.Drawing.Font 'Segoe UI', 8, ([System.Drawing.FontStyle]::Bold)
    $cooldownLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 167, 38)
    $cooldownLabel.Location  = New-Object System.Drawing.Point 14, $y
    $cooldownLabel.Size      = New-Object System.Drawing.Size 350, 16
    $cooldownLabel.BackColor = [System.Drawing.Color]::Transparent
    $cooldownText = Format-CooldownRemaining
    if ($cooldownText) { $cooldownLabel.Text = $cooldownText; $cooldownLabel.Visible = $true; $y += 18 }
    else               { $cooldownLabel.Visible = $false }
    $form.Controls.Add($cooldownLabel)

    # Detail line for the error message (also visible while cooling down).
    if ($script:LastError -and $script:LastError.detail) {
        $detail = New-Object System.Windows.Forms.Label
        $detail.Text      = $script:LastError.detail
        $detail.Font      = New-Object System.Drawing.Font 'Segoe UI', 8
        $detail.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
        $detail.Location  = New-Object System.Drawing.Point 14, $y
        $detail.Size      = New-Object System.Drawing.Size 350, 16
        $detail.BackColor = [System.Drawing.Color]::Transparent
        $form.Controls.Add($detail)
        $y += 18
    }
    $y += 4

    # Bars
    $data = $script:LastData
    if ($data) {
        foreach ($pair in @(
            @{ name='5-hour window';   info=$data.five_hour }
            @{ name='7-day all models'; info=$data.seven_day }
            @{ name='7-day Opus';      info=$data.seven_day_opus }
            @{ name='7-day Sonnet';    info=$data.seven_day_sonnet }
        )) {
            $info = $pair.info
            if (-not $info) { continue }
            $u = Get-Utilization $info
            if ($null -eq $u) { continue }

            $nameLabel = New-Object System.Windows.Forms.Label
            $nameLabel.Text     = $pair.name
            $nameLabel.Font     = New-Object System.Drawing.Font 'Segoe UI', 10
            $nameLabel.Location = New-Object System.Drawing.Point 14, $y
            $nameLabel.Size     = New-Object System.Drawing.Size 280, 18
            $nameLabel.BackColor = [System.Drawing.Color]::Transparent
            $form.Controls.Add($nameLabel)

            $pctLabel = New-Object System.Windows.Forms.Label
            $pctLabel.Text     = "$([int][Math]::Round($u))%"
            $pctLabel.Font     = New-Object System.Drawing.Font 'Segoe UI', 10, ([System.Drawing.FontStyle]::Bold)
            $pctLabel.ForeColor = Get-StatusColor $u
            $pctLabel.Location = New-Object System.Drawing.Point 300, $y
            $pctLabel.Size     = New-Object System.Drawing.Size 60, 18
            $pctLabel.TextAlign = [System.Drawing.ContentAlignment]::TopRight
            $pctLabel.BackColor = [System.Drawing.Color]::Transparent
            $form.Controls.Add($pctLabel)
            $y += 20

            $barBg = New-Object System.Windows.Forms.Panel
            $barBg.Location  = New-Object System.Drawing.Point 14, $y
            $barBg.Size      = New-Object System.Drawing.Size 346, 6
            $barBg.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
            $form.Controls.Add($barBg)

            $fillW = [int][Math]::Max(0, [Math]::Min(346, [Math]::Round(346 * $u / 100)))
            if ($fillW -gt 0) {
                $barFill = New-Object System.Windows.Forms.Panel
                $barFill.Location  = New-Object System.Drawing.Point 14, $y
                $barFill.Size      = New-Object System.Drawing.Size $fillW, 6
                $barFill.BackColor = Get-StatusColor $u
                $form.Controls.Add($barFill)
                $barFill.BringToFront()
            }
            $y += 10

            $resetLabel = New-Object System.Windows.Forms.Label
            $abs = Format-AbsoluteReset $info.resets_at
            $cd  = Format-Countdown    $info.resets_at
            $resetLabel.Text = if ($abs) { "Resets $abs  -  in $cd" } else { "Resets in $cd" }
            $resetLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 8
            $resetLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
            $resetLabel.Location = New-Object System.Drawing.Point 14, $y
            $resetLabel.Size     = New-Object System.Drawing.Size 346, 14
            $resetLabel.BackColor = [System.Drawing.Color]::Transparent
            $form.Controls.Add($resetLabel)
            $y += 22
        }
        if ($data.extra_usage -and $data.extra_usage.is_enabled) {
            $extraLabel = New-Object System.Windows.Forms.Label
            $used  = [double]$data.extra_usage.used_credits
            $limit = [double]$data.extra_usage.monthly_limit
            $cur   = $data.extra_usage.currency
            $extraLabel.Text = ("Extra credits: {0:F2} / {1:F2} {2}" -f $used, $limit, $cur)
            $extraLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 9
            $extraLabel.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
            $extraLabel.Location = New-Object System.Drawing.Point 14, $y
            $extraLabel.Size     = New-Object System.Drawing.Size 346, 18
            $extraLabel.BackColor = [System.Drawing.Color]::Transparent
            $form.Controls.Add($extraLabel)
            $y += 24
        }
    } elseif ($script:LastError) {
        $errLabel = New-Object System.Windows.Forms.Label
        $errLabel.Text = $script:LastError.detail
        $errLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 9
        $errLabel.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $errLabel.Location = New-Object System.Drawing.Point 14, $y
        $errLabel.Size     = New-Object System.Drawing.Size 346, 60
        $errLabel.BackColor = [System.Drawing.Color]::Transparent
        $form.Controls.Add($errLabel)
        $y += 70
    }

    $y += 6
    $form.Height = $y + 38

    # Position bottom-right of working area
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point ($screen.Right - $form.Width - 12), ($screen.Bottom - $form.Height - 12)

    # 1-second timer for live cooldown countdown inside the popup.
    $cdTimer = New-Object System.Windows.Forms.Timer
    $cdTimer.Interval = 1000
    $cdTimer.Add_Tick({
        try {
            $txt = Format-CooldownRemaining
            if ($txt) { $cooldownLabel.Text = $txt; $cooldownLabel.Visible = $true }
            else      { $cooldownLabel.Visible = $false }
        } catch {}
    }.GetNewClosure())
    $cdTimer.Start()

    # Close on deactivate or Escape. Always stop and dispose the timer.
    $form.Add_Deactivate({ try { $this.Close() } catch {} })
    $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
    $form.Add_FormClosed({
        try { $cdTimer.Stop(); $cdTimer.Dispose() } catch {}
        $script:PopupForm = $null
    }.GetNewClosure())

    $script:PopupForm = $form
    $form.Show()
    $form.Activate()
}

# ===== Main =====
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon    = New-StatusIcon ([System.Drawing.Color]::FromArgb(136,136,136))
$notifyIcon.Text    = "$script:AppName - loading..."
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('Refresh now', $null, { Invoke-Refresh $notifyIcon })
$null = $menu.Items.Add('Open Claude in terminal', $null, { Open-ClaudeTerminal })
$null = $menu.Items.Add('Edit settings', $null, { Open-SettingsFile })
$null = $menu.Items.Add('Reload settings', $null, { $script:Settings = Load-Settings; Update-Tray $notifyIcon })
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('Exit', $null, {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$notifyIcon.ContextMenuStrip = $menu

# Left single-click: open the popup window with bars + reset times.
# Left double-click: same popup, plus trigger a refresh if data is stale.
$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    Show-UsagePopup
})
$notifyIcon.Add_MouseDoubleClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $debounce = [int]$script:Settings['click-debounce-seconds']
    if ($script:LastFetchAt -and ([DateTime]::UtcNow - $script:LastFetchAt).TotalSeconds -ge $debounce) {
        Invoke-Refresh $notifyIcon
        # Popup may already be open from MouseClick — refresh its contents
        if ($script:PopupForm -and -not $script:PopupForm.IsDisposed) {
            $script:PopupForm.Close()
            Show-UsagePopup
        }
    }
})

# Background timer (ticks every 30s).
#  1. Always: auto-recover from a previous error once the cooldown has passed.
#     This runs regardless of the auto-refresh setting, so a transient 429
#     doesn't leave the tray stuck red until the user manually clicks.
#  2. Opt-in: auto-refresh on the user's interval, when 'auto-refresh' is on.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30 * 1000
$timer.Add_Tick({
    # Refresh the tooltip so the cooldown countdown ticks down live, even
    # though no fetch ever happens from this timer.
    Update-Tray $notifyIcon

    # Auto-retry on error is intentionally NOT done here. Background retries
    # were the root cause of an extended rate-limit incident: each retry
    # against /api/oauth/usage got a fresh 47-min Retry-After, and a buggy
    # parse fell back to a shorter local cooldown, so the script kept
    # hammering and the rate-limit window kept resetting. The tray is now
    # manual-only -- only an explicit click or a context-menu "Refresh now"
    # makes an HTTP call.
    if (-not $script:Settings['auto-refresh']) { return }
    $every = [int]$script:Settings['refresh-seconds']
    if ($every -lt 60) { $every = 60 }
    if ($script:LastFetchAt -and ([DateTime]::UtcNow - $script:LastFetchAt).TotalSeconds -lt $every) { return }
    Invoke-Refresh $notifyIcon
})
$timer.Start()

# Initial fetch
Invoke-Refresh $notifyIcon

# Run message loop. Returns when Application.Exit() is called.
[System.Windows.Forms.Application]::Run()
