#!/bin/bash
input=$(cat)

# ── helpers ──────────────────────────────────────────────────────────────────

countdown_str() {
  local epoch="$1"
  local now_epoch
  now_epoch=$(date +%s)
  local secs_left=$(( epoch - now_epoch ))
  if [ "$secs_left" -le 59 ]; then
    echo "<1m"
  else
    local mins_left=$(( secs_left / 60 ))
    local h=$(( mins_left / 60 ))
    local m=$(( mins_left % 60 ))
    if [ "$h" -gt 0 ]; then
      printf '%dh%02dm' "$h" "$m"
    else
      printf '%dm' "$m"
    fi
  fi
}

elapsed_str() {
  local secs="$1"
  [ "$secs" -lt 0 ] && secs=0
  local d=$(( secs / 86400 ))
  local h=$(( secs % 86400 / 3600 ))
  local m=$(( secs % 3600 / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else                      printf '%dm' "$m"
  fi
}

# Birth time of a file, falling back to mtime. Prints nothing when unavailable.
file_birth_epoch() {
  local f="$1" e=""
  [ -f "$f" ] || return
  e=$(stat -f %B "$f" 2>/dev/null || stat -c %W "$f" 2>/dev/null)
  case "$e" in
    ''|0|-1) e=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) ;;
  esac
  case "$e" in ''|*[!0-9]*) return ;; esac
  printf '%s' "$e"
}

# ── raw values ────────────────────────────────────────────────────────────────

cwd=$(echo "$input" | jq -r '.cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)

project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
[ -z "$project_dir" ] && project_dir="$cwd"

# Session identity — used to look up start/restart state written by the
# SessionStart hook (hooks/session-state.sh)
session_id=$(echo "$input"      | jq -r '.session_id      // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# Model
model_id=$(echo "$input"   | jq -r '.model.id           // empty')
model_name=$(echo "$input" | jq -r '.model.display_name // empty')
model_short="${model_id#claude-}"   # "claude-sonnet-4-6" → "sonnet-4-6"

# Effort / thinking
effort_level=$(echo "$input"  | jq -r '.effort.level // "auto"')
thinking_on=$(echo "$input"   | jq -r '.thinking.enabled  // empty')

# Output style (mode)
output_style=$(echo "$input" | jq -r '.output_style.name // empty')

# Context window
ctx_total=$(echo "$input"   | jq -r '.context_window.context_window_size     // empty')
ctx_used_pct=$(echo "$input" | jq -r '.context_window.used_percentage        // empty')
ctx_rem_pct=$(echo "$input"  | jq -r '.context_window.remaining_percentage   // empty')
ctx_used_tok=$(echo "$input" | jq -r '.context_window.total_input_tokens     // empty')

# Skills — count .md / .yaml / .yml files under .agents/skills/
skills_count=0
skills_ctx_pct=""
for skills_dir in "$project_dir/.agents/skills" "$project_dir/skills"; do
  if [ -d "$skills_dir" ]; then
    c=$(find "$skills_dir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | wc -l)
    if [ "$c" -gt 0 ]; then
      skills_count="$c"
      # Estimate skills token footprint: sum byte sizes of skill files ÷ 4 (≈tokens)
      if [ -n "$ctx_total" ] && [ "$ctx_total" -gt 0 ]; then
        skill_bytes=$(find "$skills_dir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')
        skill_tokens=$(( skill_bytes / 4 ))
        skills_ctx_pct=$(awk "BEGIN{printf \"%.1f\", ($skill_tokens/$ctx_total)*100}")
      fi
      break
    fi
  fi
done

# MCP — count servers + estimate tool count from plugin sources
mcp_servers=0
mcp_tools=0
settings_file="$HOME/.claude/settings.json"
installed_plugins_file="$HOME/.claude/plugins/installed_plugins.json"

# Estimate tool count for a single server by server name or install path
# Returns count to stdout
_mcp_tool_count() {
  local srv_name="$1" install_path="$2"
  # Try to count from local TypeScript source (look for  name: 'toolname'  lines)
  local src=""
  for candidate in "$install_path/server.ts" "$install_path/src/server.ts" \
                   "$install_path/src/index.ts" "$install_path/index.ts"; do
    [ -f "$candidate" ] && src="$candidate" && break
  done
  if [ -n "$src" ]; then
    # Count occurrences of  name: '<word>'  that appear inside a tools array
    local c
    c=$(awk '/tools:\s*\[/,/^\s*\]/' "$src" 2>/dev/null | grep -c "name: '" 2>/dev/null)
    [ "${c:-0}" -gt 0 ] && echo "$c" && return
  fi
  # Fallback: known tool counts for well-known external MCP servers
  case "$srv_name" in
    context7)   echo 4  ;;
    github)     echo 52 ;;   # github copilot MCP has ~52 tools
    exa)        echo 3  ;;   # web_search_exa, web_search_advanced_exa, web_fetch_exa
    firebase)   echo 16 ;;
    linear)     echo 20 ;;
    asana)      echo 12 ;;
    gitlab)     echo 30 ;;
    terraform)  echo 10 ;;
    playwright) echo 15 ;;
    serena)     echo 20 ;;
    greptile)   echo 5  ;;
    *)          echo 5  ;;   # conservative default
  esac
}

