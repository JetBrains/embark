#!/usr/bin/env bash
set -euo pipefail

# setup-agent-devin.sh — Install JetBrains Context (jbcontext) integration for Devin CLI.
#
# The native `jbcontext setup-agent` binary does not yet know `--agent=DEVIN`.
# This script provides equivalent, complete Devin CLI setup using the integration
# assets bundled in this repository.
#
# Usage:
#   scripts/setup-agent-devin.sh --agent=DEVIN [--scope=USER|PROJECT] [--non-interactive] [--auto]
#
# Scope:
#   USER    — install into ~/.config/devin/ (global Devin CLI config, default)
#   PROJECT — install into the current working directory (./.devin, ./AGENTS.md, ./hooks/jbcontext)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_CONFIG="$REPO_ROOT/.devin/config.json"
SRC_HOOKS_V1="$REPO_ROOT/.devin/hooks.v1.json"
SRC_SKILLS_DIR="$REPO_ROOT/.devin/skills"
SRC_AGENTS_MD="$REPO_ROOT/AGENTS.md"
SRC_HOOKS_DIR="$REPO_ROOT/hooks/jbcontext"
SRC_MCP_DESC_DIR="$REPO_ROOT/mcp"

# Options
AGENT=""
SCOPE="USER"
NON_INTERACTIVE=false
AUTO=false
COMPONENT_SPECIFIED=false
INSTALL_SKILLS=false
INSTALL_HOOKS=false
INSTALL_INSTRUCTIONS=false
INSTALL_MCP=false
INSTALL_SUBAGENTS=false

log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $1"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m   $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m  $1" >&2; }

usage() {
  cat <<'EOF'
Usage: setup-agent-devin.sh --agent=DEVIN [options]

Options:
  --agent=DEVIN           Required. Must be DEVIN (case-insensitive).
  --scope=USER|PROJECT    Where to install. Default: USER.
  --non-interactive       Do not prompt for confirmation.
  --auto                  Install the recommended bundle (skills, hooks,
                          MCP, subagents). Instructions go via hooks by default;
                          add --instructions to also write AGENTS.md.
  --skills                Install only skills.
  --hooks                 Install only hooks.
  --instructions          Install only instructions (AGENTS.md).
  --mcp                   Register the jbcontext MCP server only.
  --subagents             Install subagents only.
  -h, --help              Show this help.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent=*)
      AGENT="${1#*=}"
      ;;
    --agent)
      shift
      AGENT="$1"
      ;;
    --scope=*)
      SCOPE="${1#*=}"
      ;;
    --scope)
      shift
      SCOPE="$1"
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      ;;
    --auto)
      AUTO=true
      ;;
    --skills)
      COMPONENT_SPECIFIED=true
      INSTALL_SKILLS=true
      ;;
    --hooks)
      COMPONENT_SPECIFIED=true
      INSTALL_HOOKS=true
      ;;
    --instructions)
      COMPONENT_SPECIFIED=true
      INSTALL_INSTRUCTIONS=true
      ;;
    --mcp)
      COMPONENT_SPECIFIED=true
      INSTALL_MCP=true
      ;;
    --subagents)
      COMPONENT_SPECIFIED=true
      INSTALL_SUBAGENTS=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# Validate agent
if [[ -z "$AGENT" ]]; then
  if $NON_INTERACTIVE; then
    log_error "--agent is required in non-interactive mode."
    exit 1
  fi
  echo -n "Agent to set up (DEVIN): "
  read -r AGENT
fi

AGENT_LOWER="$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')"
if [[ "$AGENT_LOWER" != "devin" ]]; then
  log_error "Unsupported agent: $AGENT. This installer only supports DEVIN."
  exit 1
fi

# Validate scope
SCOPE_UPPER="$(printf '%s' "$SCOPE" | tr '[:lower:]' '[:upper:]')"
if [[ "$SCOPE_UPPER" != "USER" && "$SCOPE_UPPER" != "PROJECT" ]]; then
  log_error "Invalid scope: $SCOPE. Use USER or PROJECT."
  exit 1
