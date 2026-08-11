#!/bin/bash
# Background summarizer: turn the tail of a session transcript into a short
# topic and cache it in the session state file.
#
# Spawned detached by hooks/topic.sh as:  topic-worker.sh <session_id> <transcript>
# Never called from the status line — rendering must not depend on a model.
#
# Any failure is silent and leaves the previous topic in place.

session_id="$1"
transcript="$2"

[ -z "$session_id" ] && exit 0
[ -f "$transcript" ] || exit 0

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || exit 0

command -v claude >/dev/null 2>&1 || exit 0

state_file=$(topic_state_path "$session_id") || exit 0
mkdir -p "$(dirname "$state_file")" 2>/dev/null || exit 0

# ── lock ─────────────────────────────────────────────────────────────────────
# One summarizer per session. A lock older than two minutes belonged to a run
# that died without cleaning up, so it is reclaimed.
lock="${state_file}.topic.lock"
if ! mkdir "$lock" 2>/dev/null; then
  stale=$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)
  [ -z "$stale" ] && exit 0
  rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

# ── excerpt ──────────────────────────────────────────────────────────────────
# The last ten plain-text turns. Tool calls, tool results, thinking blocks and
# sidechain agents are bulk without signal about what the session is about.
excerpt=$(jq -rs '
  [ .[]
    | select(type == "object")
    | select(.type == "user" or .type == "assistant")
    | select(.isSidechain != true)
    | select(.isMeta != true)
    | { role: .type,
        text: ( if (.message.content | type) == "string"
                then .message.content
                else [ .message.content[]? | select(.type == "text") | .text ] | join("\n")
                end ) }
    | select(.text != null and .text != "")
    | select(.text | startswith("<system-reminder>") | not)
  ]
  | .[-10:]
  | map("\(.role): \(.text[0:400])")
  | join("\n---\n")
' "$transcript" 2>/dev/null)

[ -z "$excerpt" ] && exit 0

prompt="Below is the tail of a coding session.

Reply with a 3-5 word topic naming what the session is about. Reply with the
topic and nothing else: no quotes, no trailing punctuation, no preamble.

<session>
${excerpt}
</session>"

# ── model call ───────────────────────────────────────────────────────────────
model="${FANCY_STATUSLINE_TOPIC_MODEL:-claude-haiku-4-5-20251001}"

run_claude() {
  # FANCY_STATUSLINE_TOPIC_CHILD stops hooks/topic.sh dead inside the child
  # session this call creates.
  if command -v timeout >/dev/null 2>&1; then
    FANCY_STATUSLINE_TOPIC_CHILD=1 timeout 30 claude -p --model "$model" "$prompt" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    FANCY_STATUSLINE_TOPIC_CHILD=1 gtimeout 30 claude -p --model "$model" "$prompt" 2>/dev/null
  else
    FANCY_STATUSLINE_TOPIC_CHILD=1 claude -p --model "$model" "$prompt" 2>/dev/null
  fi
}

answer=$(run_claude) || exit 0

topic=$(topic_sanitize "$answer")
[ -z "$topic" ] && exit 0

topic_state_merge "$state_file" "$(jq -nc \
  --arg t "$topic" \
  --argjson at "$(date +%s)" \
  '{topic:$t, topic_source:"auto", topic_at:$at}')"

exit 0
