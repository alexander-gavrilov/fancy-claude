#!/bin/bash
# hooks/topic-set.sh — the /topic command backend

sandbox_home

set_topic() { bash "$PLUGIN_DIR/hooks/topic-set.sh" "$@" 2>&1; }

export CLAUDE_SESSION_ID=setsess
sf="$TOPIC_STATE_DIR/setsess.json"
printf '{"topic":"auto topic","topic_source":"auto","prompts":4,"topic_at_prompt":1}' > "$sf"

out=$(set_topic "my pinned topic")
assert_eq "the manual topic is stored"     "$(jq -r '.topic' "$sf")" "my pinned topic"
assert_eq "the source becomes manual"      "$(jq -r '.topic_source' "$sf")" "manual"
assert_contains "it confirms on stdout"    "$out" "my pinned topic"
assert_eq "the prompt count is preserved"  "$(jq -r '.prompts' "$sf")" "4"

out=$(set_topic)
assert_eq "no argument returns to auto"    "$(jq -r '.topic_source' "$sf")" "auto"
assert_eq "no argument clears the topic"   "$(jq -r '.topic' "$sf")" "null"
assert_contains "it confirms the reset"    "$out" "auto"

# clearing forces the next prompt to recompute
assert_eq "topic_at_prompt is rewound" "$(jq -r '.topic_at_prompt' "$sf")" "0"

out=$(set_topic off)
assert_eq "off disables the line"  "$(jq -r '.topic_source' "$sf")" "off"
assert_contains "it confirms off"  "$out" "off"

# a hostile argument is sanitized before storage
set_topic '\033[2J wiped' >/dev/null
assert_not_contains "the manual topic is sanitized" "$(jq -r '.topic' "$sf")" "["

# multi-word arguments arrive intact
set_topic three word topic >/dev/null
assert_eq "multiple arguments are joined" "$(jq -r '.topic' "$sf")" "three word topic"

# without a resolvable session it fails loudly instead of writing junk
unset CLAUDE_SESSION_ID
mkdir -p "$HOME/.claude/projects"
out=$(cd "$HOME" && bash "$PLUGIN_DIR/hooks/topic-set.sh" "orphan" 2>&1)
rc=$?
assert_eq "an unresolvable session exits non-zero" "$rc" "1"
assert_contains "it explains why" "$out" "session"

# the transcript fallback resolves the newest jsonl for this directory
proj_dir="$HOME/.claude/projects/-tmp-fallback"
mkdir -p "$proj_dir"
touch "$proj_dir/old-session.jsonl"
sleep 1
touch "$proj_dir/new-session.jsonl"
mkdir -p /tmp/fallback
(cd /tmp/fallback && bash "$PLUGIN_DIR/hooks/topic-set.sh" "fallback topic" >/dev/null 2>&1)
assert_eq "the newest transcript wins" \
  "$(jq -r '.topic' "$TOPIC_STATE_DIR/new-session.json" 2>/dev/null)" "fallback topic"

sandbox_cleanup