# From settings.json mcpServers
if [ -f "$settings_file" ]; then
  while IFS= read -r srv_name; do
    [ -z "$srv_name" ] && continue
    mcp_servers=$(( mcp_servers + 1 ))
    t=$(_mcp_tool_count "$srv_name" "")
    mcp_tools=$(( mcp_tools + ${t:-5} ))
  done < <(jq -r '(.mcpServers // {}) | keys[]' "$settings_file" 2>/dev/null)
fi

# From each installed plugin's .mcp.json
if [ -f "$installed_plugins_file" ]; then
  while IFS=$'\t' read -r install_path; do
    [ -z "$install_path" ] && continue
    mcp_file="${install_path}/.mcp.json"
    [ ! -f "$mcp_file" ] && continue
    # Extract server names from the .mcp.json (handles both formats)
    while IFS= read -r srv_name; do
      [ -z "$srv_name" ] && continue
      mcp_servers=$(( mcp_servers + 1 ))
      t=$(_mcp_tool_count "$srv_name" "$install_path")
      mcp_tools=$(( mcp_tools + ${t:-5} ))
    done < <(jq -r 'if has("mcpServers") then .mcpServers | keys[] else keys[] end' "$mcp_file" 2>/dev/null)
  done < <(jq -r '.plugins | to_entries[] | .value[0].installPath' "$installed_plugins_file" 2>/dev/null)
fi

# Rate limits
five_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at        // empty')
week_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage  // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at        // empty')

TZ_ABBR=$(date +%Z)

# ── ANSI palette ──────────────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2;37m"
# colors (normal intensity to stay readable in the dimmed status area)
C_WHITE="\033[37m"
C_GREEN="\033[32m"      # model
C_CYAN="\033[36m"       # context window
C_YELLOW="\033[33m"     # skills / mcp
C_MAGENTA="\033[35m"    # 5h limit
C_BLUE="\033[34m"       # 7d limit
C_RED="\033[31m"        # over-limit warnings
C_BRIGHT_GREEN="\033[1;32m"
C_BRIGHT_BLUE="\033[1;34m"

SEP="${DIM} | ${RESET}"

# ── helper: print one labeled segment ─────────────────────────────────────────
# Usage: seg COLOR EMOJI LABEL VALUE
seg() {
  local color="$1" emoji="$2" label="$3" value="$4"
  printf "${color}${emoji} ${BOLD}${label}${RESET}${color}${value}${RESET}"
}

