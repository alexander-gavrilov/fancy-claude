#!/bin/bash
# hooks/topic-worker.sh — the background summarizer

sandbox_home

WORK_DIR=$(mktemp -d)
TRANSCRIPT="$WORK_DIR/transcript.jsonl"

# A transcript with the shapes the worker must cope with: string content,
# array content with a text block, a tool-only assistant turn, and a sidechain.
{
  jq -nc '{type:"user",      isSidechain:false, message:{content:"please fix the parser"}}'
  jq -nc '{type:"assistant", isSidechain:false, message:{content:[{type:"text",text:"Looking at the parser now"}]}}'
  jq -nc '{type:"assistant", isSidechain:false, message:{content:[{type:"tool_use",name:"Read",input:{}}]}}'
  jq -nc '{type:"user",      isSidechain:true,  message:{content:"sidechain noise"}}'
} > "$TRANSCRIPT"

run_worker() { bash "$PLUGIN_DIR/hooks/topic-worker.sh" "$1" "$TRANSCRIPT" >/dev/null 2>&1; }

sf="$TOPIC_STATE_DIR/wsess.json"

# happy path
stub_bin claude 'echo "parser bug fix"'
run_worker wsess
assert_eq "the topic is stored"           "$(jq -r '.topic' "$sf")" "parser bug fix"
assert_eq "the source is marked auto"     "$(jq -r '.topic_source' "$sf")" "auto"
assert_contains "topic_at is a timestamp" "$(jq -r '.topic_at | tostring | length' "$sf")" "10"

# the excerpt reaches the model and excludes the noise
stub_bin claude 'printf "%s" "$*" > '"$WORK_DIR"'/seen.txt; echo "captured"'
run_worker wsess
seen=$(cat "$WORK_DIR/seen.txt")
assert_contains     "user text is in the excerpt"      "$seen" "please fix the parser"
assert_contains     "assistant text is in the excerpt" "$seen" "Looking at the parser now"
assert_not_contains "tool calls are excluded"          "$seen" "tool_use"
assert_not_contains "sidechains are excluded"          "$seen" "sidechain noise"

# model output is sanitized
printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
stub_bin claude 'printf "\033[31mred\033[0m topic\n"'
run_worker wsess
assert_eq "model output is sanitized" "$(jq -r '.topic' "$sf")" "red topic"

# Another plugin may decorate the reply itself, not just the stream around it.
# Observed in the wild: a message-timestamp plugin prefixing every reply.
printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
stub_bin claude 'echo "[2026-08-11 12:40:48] decorated topic"'
run_worker wsess
assert_eq "a decorating prefix is stripped" "$(jq -r '.topic' "$sf")" "decorated topic"

printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
stub_bin claude 'echo "[12:40] [info] two prefixes"'
run_worker wsess
assert_eq "several prefixes are stripped" "$(jq -r '.topic' "$sf")" "two prefixes"

printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
stub_bin claude 'echo "brackets [inside] a topic survive"'
run_worker wsess
assert_eq "only leading brackets are stripped" \
  "$(jq -r '.topic' "$sf")" "brackets [inside] a topic survive"

# failures leave the previous topic alone
printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
stub_bin claude 'exit 1'
run_worker wsess
assert_eq "a failing model call preserves the topic" "$(jq -r '.topic' "$sf")" "previous"

stub_bin claude 'echo ""'
run_worker wsess
assert_eq "empty output preserves the topic" "$(jq -r '.topic' "$sf")" "previous"

# a held lock suppresses a second run
stub_bin claude 'echo "should not land"'
mkdir -p "${sf}.topic.lock"
run_worker wsess
assert_eq "a held lock suppresses the run" "$(jq -r '.topic' "$sf")" "previous"
rmdir "${sf}.topic.lock"

# a stale lock is reclaimed
mkdir -p "${sf}.topic.lock"
touch -t 197001010000 "${sf}.topic.lock" 2>/dev/null || true
stub_bin claude 'echo "after stale lock"'
run_worker wsess
assert_eq "a stale lock is reclaimed" "$(jq -r '.topic' "$sf")" "after stale lock"
assert_file_missing "the lock is released" "${sf}.topic.lock"

# a missing transcript is survivable
printf '{"topic":"previous","topic_source":"auto"}' > "$sf"
bash "$PLUGIN_DIR/hooks/topic-worker.sh" wsess "$WORK_DIR/nope.jsonl" >/dev/null 2>&1
assert_eq "a missing transcript preserves the topic" "$(jq -r '.topic' "$sf")" "previous"

stub_cleanup
rm -rf "$WORK_DIR"
sandbox_cleanup
