#!/bin/bash
# UserPromptSubmit hook: count prompts and decide when the session topic should
# be recomputed. It never talks to a model itself — it spawns the worker
# detached and returns, so a prompt is never delayed by a summary.
#
# Disable with FANCY_STATUSLINE_TOPIC=off.

# Recursion guard. topic-worker.sh runs `claude -p`, which is itself a Claude
# Code session and fires this hook again. Without this line, one prompt would
# spawn summarizers without end.
[ -n "${FANCY_STATUSLINE_TOPIC_CHILD:-}" ] && exit 0

# Any value pins or disables the topic, and a computed one would never be shown.
[ -n "${FANCY_STATUSLINE_TOPIC:-}" ] && exit 0

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || exit 0

input=$(cat)

session_id=$(printf '%s' "$input"  | jq -r '.session_id      // empty' 2>/dev/null)
transcript=$(printf '%s' "$input"  | jq -r '.transcript_path // empty' 2>/dev/null)

state_file=$(topic_state_path "$session_id") || exit 0

every="${FANCY_STATUSLINE_TOPIC_EVERY:-5}"
case "$every" in ''|*[!0-9]*) every=5 ;; esac
[ "$every" -lt 1 ] && every=1

prompts=$(topic_state_read      "$state_file" prompts 0)
at_prompt=$(topic_state_read    "$state_file" topic_at_prompt 0)
source_kind=$(topic_state_read  "$state_file" topic_source auto)
case "$prompts"   in ''|*[!0-9]*) prompts=0   ;; esac
case "$at_prompt" in ''|*[!0-9]*) at_prompt=0 ;; esac

prompts=$(( prompts + 1 ))

# A pinned or disabled topic still counts prompts, so that clearing the pin
# later resumes from an honest number.
if [ "$source_kind" = "manual" ] || [ "$source_kind" = "off" ]; then
  topic_state_merge "$state_file" "$(jq -nc --argjson p "$prompts" '{prompts:$p}')"
  exit 0
fi

recompute=0
if [ "$prompts" -eq 1 ] || [ $(( prompts - at_prompt )) -ge "$every" ]; then
  recompute=1
fi

if [ "$recompute" -eq 0 ]; then
  topic_state_merge "$state_file" "$(jq -nc --argjson p "$prompts" '{prompts:$p}')"
  exit 0
fi

topic_state_merge "$state_file" \
  "$(jq -nc --argjson p "$prompts" '{prompts:$p, topic_at_prompt:$p}')"

worker="${FANCY_STATUSLINE_TOPIC_WORKER:-$HOOK_DIR/topic-worker.sh}"
[ -x "$worker" ] || [ -f "$worker" ] || exit 0

# Detached: the hook must not wait for the model, and the worker must survive
# this process exiting.
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$worker" "$session_id" "$transcript" >/dev/null 2>&1 &
else
  nohup bash "$worker" "$session_id" "$transcript" >/dev/null 2>&1 &
fi
disown 2>/dev/null

exit 0
