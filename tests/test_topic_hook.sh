#!/bin/bash
# hooks/topic.sh — when the summarizer is triggered

sandbox_home

WORK_DIR=$(mktemp -d)
export FANCY_STATUSLINE_TOPIC_WORKER="$WORK_DIR/worker.sh"
cat > "$FANCY_STATUSLINE_TOPIC_WORKER" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$(dirname "$0")/fired.log"
STUB
chmod +x "$FANCY_STATUSLINE_TOPIC_WORKER"

fired_count() { [ -f "$WORK_DIR/fired.log" ] && wc -l < "$WORK_DIR/fired.log" | tr -d ' ' || echo 0; }
reset_fired() { rm -f "$WORK_DIR/fired.log"; }

prompt() {
  jq -nc --arg sid "$1" --arg tr "$WORK_DIR/transcript.jsonl" \
    '{session_id:$sid, transcript_path:$tr, prompt:"hello"}' \
    | bash "$PLUGIN_DIR/hooks/topic.sh" >/dev/null 2>&1
  # the worker is spawned detached; give it a moment to touch the log
  sleep 0.3
}

sf="$TOPIC_STATE_DIR/hooksess.json"

# first prompt fires immediately
prompt hooksess
assert_eq "fires on the first prompt" "$(fired_count)" "1"
assert_eq "prompts is counted"        "$(jq -r '.prompts' "$sf")" "1"
assert_eq "topic_at_prompt is stamped" "$(jq -r '.topic_at_prompt' "$sf")" "1"

# prompts 2..5 stay quiet with the default N=5
reset_fired
for _ in 2 3 4 5; do prompt hooksess; done
assert_eq "quiet on prompts 2 through 5" "$(fired_count)" "0"
assert_eq "prompts keeps counting"       "$(jq -r '.prompts' "$sf")" "5"

# prompt 6 is five past the last recompute
prompt hooksess
assert_eq "fires again on prompt 6" "$(fired_count)" "1"

# N is configurable
reset_fired
rm -f "$sf"
FANCY_STATUSLINE_TOPIC_EVERY=2 prompt evsess
sf2="$TOPIC_STATE_DIR/evsess.json"
reset_fired
FANCY_STATUSLINE_TOPIC_EVERY=2 prompt evsess
assert_eq "N=2 stays quiet on prompt 2" "$(fired_count)" "0"
FANCY_STATUSLINE_TOPIC_EVERY=2 prompt evsess
assert_eq "N=2 fires on prompt 3" "$(fired_count)" "1"

# manual and off suppress the worker
reset_fired
printf '{"topic":"pinned","topic_source":"manual","prompts":9,"topic_at_prompt":1}' > "$TOPIC_STATE_DIR/mansess.json"
prompt mansess
assert_eq "manual suppresses the worker" "$(fired_count)" "0"
assert_eq "manual still counts prompts"  "$(jq -r '.prompts' "$TOPIC_STATE_DIR/mansess.json")" "10"

reset_fired
printf '{"topic_source":"off","prompts":9,"topic_at_prompt":1}' > "$TOPIC_STATE_DIR/offsess.json"
prompt offsess
assert_eq "topic_source=off suppresses the worker" "$(fired_count)" "0"

# the recursion guard
reset_fired
rm -f "$TOPIC_STATE_DIR/childsess.json"
FANCY_STATUSLINE_TOPIC_CHILD=1 prompt childsess
assert_eq "the child guard suppresses the worker" "$(fired_count)" "0"
assert_file_missing "the child guard writes no state" "$TOPIC_STATE_DIR/childsess.json"

# the env override suppresses the worker
reset_fired
rm -f "$TOPIC_STATE_DIR/envsess.json"
FANCY_STATUSLINE_TOPIC="pinned by env" prompt envsess
assert_eq "the env override suppresses the worker" "$(fired_count)" "0"

reset_fired
rm -f "$TOPIC_STATE_DIR/offenvsess.json"
FANCY_STATUSLINE_TOPIC=off prompt offenvsess
assert_eq "FANCY_STATUSLINE_TOPIC=off suppresses the worker" "$(fired_count)" "0"

# a malformed session id is ignored without a crash
reset_fired
prompt '../evil'
assert_eq "a malformed session id fires nothing" "$(fired_count)" "0"

rm -rf "$WORK_DIR"
unset FANCY_STATUSLINE_TOPIC_WORKER
sandbox_cleanup
