#!/usr/bin/env bash
#
# Benchmarks the interactive Claude Code TUI on a single query with vs. without JetBrains
# Context, measuring the WARM steady-state (what a real ongoing session pays), using Claude
# Code's OFFICIAL cost -- no manual price tables.
#
#   - Optional query as the first positional arg; otherwise prompted.
#   - Keeps prompt caching ENABLED (unsets DISABLE_PROMPT_CACHING); pins the auto-updater; 5-min TTL.
#   - Each leg runs TWO interactive TUI sessions sharing one unique marker:
#       1) WARM-UP  : you type  hi  and /exit -- writes the TUI tools+system prefix into cache.
#       2) MEASURED : you paste the query (one turn) and /exit -- reads that prefix warm.
#     Because the measured session is separate and single-turn, its OFFICIAL cost is the warm
#     query cost (the warm-up's cold prefix write is a different session, excluded).
#   - Reads OFFICIAL metrics from ~/.claude.json (lastCost / lastDuration / lastAPIDuration) for
#     the session created by the measured run. WarmRead = cache_read on that session's FIRST
#     call (from the transcript); >0 confirms the warm-up populated the cache.
#   - Restores the original cache environment on exit.
#
# Usage:  ./singe-query-bench-claude.sh [--model <id>] [query]

set -euo pipefail

MODEL="claude-opus-4-8"
PROMPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --model=*) MODEL="${1#*=}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) PROMPT="$1"; shift ;;
    esac
done

CACHE_VARS="DISABLE_PROMPT_CACHING DISABLE_AUTOUPDATER ENABLE_PROMPT_CACHING_1H"

# Indexed arrays are fine on bash 3.2 (macOS); associative arrays are not, so we avoid them.
SUM_LABEL=(); SUM_COST=(); SUM_WALL=(); SUM_API=(); SUM_CREAD=()

# --- Cache env save / enable / restore (portable, no associative arrays) --------------------
save_and_enable_caches() {
    for v in $CACHE_VARS; do
        if eval "[ -n \"\${$v+x}\" ]"; then
            eval "__set_$v=1"; eval "__val_$v=\"\$$v\""
        else
            eval "__set_$v=0"
        fi
    done
    unset DISABLE_PROMPT_CACHING 2>/dev/null || true   # caching ON for realism
    export DISABLE_AUTOUPDATER=1                        # pin the binary across runs
    unset ENABLE_PROMPT_CACHING_1H 2>/dev/null || true # 5-min TTL (warm-up + measured run back-to-back)
}

cleanup() {
    echo "Restoring original cache environment..."
    for v in $CACHE_VARS; do
        if [ "$(eval "echo \${__set_$v:-0}")" = "1" ]; then
            eval "export $v=\"\$__val_$v\""
        else
            unset "$v" 2>/dev/null || true
        fi
    done
    jbcontext setup-agent --agent=claude || true
}

# --- Clipboard (pbcopy / wl-copy / xclip / xsel) -------------------------------------------
copy_clip() {
    if   command -v pbcopy  >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
    elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
    elif command -v xsel    >/dev/null 2>&1; then printf '%s' "$1" | xsel --clipboard --input
    else return 1
    fi
}

fmt_ms() {
    local ms="${1%%.*}"
    if [ -z "$ms" ] || [ "$ms" = "0" ]; then printf '00:00'; return; fi
    local s=$(( ms / 1000 )) h m sec
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); sec=$(( s % 60 ))
    if [ "$h" -gt 0 ]; then printf '%02d:%02d:%02d' "$h" "$m" "$sec"
    else printf '%02d:%02d' "$m" "$sec"; fi
}

# Wait for a single keypress so the user can read the step before the TUI takes the terminal.
pause() {
    printf '%s' "${1:-Press any key to launch Claude...}"
    read -rsn1 _ </dev/tty 2>/dev/null || read -r _ 2>/dev/null || true
    printf '\n'
}

# --- Read OFFICIAL metrics from ~/.claude.json via python3 ---------------------------------
# We do NOT match by cwd (Claude Code keys the project entry by the git-repo root, not the
# launch cwd). Instead we detect the session created by the measured run as the one whose
# lastSessionId is new since the pre-run snapshot.
# pyhelper snapshot            -> JSON [sessionId, ...] currently recorded across all projects
# pyhelper result <preJSON>    -> "lastCost|lastDuration|lastAPIDuration|firstCallCacheRead"
#                                 for the newest newly-created session, else "" (retry)
pyhelper() {
    python3 - "$@" <<'PY'
import json, os, sys, glob

mode = sys.argv[1]
try:
    projects = json.load(open(os.path.expanduser("~/.claude.json"), encoding="utf-8")).get("projects", {}) or {}
except Exception:
    projects = {}

if mode == "snapshot":
    sids = sorted({ (v.get("lastSessionId") or "") for v in projects.values() if isinstance(v, dict) } - {""})
    print(json.dumps(sids))
    sys.exit(0)

# mode == "result"
try:
    pre = set(json.loads(sys.argv[2])) if len(sys.argv) > 2 and sys.argv[2] else set()
except Exception:
    pre = set()

BASE = os.path.expanduser("~/.claude/projects")
def sid_mtime(sid):
    for p in glob.glob(os.path.join(BASE, "*", sid + ".jsonl")):
        try: return os.path.getmtime(p)
        except OSError: pass
    return 0.0

# Candidate = any project entry whose lastSessionId is new and that has a recorded cost.
cands = []
for v in projects.values():
    if not isinstance(v, dict): continue
    s = v.get("lastSessionId")
    if s and s not in pre and v.get("lastCost") is not None:
        cands.append((v, s))
if not cands:
    sys.exit(0)  # not persisted yet -> caller retries

# The measured session ran last, so its transcript is newest.
ent, sid = max(cands, key=lambda vs: sid_mtime(vs[1]))

# First-call cache_read from the transcript (0 = cold, >0 = warm-up took). Located by session id.
first_read = ""
for p in glob.glob(os.path.join(BASE, "*", sid + ".jsonl")):
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                try: o = json.loads(line)
                except Exception: continue
                if o.get("type") != "assistant": continue
                u = (o.get("message") or {}).get("usage")
                if isinstance(u, dict) and "cache_read_input_tokens" in u:
                    first_read = u.get("cache_read_input_tokens"); break
    except Exception:
        pass
    if first_read != "": break

print("%s|%s|%s|%s" % (ent.get("lastCost", ""), ent.get("lastDuration", ""),
                       ent.get("lastAPIDuration", ""), first_read))
PY
}