# ── session age + last restart ───────────────────────────────────────────────
# State is written by the SessionStart hook. When it is absent (hook disabled,
# or first render before the hook has ever run) we still show the age, derived
# from the transcript file, and simply omit the restart chip.
session_chip=""
if [ "$FANCY_STATUSLINE_SESSION" != "off" ]; then
  sess_started=""
  sess_event=""
  sess_event_at=""
  sess_restarts=0

  case "$session_id" in
    ''|*[!A-Za-z0-9._-]*) : ;;
    *)
      sess_state="$HOME/.claude/fancy-statusline/sessions/${session_id}.json"
      if [ -f "$sess_state" ]; then
        sess_started=$(jq -r   '.started       // empty' "$sess_state" 2>/dev/null)
        sess_event=$(jq -r     '.last_event    // empty' "$sess_state" 2>/dev/null)
        sess_event_at=$(jq -r  '.last_event_at // empty' "$sess_state" 2>/dev/null)
        sess_restarts=$(jq -r  '.restarts      // 0'     "$sess_state" 2>/dev/null)
      fi
      ;;
  esac

  case "$sess_started"  in ''|*[!0-9]*) sess_started=$(file_birth_epoch "$transcript_path") ;; esac
  case "$sess_restarts" in ''|*[!0-9]*) sess_restarts=0 ;; esac

  if [ -n "$sess_started" ]; then
    now_epoch=$(date +%s)
    session_chip="${C_WHITE}\xF0\x9F\x95\x92 ${BOLD}up:${RESET}${C_WHITE}$(elapsed_str $(( now_epoch - sess_started )))${RESET}"
  fi

  if [ "$sess_restarts" -gt 0 ] && [ -n "$sess_event" ]; then
    case "$sess_event" in
      resume)  ev_label="resumed"   ;;
      clear)   ev_label="cleared"   ;;
      compact) ev_label="compacted" ;;
      *)       ev_label="$sess_event" ;;
    esac
    ev_str="${BOLD}${ev_label}${RESET}${C_YELLOW}"
    case "$sess_event_at" in
      ''|*[!0-9]*) : ;;
      *) ev_time=$(date -r "$sess_event_at" '+%H:%M' 2>/dev/null || date -d "@${sess_event_at}" '+%H:%M' 2>/dev/null)
         [ -n "$ev_time" ] && ev_str="${ev_str}:${ev_time}" ;;
    esac
    [ "$sess_restarts" -gt 1 ] && ev_str="${ev_str} \xC3\x97${sess_restarts}"
    [ -n "$session_chip" ] && session_chip="${session_chip}${SEP}"
    session_chip="${session_chip}${C_YELLOW}\xE2\x9F\xB3 ${ev_str}${RESET}"
  fi
fi

# ── LINE 1 — machine identity ────────────────────────────────────────────────
printf "${C_BRIGHT_GREEN}%s@%s${RESET}" \
  "$(whoami)" "$(hostname -s)"
[ -n "$session_chip" ] && printf "%b" "${SEP}${session_chip}"
printf "\n"

# ── LINE 2 — working directory ───────────────────────────────────────────────
printf "${C_BRIGHT_BLUE}%s${RESET}\n" "$cwd"

# ── LINE 3 — model + effort + mode + context summary ─────────────────────────
line2=""

# Model chip
if [ -n "$model_short" ]; then
  chip="${model_short}"
  # Append effort if present
  case "$effort_level" in
    low)    chip="${chip} \xF0\x9F\x90\xA2 low"    ;;   # 🐢 low
    medium) chip="${chip} \xF0\x9F\x8F\x83 medium" ;;   # 🏃 medium
    high)   chip="${chip} \xF0\x9F\x9A\x80 high"   ;;   # 🚀 high
    xhigh)  chip="${chip} \xF0\x9F\x94\xA5 xhigh"  ;;   # 🔥 xhigh
    max)    chip="${chip} \xE2\x9A\xA1 max"         ;;   # ⚡ max
    auto)   chip="${chip} \xE2\x9A\x96 auto"        ;;   # ⚖️ auto
  esac
  # Append thinking indicator
  if [ "$thinking_on" = "true" ]; then
    chip="${chip} \xF0\x9F\xA7\xA0"  # 🧠
  fi
  line2="${C_GREEN}\xF0\x9F\xA4\x96 ${BOLD}model:${RESET}${C_GREEN}${chip}${RESET}"
fi

# Mode chip
if [ -n "$output_style" ] && [ "$output_style" != "default" ] && [ "$output_style" != "null" ]; then
  [ -n "$line2" ] && line2="${line2}${SEP}"
  line2="${line2}$(seg "$C_WHITE" "\xF0\x9F\x8E\xAF" "mode:" "$output_style")"
fi

# Context window chips
if [ -n "$ctx_total" ]; then
  ctx_total_k=$(awk "BEGIN{printf \"%.0f\", $ctx_total/1000}")
  [ -n "$line2" ] && line2="${line2}${SEP}"
  line2="${line2}${C_CYAN}\xF0\x9F\x93\x8A ${BOLD}ctx:${RESET}${C_CYAN}${ctx_total_k}k${RESET}"

  if [ -n "$ctx_used_pct" ]; then
    used_int=$(printf "%.0f" "$ctx_used_pct")
    used_color="$C_CYAN"
    [ "$used_int" -ge 80 ] && used_color="$C_RED"
    [ "$used_int" -ge 50 ] && [ "$used_int" -lt 80 ] && used_color="$C_YELLOW"
    used_fmt=$(printf "%.0f%%" "$ctx_used_pct")
    line2="${line2}${SEP}${used_color}\xF0\x9F\x93\x88 ${BOLD}used:${RESET}${used_color}${used_fmt}${RESET}"
  fi

  if [ -n "$ctx_rem_pct" ]; then
    rem_int=$(printf "%.0f" "$ctx_rem_pct")
    rem_color="$C_CYAN"
    [ "$rem_int" -le 20 ] && rem_color="$C_RED"
    [ "$rem_int" -le 50 ] && [ "$rem_int" -gt 20 ] && rem_color="$C_YELLOW"
    rem_fmt=$(printf "%.0f%%" "$ctx_rem_pct")
    line2="${line2}${SEP}${rem_color}\xF0\x9F\x93\x89 ${BOLD}rem:${RESET}${rem_color}${rem_fmt}${RESET}"
  fi