fi

# Default to bundle unless component flags were given
if ! $COMPONENT_SPECIFIED; then
  INSTALL_SKILLS=true
  INSTALL_HOOKS=true
  # Instructions are injected via SessionStart/PostCompaction/UserPromptSubmit hooks.
  # Install AGENTS.md only when --instructions is explicitly requested.
  INSTALL_INSTRUCTIONS=false
  INSTALL_MCP=true
  INSTALL_SUBAGENTS=true
fi

# Compute target paths
if [[ "$SCOPE_UPPER" == "USER" ]]; then
  TARGET_DIR="${HOME}/.config/devin"
  TARGET_CONFIG="$TARGET_DIR/config.json"
  TARGET_AGENTS_MD="$TARGET_DIR/AGENTS.md"
  TARGET_SKILLS_DIR="$TARGET_DIR/skills"
  TARGET_HOOKS_DIR="$TARGET_DIR/hooks/jbcontext"
else
  TARGET_DIR="$(pwd)"
  TARGET_CONFIG="$TARGET_DIR/.devin/config.json"
  TARGET_AGENTS_MD="$TARGET_DIR/AGENTS.md"
  TARGET_SKILLS_DIR="$TARGET_DIR/.devin/skills"
  TARGET_HOOKS_DIR="$TARGET_DIR/hooks/jbcontext"
fi

# Prerequisite checks
for cmd in jq cp mkdir node; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command '$cmd' not found."
    exit 1
  fi
done

if ! command -v jbcontext >/dev/null 2>&1; then
  log_warn "jbcontext CLI not found on PATH. Install it before using the integration:"
  log_warn "  curl -fsSL https://download.jetbrains.com/jetbrains-context/release/download-jbcontext.sh | bash"
fi

echo ""
echo "JetBrains Context Devin CLI installer"
echo "  Source:  $REPO_ROOT"
echo "  Scope:   $SCOPE_UPPER"
echo "  Target:  $TARGET_DIR"
echo ""

if ! $NON_INTERACTIVE; then
  echo -n "Proceed with installation? [Y/n]: "
  read -r reply
  case "$reply" in
    [nN]|[nN][oO])
      log_info "Cancelled."
      exit 0
      ;;
  esac
fi

mkdir -p "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Merge helpers
# ---------------------------------------------------------------------------

# Resolve the jbcontext binary to an absolute path for the MCP server command.
# Falls back to 'jbcontext' on PATH if not found in common install locations.
resolve_jbcontext_binary() {
  local candidates=(
    "${HOME}/.jbcontext/bin/jbcontext"
    "/usr/local/bin/jbcontext"
    "/opt/homebrew/bin/jbcontext"
    "${HOME}/.local/bin/jbcontext"
  )
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  if command -v jbcontext >/dev/null 2>&1; then
    command -v jbcontext
    return 0
  fi
  printf '%s' 'jbcontext'
  return 1
}

# Rewrite the jbcontext MCP server command in a config.json to an absolute path.
rewrite_jbcontext_command() {
  local json_file="$1"
  local jbctx_path="$2"
  jq --arg cmd "$jbctx_path" '.mcpServers.jbcontext.command = $cmd' "$json_file"
}

# Replace hooks/jbcontext/ path references in hook command strings with the
# actual hooks directory. Works both for bare paths and for `node "..."` commands.
rewrite_hook_commands() {
  local json_file="$1"
  local hook_dir="$2"
  jq --arg dir "$hook_dir" 'walk(
    if type == "string" and contains("hooks/jbcontext/") then
      gsub("hooks/jbcontext/"; $dir + "/")
    else
      .
    end
  )' "$json_file"
}