invoke_run() {
    local label="$1"
    printf '\n==== %s ====\n' "$label"

    # Unique per-leg marker: warm-up and measured share it (so they cache-share); other legs
    # get a different one (so legs don't cross-contaminate).
    local nonce="benchmark-run-id-$(date +%s)-$RANDOM-$$"

    # Snapshot BEFORE the warm-up. Both TUI sessions update the same project entry, so after
    # both run that entry's lastSessionId is the MEASURED session's -- the only new id vs this.
    local pre; pre="$(pyhelper snapshot)"

    # --- Turn 1: warm-up (writes the TUI prefix into cache) --------------------------------
    echo "WARM-UP: in Claude, type  hi  and press Enter; wait for the reply, then /exit."
    pause "  Press any key to start the WARM-UP session..."
    "$CLAUDE_BIN" --model "$MODEL" --append-system-prompt "$nonce" || true

    # --- Turn 2: measured (reads the prefix warm; keep it to ONE turn) ---------------------
    if copy_clip "$PROMPT"; then
        echo "MEASURED: the query is on your clipboard. Paste it, press Enter, wait for it to"
        echo "          finish, then /exit. Do exactly ONE turn so the cost is just the query."
    else
        echo "No clipboard tool found (install pbcopy/wl-copy/xclip/xsel). Paste this query manually:"
        printf '  %s\n' "$PROMPT"
        echo "Do exactly ONE turn, then /exit."
    fi
    pause "  Press any key to start the MEASURED session..."
    "$CLAUDE_BIN" --model "$MODEL" --append-system-prompt "$nonce" || true

    # Read official metrics; retry in case the config write lags process exit.
    local out="" i
    for i in 0 1 2 3 4 5; do
        out="$(pyhelper result "$pre")"
        [ -n "$out" ] && break
        sleep 0.4
    done

    local cost="n/a" wall="n/a" api="n/a" cread=""
    if [ -n "$out" ]; then
        local c dms ams
        IFS='|' read -r c dms ams cread <<<"$out"
        [ -n "$c" ]   && cost="$(printf '%.4f' "$c")"
        [ -n "$dms" ] && wall="$(fmt_ms "$dms")"
        [ -n "$ams" ] && api="$(fmt_ms "$ams")"
    else
        echo "WARNING: no fresh session recorded for the measured run (did it run a turn?)." >&2
    fi

    printf '\n  Result: %s (warm query turn)\n' "$label"
    printf '    Cost (official) : $%s\n' "$cost"
    [ "$wall" != "n/a" ] && printf '    Wall time       : %s\n' "$wall"
    [ "$api"  != "n/a" ] && printf '    API time        : %s\n' "$api"
    if [ -n "$cread" ]; then
        printf '    Warm-head read  : %s\n' "$cread"
        if [ "$cread" = "0" ]; then
            echo "    WARNING: measured session's first call read 0 cached tokens -- warm-up did NOT" >&2
            echo "             warm it (cold). Re-run this leg (do the 'hi' warm-up first)." >&2
        fi
    fi

    SUM_LABEL+=("$label"); SUM_COST+=("$cost"); SUM_WALL+=("$wall"); SUM_API+=("$api"); SUM_CREAD+=("${cread:-n/a}")
}

main() {
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required (to read ~/.claude.json)" >&2; exit 1; }
    CLAUDE_BIN="$(command -v claude)" || { echo "claude not found in PATH" >&2; exit 1; }

    if [ -z "$PROMPT" ]; then
        read -r -p "Enter the query to benchmark: " PROMPT
    fi

    save_and_enable_caches
    trap cleanup EXIT
    echo "Prompt caching ENABLED; measuring the WARM query turn (TUI warm-up + TUI query per leg)..."

    jbcontext setup-agent --agent=claude
    invoke_run "Run Claude with JetBrains Context"

    jbcontext remove-agent --agent=claude
    invoke_run "Run Claude without JetBrains Context"

    echo
    echo "==== Summary (warm query turn, official cost) ===="
    printf '%-36s %10s %9s %9s %10s\n' "Run" "Cost USD" "Wall" "API" "WarmRead"
    for i in "${!SUM_LABEL[@]}"; do
        printf '%-36s %10s %9s %9s %10s\n' "${SUM_LABEL[$i]}" "${SUM_COST[$i]}" "${SUM_WALL[$i]}" "${SUM_API[$i]}" "${SUM_CREAD[$i]}"
    done
    echo
    echo "Cost/Wall/API are Claude Code's OFFICIAL figures for the measured (2nd) session."
    echo "WarmRead = cache_read on that session's first call; >0 means the warm-up populated the cache."
}

main
