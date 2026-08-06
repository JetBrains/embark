<#
.SYNOPSIS
  Benchmarks the interactive Claude Code TUI on a single query with vs. without JetBrains
  Context, measuring the WARM steady-state (what a real ongoing session pays), using Claude
  Code's OFFICIAL cost -- no manual price tables.

.DESCRIPTION
  - Prompts for the query at runtime (or pass -Prompt).
  - Keeps prompt caching ENABLED (unsets DISABLE_PROMPT_CACHING); pins the auto-updater; 5-min TTL.
  - Each leg runs TWO interactive TUI sessions sharing one unique marker:
      1) WARM-UP  : you type  hi  and /exit -- writes the TUI tools+system prefix into cache.
      2) MEASURED : you paste the query (one turn) and /exit -- reads that prefix warm.
    Because the measured session is separate and single-turn, its OFFICIAL cost is the warm
    query cost (the warm-up's cold prefix write is a different session, excluded).
  - Reads OFFICIAL metrics from ~/.claude.json (lastCost / lastDuration / lastAPIDuration) for
    the session created by the measured run, detected as the one whose lastSessionId is new
    since a pre-run snapshot (NOT matched by cwd -- Claude Code keys the project entry by the
    git-repo root). WarmRead = cache_read on that session's FIRST call (from the transcript);
    >0 confirms the warm-up populated the cache.
  - Restores the original cache environment in a finally block.
#>

[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$Model = "claude-opus-4-8"
)

$ErrorActionPreference = "Stop"

# --- Environment we will toggle. Capture originals so we can restore them. -----------------
$cacheVars = @{
    "DISABLE_PROMPT_CACHING"   = $null   # keep caching ON ($null => remove if set in env)
    "DISABLE_AUTOUPDATER"      = "1"     # pin the binary across runs
    "ENABLE_PROMPT_CACHING_1H" = $null   # 5-min TTL (warm-up + measured run back-to-back)
}

$original = @{}
foreach ($name in $cacheVars.Keys) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$ClaudeExe    = (Get-Command claude -ErrorAction Stop).Source
$ClaudeConfig = Join-Path $env:USERPROFILE ".claude.json"
$WorkingDir   = (Get-Location).Path

function Set-Env([string]$name, $value) {
    if ($null -eq $value) {
        Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue
    } else {
        Set-Item -Path "Env:\$name" -Value $value
    }
}

function Format-Ms([double]$ms) {
    $ts = [timespan]::FromMilliseconds($ms)
    if ($ts.TotalHours -ge 1) { return ("{0:00}:{1:00}:{2:00}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ("{0:00}:{1:00}" -f [int]$ts.TotalMinutes, $ts.Seconds)
}

# Wait for a single keypress so the user can read the step before the TUI takes the console.
function Wait-Key([string]$msg) {
    Write-Host $msg -ForegroundColor DarkCyan -NoNewline
    try { [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { [void](Read-Host) }
    Write-Host ""
}

function Get-Val($dict, $key) {
    # Iterate .Keys (works on every IDictionary) rather than call .Contains/.ContainsKey, whose
    # availability differs by backing type: generic Dictionary<string,object> (5.1
    # JavaScriptSerializer) exposes ContainsKey but not a public 1-arg Contains; OrderedDictionary
    # (7+ -AsHashtable) exposes Contains but not ContainsKey. Indexing with the actual key object
    # avoids KeyNotFound on the case-sensitive generic dictionary.
    if ($dict -is [System.Collections.IDictionary]) {
        foreach ($k in $dict.Keys) {
            if ($k -eq $key) { return $dict[$k] }
        }
    }
    return $null
}

# Parse ~/.claude.json and return the 'projects' dictionary. Keys like C:/x and c:/x differ
# only by case, which plain ConvertFrom-Json rejects -- so on PowerShell 7+ we use
# -AsHashtable (tolerates them), and on Windows PowerShell 5.1 (no -AsHashtable) we fall back
# to the .NET Framework JavaScriptSerializer.
function Read-ClaudeProjects {
    if (-not (Test-Path $ClaudeConfig)) { return $null }
    $text = Get-Content -Raw -LiteralPath $ClaudeConfig
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try {
            $obj = $text | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Failed to parse $ClaudeConfig : $($_.Exception.Message)"
            return $null
        }
        return (Get-Val $obj 'projects')
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $obj = $ser.DeserializeObject($text)
    } catch {
        Write-Warning "Failed to parse $ClaudeConfig : $($_.Exception.Message)"
        return $null
    }
    return (Get-Val $obj 'projects')
}

# Set of every lastSessionId currently recorded across all projects.
function Get-Snapshot {
    $projects = Read-ClaudeProjects
    $set = [System.Collections.Generic.HashSet[string]]::new()
    if ($projects) {
        foreach ($v in $projects.Values) {
            $s = Get-Val $v 'lastSessionId'
            if ($s) { [void]$set.Add([string]$s) }
        }
    }
    return $set
}

# Locate the main transcript for a session id (skip subagent transcripts).
function Get-TranscriptPath([string]$sid) {
    if ([string]::IsNullOrWhiteSpace($sid)) { return $null }
    $base = Join-Path $env:USERPROFILE ".claude\projects"
    if (-not (Test-Path $base)) { return $null }
    $f = Get-ChildItem -Path $base -Recurse -Filter "$sid.jsonl" -File -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '[\\/]subagents[\\/]' } | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# cache_read_input_tokens on the FIRST assistant call of a session (0 = cold, >0 = warm).
function Get-FirstCallRead([string]$sid) {
    $path = Get-TranscriptPath $sid
    if (-not $path) { return $null }
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant') { continue }
        $u = $o.message.usage
        if ($null -ne $u -and ($null -ne $u.cache_read_input_tokens)) { return [long]$u.cache_read_input_tokens }
    }
    return $null
}

# Official metrics for the newest session whose id is new since $preSids, or $null (retry).
function Get-Result($preSids) {
    $projects = Read-ClaudeProjects
    if (-not $projects) { return $null }
    $cands = @()
    foreach ($v in $projects.Values) {
        $s = [string](Get-Val $v 'lastSessionId')
        if ($s -and (-not $preSids.Contains($s)) -and ($null -ne (Get-Val $v 'lastCost'))) {
            $mt = 0L; $tp = Get-TranscriptPath $s
            if ($tp) { try { $mt = (Get-Item $tp).LastWriteTimeUtc.ToFileTimeUtc() } catch {} }
            $cands += [pscustomobject]@{ V = $v; Sid = $s; Mtime = $mt }
        }
    }
    if ($cands.Count -eq 0) { return $null }
    $best = $cands | Sort-Object Mtime -Descending | Select-Object -First 1  # measured ran last
    return [pscustomobject]@{
        Cost      = (Get-Val $best.V 'lastCost')
        WallMs    = (Get-Val $best.V 'lastDuration')
        ApiMs     = (Get-Val $best.V 'lastAPIDuration')
        FirstRead = (Get-FirstCallRead $best.Sid)
    }
}

function Invoke-ClaudeRun([string]$label, [string]$query) {
    Write-Host ""
    Write-Host "==== $label ====" -ForegroundColor Cyan

    # Unique per-leg marker: warm-up and measured share it (so they cache-share); other legs
    # get a different one (so legs don't cross-contaminate). No spaces -> clean arg passing.
    $nonce = "benchmark-run-id-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())-$(Get-Random)-$PID"

    # Snapshot BEFORE the warm-up. Both TUI sessions update the same project entry, so after
    # both run that entry's lastSessionId is the MEASURED session's -- the only new id vs this.
    $pre = Get-Snapshot

    # --- Turn 1: warm-up (writes the TUI prefix into cache) --------------------------------
    Write-Host "WARM-UP: in Claude, type  hi  and press Enter; wait for the reply, then /exit." -ForegroundColor Yellow
    Wait-Key "  Press any key to start the WARM-UP session..."
    Start-Process -FilePath $ClaudeExe -ArgumentList '--model', $Model, '--append-system-prompt', $nonce -WorkingDirectory $WorkingDir -NoNewWindow -Wait

    # --- Turn 2: measured (reads the prefix warm; keep it to ONE turn) ---------------------
    Set-Clipboard -Value $query
    Write-Host "MEASURED: the query is on your clipboard. Paste it (Ctrl+V), press Enter, wait, then /exit." -ForegroundColor Yellow
    Write-Host "          Do exactly ONE turn so the cost is just the query." -ForegroundColor DarkGray
    Wait-Key "  Press any key to start the MEASURED session..."
    Start-Process -FilePath $ClaudeExe -ArgumentList '--model', $Model, '--append-system-prompt', $nonce -WorkingDirectory $WorkingDir -NoNewWindow -Wait

    # Read official metrics; retry in case the config write lags process exit.
    $r = $null
    for ($try = 0; $try -lt 6 -and $null -eq $r; $try++) {
        $r = Get-Result $pre
        if ($null -eq $r) { Start-Sleep -Milliseconds 400 }
    }

    $costUsd = $null; $wallMs = $null; $apiMs = $null; $cread = $null
    if ($r) {
        $costUsd = $r.Cost; $wallMs = $r.WallMs; $apiMs = $r.ApiMs; $cread = $r.FirstRead
    } else {
        Write-Warning "No fresh session recorded for the measured run (did it run a turn?)."
    }

    Write-Host ""
    Write-Host "  Result: $label (warm query turn)" -ForegroundColor Green
    if ($null -ne $costUsd) { Write-Host ("    Cost (official) : `${0:N4}" -f [double]$costUsd) }
    else                    { Write-Host  "    Cost (official) : n/a" }
    if ($null -ne $wallMs)  { Write-Host ("    Wall time       : {0}" -f (Format-Ms ([double]$wallMs))) }
    if ($null -ne $apiMs)   { Write-Host ("    API time        : {0}" -f (Format-Ms ([double]$apiMs))) }
    if ($null -ne $cread) {
        Write-Host ("    Warm-head read  : {0}" -f $cread)
        if ([long]$cread -eq 0) {
            Write-Warning "Measured session's first call read 0 cached tokens -- warm-up did NOT warm it (cold). Re-run this leg."
        }
    }

    [pscustomobject]@{
        Run      = $label
        CostUSD  = $costUsd
        WallMs   = $wallMs
        ApiMs    = $apiMs
        WarmRead = $cread
    }
}

try {
    # --- Prompt for the query --------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $Prompt = Read-Host "Enter the query to benchmark"
    }

    # --- Enable caching; measure the warm query turn ---------------------------------------
    Write-Host "Prompt caching ENABLED; measuring the WARM query turn (TUI warm-up + TUI query per leg)..." -ForegroundColor Yellow
    foreach ($name in $cacheVars.Keys) { Set-Env $name $cacheVars[$name] }

    # --- Run twice: with and without JetBrains context ------------------------------------
    $results = @()

    jbcontext setup-agent --agent=claude
    $results += Invoke-ClaudeRun "Run Claude with JetBrains Context" $Prompt

    jbcontext remove-agent --agent=claude
    $results += Invoke-ClaudeRun "Run Claude without JetBrains Context" $Prompt

    # --- Summary table ---------------------------------------------------------------------
    Write-Host ""
    Write-Host "==== Summary (warm query turn, official cost) ====" -ForegroundColor Cyan
    $results | Format-Table `
        Run,
        @{ Label = "Cost USD"; Expression = { if ($null -ne $_.CostUSD)  { "{0:N4}" -f [double]$_.CostUSD } else { "n/a" } }; Align = "Right" },
        @{ Label = "Wall";     Expression = { if ($null -ne $_.WallMs)   { Format-Ms ([double]$_.WallMs) }  else { "n/a" } }; Align = "Right" },
        @{ Label = "API";      Expression = { if ($null -ne $_.ApiMs)    { Format-Ms ([double]$_.ApiMs) }   else { "n/a" } }; Align = "Right" },
        @{ Label = "WarmRead"; Expression = { if ($null -ne $_.WarmRead) { $_.WarmRead }                    else { "n/a" } }; Align = "Right" } `
        -AutoSize

    Write-Host "Cost/Wall/API are Claude Code's OFFICIAL figures for the measured (2nd) session." -ForegroundColor DarkGray
    Write-Host "WarmRead = cache_read on that session's first call; >0 means the warm-up populated the cache." -ForegroundColor DarkGray
}
finally {
    # --- Restore original environment ------------------------------------------------------
    Write-Host "Restoring original cache environment..." -ForegroundColor Yellow
    foreach ($name in $original.Keys) { Set-Env $name $original[$name] }
    jbcontext setup-agent --agent=claude
}