# Merge jbcontext config into an existing Devin config.json.
# If $1 does not exist, a JSON null is fed as the target base.
merge_devin_config() {
  local target="$1"
  local source="$2"
  local hooks_json="$3"
  local input_cmd

  if [[ -f "$target" ]]; then
    input_cmd="cat \"$target\""
  else
    input_cmd="echo 'null'"
  fi

  eval "$input_cmd" | jq --slurpfile src "$source" --slurpfile hooks "$hooks_json" '
    ($src[0].mcpServers // {}) as $s_mcp
    | ($src[0].permissions // {}) as $s_perm
    | ($hooks[0] // {}) as $s_hooks
    | . as $t
    | ($t.mcpServers + $s_mcp) as $mcp
    | (
        ($t.permissions // {}) as $tp
        | {
            allow: ((($tp.allow // []) + ($s_perm.allow // [])) | unique),
            deny:  ((($tp.deny  // []) + ($s_perm.deny  // [])) | unique),
            ask:   ((($tp.ask   // []) + ($s_perm.ask   // [])) | unique)
          }
      ) as $perm
    | ($t.hooks // {}) as $t_hooks
    | (
        (($t_hooks | keys) + ($s_hooks | keys)) | unique
        | map({(.): (($t_hooks[.] // []) + ($s_hooks[.] // []))})
        | add // {}
      ) as $hooks
    | $t
    | .mcpServers = $mcp
    | .permissions = $perm
    | .hooks = $hooks
  '
}

# Insert or replace content between jbcontext instruction markers in AGENTS.md
install_agents_md() {
  local src="$1"
  local dst="$2"

  local marker_start="<!-- jbcontext-instructions-start -->"
  local marker_end="<!-- jbcontext-instructions-end -->"
  local block
  block="$(awk "/$marker_start/{flag=1; print; next} /$marker_end/{print; flag=0; next} flag" "$src")"

  if [[ -f "$dst" ]]; then
    if grep -qF "$marker_start" "$dst"; then
      # Replace block between markers
      awk -v start="$marker_start" -v end="$marker_end" -v block="$block" '
        $0 == start { print block; skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
      ' "$dst" > "${dst}.tmp" && mv "${dst}.tmp" "$dst"
    else
      # Append with header
      {
        echo ""
        echo "$block"
      } >> "$dst"
    fi
  else
    cp "$src" "$dst"
  fi
}

# ---------------------------------------------------------------------------
# Install components
# ---------------------------------------------------------------------------

# 1. MCP server + permissions
if $INSTALL_MCP || $INSTALL_HOOKS; then
  mkdir -p "$(dirname "$TARGET_CONFIG")"

  if [[ "$SCOPE_UPPER" == "USER" ]]; then
    # For user scope, rewrite hook command paths to absolute and resolve
    # jbcontext binary path for the MCP server command.
    local_hooks_json="/tmp/jbcontext-devin-hooks-$$.json"
    local_config_json="/tmp/jbcontext-devin-config-$$.json"
    rewrite_hook_commands "$SRC_HOOKS_V1" "$TARGET_HOOKS_DIR" > "$local_hooks_json"

    jbctx_path="$(resolve_jbcontext_binary)"
    if [[ "$jbctx_path" != "jbcontext" ]]; then
      rewrite_jbcontext_command "$SRC_CONFIG" "$jbctx_path" > "$local_config_json"
    else
      cp "$SRC_CONFIG" "$local_config_json"
      log_warn "jbcontext binary not found on PATH or in common locations; MCP server command left as 'jbcontext'"
    fi

    if [[ -f "$TARGET_CONFIG" ]]; then
      log_info "Merging jbconfig into $TARGET_CONFIG"
      cp "$TARGET_CONFIG" "$TARGET_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
      merge_devin_config "$TARGET_CONFIG" "$local_config_json" "$local_hooks_json" > "${TARGET_CONFIG}.tmp" && mv "${TARGET_CONFIG}.tmp" "$TARGET_CONFIG"
    else
      log_info "Creating $TARGET_CONFIG"
      merge_devin_config /dev/null "$local_config_json" "$local_hooks_json" > "$TARGET_CONFIG"
    fi

    rm -f "$local_hooks_json" "$local_config_json"
  else
    # Project scope: keep hooks in .devin/hooks.v1.json, config.json only mcp/permissions
    if [[ -f "$TARGET_CONFIG" ]]; then
      log_info "Merging jbconfig into $TARGET_CONFIG"
      cp "$TARGET_CONFIG" "$TARGET_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
      jq --slurpfile src "$SRC_CONFIG" '
        ($src[0].mcpServers) as $s_mcp
        | ($src[0].permissions) as $s_perm
        | . as $t
        | .mcpServers = ($t.mcpServers + $s_mcp)
        | .permissions = (
            ($t.permissions // {}) as $tp
            | {
                allow: ((($tp.allow // []) + ($s_perm.allow // [])) | unique),
                deny:  ((($tp.deny  // []) + ($s_perm.deny  // [])) | unique),
                ask:   ((($tp.ask   // []) + ($s_perm.ask   // [])) | unique)
              }
          )
      ' "$TARGET_CONFIG" > "${TARGET_CONFIG}.tmp" && mv "${TARGET_CONFIG}.tmp" "$TARGET_CONFIG"
    else
      log_info "Creating $TARGET_CONFIG"
      cp "$SRC_CONFIG" "$TARGET_CONFIG"
    fi
  fi

  log_ok "MCP server registered: jbcontext (stdio)"
fi

# 2. Hooks (Node adapter + instruction text)
if $INSTALL_HOOKS; then
  mkdir -p "$TARGET_HOOKS_DIR"
  cp -R "$SRC_HOOKS_DIR/"* "$TARGET_HOOKS_DIR/"
  chmod +x "$TARGET_HOOKS_DIR"/*.js 2>/dev/null || true
  log_ok "Hooks installed to $TARGET_HOOKS_DIR"

  if [[ "$SCOPE_UPPER" == "PROJECT" ]]; then
    mkdir -p "$TARGET_DIR/.devin"
    cp "$SRC_HOOKS_V1" "$TARGET_DIR/.devin/hooks.v1.json"
    log_ok "Project hooks manifest installed to .devin/hooks.v1.json"
  fi
fi

# 2b. MCP tool descriptions (for documentation / future wrapper)
if $INSTALL_MCP || $INSTALL_HOOKS; then
  if [[ -d "$SRC_MCP_DESC_DIR" ]]; then
    mkdir -p "$TARGET_HOOKS_DIR/mcp"
    cp -R "$SRC_MCP_DESC_DIR/"* "$TARGET_HOOKS_DIR/mcp/"
    log_ok "MCP tool descriptions copied to $TARGET_HOOKS_DIR/mcp"
  fi
fi

# 3. Skills
if $INSTALL_SKILLS; then
  mkdir -p "$TARGET_SKILLS_DIR"
  cp -R "$SRC_SKILLS_DIR/"* "$TARGET_SKILLS_DIR/"
  log_ok "Skills installed to $TARGET_SKILLS_DIR"
fi

# 4. Subagents (context-explorer is packaged as a subagent skill)
if $INSTALL_SUBAGENTS; then
  mkdir -p "$TARGET_SKILLS_DIR"
  if [[ -d "$SRC_SKILLS_DIR/context-explorer" ]]; then
    log_ok "Subagent skill installed: context-explorer"
  else
    log_warn "context-explorer skill not found; skipping subagent."
  fi
fi

# 5. Instructions (AGENTS.md)
if $INSTALL_INSTRUCTIONS; then
  install_agents_md "$SRC_AGENTS_MD" "$TARGET_AGENTS_MD"
  log_ok "Instructions installed to $TARGET_AGENTS_MD"
fi

echo ""
echo "---------------------------------------------------------------"
log_ok "Devin CLI integration installed successfully."
echo ""
echo "Next steps:"
echo "  1. Run 'jbcontext index' in your project to build the index."
echo "  2. Launch Devin CLI; use /context-search for focused search or /context-explorer for deeper exploration."
if [[ "$SCOPE_UPPER" == "USER" ]]; then
  echo "  3. Global config is at $TARGET_CONFIG"
else
  echo "  3. Project config is at $TARGET_CONFIG"
fi
echo ""
echo "Rollback: backups of overwritten files have a .bak.<timestamp> suffix."
