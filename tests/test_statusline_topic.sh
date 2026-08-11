#!/bin/bash
# statusline-command.sh — the topic line

sandbox_home
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

# Minimal status-line input. The script tolerates every other field being absent.
sl_input() {
  jq -nc --arg sid "$1" \
    '{session_id:$sid, cwd:"/tmp/proj",
      workspace:{project_dir:"/tmp/proj"},
      model:{id:"claude-opus-5", display_name:"Opus 5"},
      context_window:{context_window_size:200000, used_percentage:10, remaining_percentage:90}}'
}

render() { sl_input "$1" | bash "$PLUGIN_DIR/statusline-command.sh" 2>/dev/null; }

sf="$TOPIC_STATE_DIR/slsess.json"

# no state at all
out=$(render slsess)
assert_not_contains "no topic line without state" "$out" "topic:"
assert_contains     "the rest of the bar still renders" "$out" "/tmp/proj"

# auto topic present
printf '{"topic":"parser refactor","topic_source":"auto"}' > "$sf"
out=$(render slsess)
assert_contains "auto topic is rendered" "$out" "topic:"
assert_contains "auto topic text is rendered" "$out" "parser refactor"

# the topic line comes first
assert_contains "topic is the first line" "$(printf '%s' "$out" | head -n 1)" "parser refactor"

# topic_source=off hides it
printf '{"topic":"parser refactor","topic_source":"off"}' > "$sf"
out=$(render slsess)
assert_not_contains "topic_source=off hides the line" "$out" "parser refactor"

# env override wins over the cache
printf '{"topic":"parser refactor","topic_source":"auto"}' > "$sf"
out=$(FANCY_STATUSLINE_TOPIC="pinned topic" render slsess)
assert_contains     "env override is rendered" "$out" "pinned topic"
assert_not_contains "env override replaces the cache" "$out" "parser refactor"

# env off wins over everything
out=$(FANCY_STATUSLINE_TOPIC=off render slsess)
assert_not_contains "FANCY_STATUSLINE_TOPIC=off hides the line" "$out" "parser refactor"

# a hostile cached topic cannot repaint the terminal
printf '{"topic":"\\\\033[2Jwiped","topic_source":"auto"}' > "$sf"
out=$(render slsess)
assert_not_contains "escaped ANSI from the cache is neutralized" "$out" "[2J"

# an over-long topic is cut down
long=$(printf 'x%.0s' $(seq 1 200))
jq -nc --arg t "$long" '{topic:$t, topic_source:"auto"}' > "$sf"
out=$(FANCY_STATUSLINE_TOPIC_WIDTH=20 render slsess)
assert_contains "an over-long topic is truncated" "$out" "…"

unset CLAUDE_PLUGIN_ROOT
sandbox_cleanup
