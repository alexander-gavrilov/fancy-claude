#!/bin/bash
# Backend for the /topic command.
#
#   topic-set.sh <text>   pin a manual topic for this session
#   topic-set.sh          drop the pin and let the summarizer take over again
#   topic-set.sh off      hide the topic line and stop summarizing
#
# Prints a one-line confirmation for the model to relay to the user.

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || {
  printf 'fancy-statusline: topic library not found\n'
  exit 1
}

# ── which session are we in ──────────────────────────────────────────────────
# The transcript being written right now belongs to the active session, so the
# newest .jsonl for this directory is the answer when the id is not exported.
resolve_session() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_SESSION_ID"
    return 0
  fi
  local slug proj newest
  slug=$(pwd | tr '/.' '--')
  proj="$HOME/.claude/projects/$slug"
  [ -d "$proj" ] || return 1
  newest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -n 1)
  [ -z "$newest" ] && return 1
  newest=$(basename "$newest" .jsonl)
  printf '%s' "$newest"
}

session_id=$(resolve_session) || {
  printf 'fancy-statusline: could not determine the current session\n'
  exit 1
}

state_file=$(topic_state_path "$session_id") || {
  printf 'fancy-statusline: could not determine the current session\n'
  exit 1
}

arg="$*"

case "$arg" in
  off)
    topic_state_merge "$state_file" '{"topic":null,"topic_source":"off"}'
    printf 'Topic line turned off for this session.\n'
    ;;
  '')
    # Rewinding topic_at_prompt makes the next prompt recompute immediately
    # rather than waiting out the remainder of the interval.
    topic_state_merge "$state_file" '{"topic":null,"topic_source":"auto","topic_at_prompt":0}'
    printf 'Topic reset to auto; it will be recomputed on the next prompt.\n'
    ;;
  *)
    topic=$(topic_sanitize "$arg")
    if [ -z "$topic" ]; then
      printf 'fancy-statusline: that topic is empty after sanitization\n'
      exit 1
    fi
    topic_state_merge "$state_file" "$(jq -nc \
      --arg t "$topic" \
      --argjson at "$(date +%s)" \
      '{topic:$t, topic_source:"manual", topic_at:$at}')"
    printf 'Topic pinned: %s\n' "$topic"
    ;;
esac

exit 0
