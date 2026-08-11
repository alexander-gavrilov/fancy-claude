#!/bin/bash
# Shared helpers for the session-topic feature: where session state lives, how
# to update it without racing, and how to make a topic string safe to print.
#
# Sourced by the status line and by the topic hooks. Defines functions only —
# sourcing it must have no side effects.

TOPIC_STATE_DIR="${TOPIC_STATE_DIR:-$HOME/.claude/fancy-statusline/sessions}"

# topic_state_path <session_id>
# The session id becomes a filename, so refuse anything that is not a plain id.
topic_state_path() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/%s.json' "$TOPIC_STATE_DIR" "$1"
}

# topic_state_read <file> <key> [default]
topic_state_read() {
  local file="$1" key="$2" def="${3:-}" val=""
  if [ -f "$file" ]; then
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)
  fi
  [ -z "$val" ] && val="$def"
  printf '%s' "$val"
}

# topic_state_merge <file> <json_object>
# The prompt hook writes counters while the worker writes the topic, so writes
# are serialized with a directory lock. A failed jq leaves the old file intact.
topic_state_merge() {
  local file="$1" frag="$2" tries=0 base tmp
  local lock="${file}.lock"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$(( tries + 1 ))
    [ "$tries" -gt 50 ] && return 1
    sleep 0.02
  done
  base='{}'
  if [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
    base=$(cat "$file")
  fi
  tmp=$(mktemp) || { rmdir "$lock" 2>/dev/null; return 1; }
  if printf '%s' "$base" | jq --argjson frag "$frag" '. * $frag' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    rmdir "$lock" 2>/dev/null
    return 0
  fi
  rm -f "$tmp"
  rmdir "$lock" 2>/dev/null
  return 1
}

# topic_sanitize <text>
# Topic text reaches a terminal, and its ultimate source is model output over
# arbitrary transcript content. Strip anything that could move the cursor or
# repaint the screen, in both real and backslash-escaped form — the status line
# assembles strings that pass through printf %b, which would interpret the
# literal form.
topic_sanitize() {
  local raw="$1" width="${FANCY_STATUSLINE_TOPIC_WIDTH:-60}" out
  case "$width" in ''|*[!0-9]*) width=60 ;; esac
  [ "$width" -lt 8 ] && width=8

  out=$(printf '%s' "$raw" | head -n 1)
  # literal "\033[…m", "\x1b[…m", "\e[…m"
  out=$(printf '%s' "$out" | sed -E 's/\\+(033|x1[bB]|e)\[[0-9;]*[a-zA-Z]//g')
  # real ESC-introduced CSI sequences
  out=$(printf '%s' "$out" | LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')
  out=$(printf '%s' "$out" | tr -d '\\')
  out=$(printf '%s' "$out" | LC_ALL=C tr -d '\000-\037\177')
  out=$(printf '%s' "$out" | tr -s '[:space:]' ' ')
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  out="${out#\"}"; out="${out%\"}"
  out="${out#\'}"; out="${out%\'}"

  if [ "${#out}" -gt "$width" ]; then
    out="$(printf '%s' "$out" | cut -c "1-$(( width - 1 ))")…"
  fi
  printf '%s' "$out"
}
