#!/bin/bash
# SessionStart hook: track when a session originally started and when it was
# last restarted, so the status bar can show both.
#
# Records state under ~/.claude/fancy-statusline/sessions/<session_id>.json and,
# on a restart (resume / clear / compact), prints a one-line notice into the
# chat. A cold `startup` only seeds the state file — there is nothing to report.
#
# Disable with FANCY_STATUSLINE_SESSION=off.

[ "$FANCY_STATUSLINE_SESSION" = "off" ] && exit 0

input=$(cat)

source=$(printf '%s' "$input" | jq -r '.source          // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id     // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# session_id becomes a filename — refuse anything that is not a plain id
case "$session_id" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

state_dir="$HOME/.claude/fancy-statusline/sessions"
state_file="$state_dir/${session_id}.json"
mkdir -p "$state_dir" 2>/dev/null || exit 0

now_epoch=$(date +%s)

# Original start time = birth time of the transcript jsonl. Both /clear and
# --resume keep the same session id and the same file, so this survives a
# restart without any bookkeeping of our own. Degrade to mtime, then to now.
started_epoch=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  started_epoch=$(stat -f %B "$transcript" 2>/dev/null || stat -c %W "$transcript" 2>/dev/null)
  case "$started_epoch" in
    ''|0|-1) started_epoch=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null) ;;
  esac
fi

# Anything already on record wins over a fallback guess
prev_started=""
restarts=0
if [ -f "$state_file" ]; then
  prev_started=$(jq -r '.started  // empty' "$state_file" 2>/dev/null)
  restarts=$(jq -r     '.restarts // 0'     "$state_file" 2>/dev/null)
fi
case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac
[ -n "$prev_started" ] && started_epoch="$prev_started"
[ -z "$started_epoch" ] && started_epoch="$now_epoch"

case "$source" in
  resume)  label="Session resumed"   ;;
  clear)   label="Context cleared"   ;;
  compact) label="Context compacted" ;;
  *)       label="" ;;
esac

last_event=""
last_event_at=""
if [ -n "$label" ]; then
  restarts=$(( restarts + 1 ))
  last_event="$source"
  last_event_at="$now_epoch"
elif [ -f "$state_file" ]; then
  last_event=$(jq -r    '.last_event    // empty' "$state_file" 2>/dev/null)
  last_event_at=$(jq -r '.last_event_at // empty' "$state_file" 2>/dev/null)
fi

# The worker and the prompt hook write topic fields into the same file, and the
# jq -n below rewrites it wholesale — so carry them across. A restart that ends
# the conversation (clear, compact) ends the topic with it; a resume does not.
topic=$(jq -r        '.topic          // empty' "$state_file" 2>/dev/null)
topic_source=$(jq -r '.topic_source   // empty' "$state_file" 2>/dev/null)
topic_at=$(jq -r     '.topic_at       // empty' "$state_file" 2>/dev/null)
prompts=$(jq -r      '.prompts        // 0'     "$state_file" 2>/dev/null)
topic_at_prompt=$(jq -r '.topic_at_prompt // 0' "$state_file" 2>/dev/null)
case "$prompts"         in ''|*[!0-9]*) prompts=0         ;; esac
case "$topic_at_prompt" in ''|*[!0-9]*) topic_at_prompt=0 ;; esac
case "$topic_at"        in ''|*[!0-9]*) topic_at=""       ;; esac

case "$source" in
  clear|compact)
    topic=""
    topic_source="auto"
    topic_at=""
    prompts=0
    topic_at_prompt=0
    ;;
esac

tmp=$(mktemp) || exit 0
if jq -n \
    --arg  sid   "$session_id" \
    --argjson st "$started_epoch" \
    --arg  ev    "$last_event" \
    --arg  evat  "$last_event_at" \
    --argjson n  "$restarts" \
    --arg  tp    "$topic" \
    --arg  tsrc  "$topic_source" \
    --arg  tat   "$topic_at" \
    --argjson pc "$prompts" \
    --argjson ta "$topic_at_prompt" \
    '{
       session_id:      $sid,
       started:         $st,
       last_event:      (if $ev   == "" then null else $ev             end),
       last_event_at:   (if $evat == "" then null else ($evat|tonumber) end),
       restarts:        $n,
       topic:           (if $tp   == "" then null else $tp             end),
       topic_source:    (if $tsrc == "" then "auto" else $tsrc         end),
       topic_at:        (if $tat  == "" then null else ($tat|tonumber)  end),
       prompts:         $pc,
       topic_at_prompt: $ta
     }' \
    > "$tmp" 2>/dev/null; then
  mv "$tmp" "$state_file"
else
  rm -f "$tmp"
fi

# Keep the directory from growing without bound
find "$state_dir" -type f -name '*.json' -mtime +30 -delete 2>/dev/null

[ -z "$label" ] && exit 0

fmt() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null; }

elapsed=$(( now_epoch - started_epoch ))
[ "$elapsed" -lt 0 ] && elapsed=0
days=$((  elapsed / 86400 ))
hours=$(( elapsed % 86400 / 3600 ))
mins=$((  elapsed % 3600 / 60 ))
if   [ "$days"  -gt 0 ]; then ago="${days}d ${hours}h"
elif [ "$hours" -gt 0 ]; then ago="${hours}h ${mins}m"
else                          ago="${mins}m"
fi

count=""
[ "$restarts" -gt 1 ] && count=" · restart #${restarts}"

msg=$(printf '⟳ %s · %s%s\n   session started %s (%s ago)' \
  "$label" "$(fmt "$now_epoch")" "$count" "$(fmt "$started_epoch")" "$ago")

jq -n --arg m "$msg" '{systemMessage: $m}'