fi

[ -n "$line2" ] && printf "%b\n" "$line2"

# ── LINE 4 — skills + MCP ────────────────────────────────────────────────────
if [ -n "$ctx_total" ]; then
  line3=""

  _seg3() { [ -n "$line3" ] && line3="${line3}${SEP}"; line3="${line3}$1"; }

  # Skills segment
  if [ "$skills_count" -gt 0 ]; then
    skills_str="${skills_count}"
    [ -n "$skills_ctx_pct" ] && skills_str="${skills_str} (${skills_ctx_pct}% ctx)"
    _seg3 "${C_YELLOW}\xF0\x9F\x94\xA7 ${BOLD}skills:${RESET}${C_YELLOW}${skills_str}${RESET}"
  fi

  # MCP segment — only when servers > 0
  if [ -n "$mcp_servers" ] && [ "$mcp_servers" -gt 0 ]; then
    mcp_str="${mcp_servers} srv"
    if [ "$mcp_tools" -gt 0 ]; then
      mcp_str="${mcp_str} / ~${mcp_tools} tools"
      if [ -n "$ctx_total" ] && [ "$ctx_total" -gt 0 ]; then
        mcp_tok=$(( mcp_tools * 400 ))
        mcp_ctx_pct=$(awk "BEGIN{printf \"%.1f\", ($mcp_tok/$ctx_total)*100}")
        mcp_str="${mcp_str} (~${mcp_ctx_pct}% ctx)"
      fi
    fi
    _seg3 "${C_YELLOW}\xF0\x9F\x94\x8C ${BOLD}mcp:${RESET}${C_YELLOW}${mcp_str}${RESET}"
  fi

  [ -n "$line3" ] && printf "%b\n" "$line3"
fi

# ── LINE 5 — rate limits ──────────────────────────────────────────────────────
line4=""

# 5-hour limit
if [ -n "$five_pct" ]; then
  five_fmt=$(printf "%.0f%%" "$five_pct")
  five_int=$(printf "%.0f" "$five_pct")
  lim_color="$C_MAGENTA"
  [ "$five_int" -ge 90 ] && lim_color="$C_RED"
  [ "$five_int" -ge 70 ] && [ "$five_int" -lt 90 ] && lim_color="$C_YELLOW"

  five_str="${five_fmt}"
  if [ -n "$five_reset" ]; then
    reset_dt=$(date -d "@${five_reset}" "+%H:%M %Z" 2>/dev/null || date -r "${five_reset}" "+%H:%M %Z" 2>/dev/null)
    cdown=$(countdown_str "$five_reset")
    five_str="${five_str} \xE2\x86\xBA${reset_dt} (${cdown})"
  fi
  line4="${lim_color}\xE2\x8F\xB1\xEF\xB8\x8F ${BOLD}5h:${RESET}${lim_color}${five_str}${RESET}"
fi

# 7-day limit
if [ -n "$week_pct" ]; then
  week_fmt=$(printf "%.0f%%" "$week_pct")
  week_int=$(printf "%.0f" "$week_pct")
  wlim_color="$C_BLUE"
  [ "$week_int" -ge 90 ] && wlim_color="$C_RED"
  [ "$week_int" -ge 70 ] && [ "$week_int" -lt 90 ] && wlim_color="$C_YELLOW"

  week_str="${week_fmt}"
  if [ -n "$week_reset" ]; then
    reset_dt=$(date -d "@${week_reset}" "+%a %d %H:%M %Z" 2>/dev/null || date -r "${week_reset}" "+%a %d %H:%M %Z" 2>/dev/null)
    cdown=$(countdown_str "$week_reset")
    week_str="${week_str} \xE2\x86\xBA${reset_dt} (${cdown})"
  fi
  [ -n "$line4" ] && line4="${line4}${SEP}"
  line4="${line4}${wlim_color}\xF0\x9F\x93\x85 ${BOLD}7d:${RESET}${wlim_color}${week_str}${RESET}"
fi

[ -n "$line4" ] && printf "%b\n" "$line4"

