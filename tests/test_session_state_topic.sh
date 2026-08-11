#!/bin/bash
# hooks/session-state.sh — topic fields across restarts

sandbox_home

WORK_DIR=$(mktemp -d)
TRANSCRIPT="$WORK_DIR/transcript.jsonl"
printf '{}\n' > "$TRANSCRIPT"

session_start() {
  jq -nc --arg src "$1" --arg sid "$2" --arg tr "$TRANSCRIPT" \
    '{source:$src, session_id:$sid, transcript_path:$tr}' \
    | bash "$PLUGIN_DIR/hooks/session-state.sh" >/dev/null 2>&1
}

seed() {
  printf '{"session_id":"%s","started":1000,"restarts":1,"topic":"kept topic","topic_source":"manual","topic_at":1234567890,"prompts":7,"topic_at_prompt":5}' \
    "$1" > "$TOPIC_STATE_DIR/$1.json"
}

# resume keeps everything
seed rsess
session_start resume rsess
sf="$TOPIC_STATE_DIR/rsess.json"
assert_eq "resume keeps the topic"        "$(jq -r '.topic' "$sf")" "kept topic"
assert_eq "resume keeps the source"       "$(jq -r '.topic_source' "$sf")" "manual"
assert_eq "resume keeps the prompt count" "$(jq -r '.prompts' "$sf")" "7"
assert_eq "resume still counts restarts"  "$(jq -r '.restarts' "$sf")" "2"

# startup keeps everything too
seed usess
session_start startup usess
assert_eq "startup keeps the topic" "$(jq -r '.topic' "$TOPIC_STATE_DIR/usess.json")" "kept topic"

# clear wipes the topic
seed csess
session_start clear csess
sf="$TOPIC_STATE_DIR/csess.json"
assert_eq "clear drops the topic"          "$(jq -r '.topic' "$sf")" "null"
assert_eq "clear returns to auto"          "$(jq -r '.topic_source' "$sf")" "auto"
assert_eq "clear resets the prompt count"  "$(jq -r '.prompts' "$sf")" "0"
assert_eq "clear rewinds topic_at_prompt"  "$(jq -r '.topic_at_prompt' "$sf")" "0"
assert_eq "clear preserves the start time" "$(jq -r '.started' "$sf")" "1000"

# compact wipes it as well
seed psess
session_start compact psess
assert_eq "compact drops the topic" "$(jq -r '.topic' "$TOPIC_STATE_DIR/psess.json")" "null"

rm -rf "$WORK_DIR"
sandbox_cleanup
