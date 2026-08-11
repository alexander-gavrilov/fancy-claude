#!/bin/bash
# lib/topic-lib.sh — sanitizer and state helpers

sandbox_home
# shellcheck source=../plugins/fancy-statusline/lib/topic-lib.sh
. "$PLUGIN_DIR/lib/topic-lib.sh"

# ── topic_state_path ─────────────────────────────────────────────────────────
assert_eq "state path for a valid id" \
  "$(topic_state_path 'abc-123.def')" "$TOPIC_STATE_DIR/abc-123.def.json"

topic_state_path '../etc/passwd' >/dev/null 2>&1
assert_eq "state path rejects traversal" "$?" "1"

topic_state_path '' >/dev/null 2>&1
assert_eq "state path rejects empty id" "$?" "1"

# ── topic_state_merge / topic_state_read ─────────────────────────────────────
sf=$(topic_state_path 'sess1')

assert_eq "read from a missing file returns the default" \
  "$(topic_state_read "$sf" topic 'none')" "none"

topic_state_merge "$sf" '{"started":111,"restarts":2}'
topic_state_merge "$sf" '{"topic":"first topic","topic_source":"auto"}'
assert_eq "merge keeps pre-existing keys" "$(topic_state_read "$sf" started)" "111"
assert_eq "merge writes new keys"         "$(topic_state_read "$sf" topic)" "first topic"

topic_state_merge "$sf" '{"topic":"second topic"}'
assert_eq "merge overwrites"      "$(topic_state_read "$sf" topic)" "second topic"
assert_eq "merge keeps siblings"  "$(topic_state_read "$sf" topic_source)" "auto"
assert_eq "merge keeps restarts"  "$(topic_state_read "$sf" restarts)" "2"

printf 'not json at all' > "$sf"
topic_state_merge "$sf" '{"topic":"recovered"}'
assert_eq "merge recovers from a corrupt file" "$(topic_state_read "$sf" topic)" "recovered"

# ── topic_sanitize ───────────────────────────────────────────────────────────
assert_eq "plain text passes through" \
  "$(topic_sanitize 'refactor the parser')" "refactor the parser"

assert_eq "only the first line survives" \
  "$(topic_sanitize "$(printf 'first line\nsecond line')")" "first line"

assert_eq "real ANSI is removed" \
  "$(topic_sanitize "$(printf '\033[31mred topic\033[0m')")" "red topic"

assert_eq "literal escape sequences are removed" \
  "$(topic_sanitize '\033[31mred topic')" "red topic"

assert_not_contains "no backslash survives" "$(topic_sanitize 'a \\ b')" '\'

assert_eq "whitespace is collapsed and trimmed" \
  "$(topic_sanitize '   too    many   spaces  ')" "too many spaces"

assert_eq "surrounding quotes are stripped" \
  "$(topic_sanitize '"quoted topic"')" "quoted topic"

FANCY_STATUSLINE_TOPIC_WIDTH=10
assert_eq "long text is truncated with an ellipsis" \
  "$(topic_sanitize 'abcdefghijklmnop')" "abcdefghi…"
assert_eq "text at the limit is left alone" \
  "$(topic_sanitize 'abcdefghij')" "abcdefghij"
unset FANCY_STATUSLINE_TOPIC_WIDTH

assert_eq "a non-numeric width falls back to 60" \
  "$(FANCY_STATUSLINE_TOPIC_WIDTH=abc topic_sanitize 'short')" "short"

assert_eq "empty input yields empty output" "$(topic_sanitize '')" ""

sandbox_cleanup
