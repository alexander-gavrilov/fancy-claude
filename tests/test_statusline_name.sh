#!/bin/bash
# statusline-command.sh — the session name chip on the topic line

sandbox_home
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

SESS_DIR="$HOME/.claude/sessions"
mkdir -p "$SESS_DIR"

# Minimal status-line input, as Claude Code pipes it in.
name_input() {
  jq -nc --arg sid "$1" \
    '{session_id:$sid, cwd:"/tmp/proj",
      workspace:{project_dir:"/tmp/proj"},
      model:{id:"claude-opus-5", display_name:"Opus 5"},
      context_window:{context_window_size:200000, used_percentage:10, remaining_percentage:90}}'
}

name_render() { name_input "$1" | bash "$PLUGIN_DIR/statusline-command.sh" 2>/dev/null; }

# name_entry <pid> <session_id> <name> <updated_at>
name_entry() {
  jq -nc --argjson pid "$1" --arg sid "$2" --arg n "$3" --argjson up "$4" \
    '{pid:$pid, sessionId:$sid, cwd:"/tmp/proj", name:$n,
      nameSource:"derived", kind:"interactive", status:"idle", updatedAt:$up}' \
    > "$SESS_DIR/$1.json"
}

sid="6ba9f8b9-069a-486e-b504-38940effb2e8"
first_line() { printf '%s' "$1" | head -n 1; }

# ── the chip itself ──────────────────────────────────────────────────────────
name_entry "$$" "$sid" "fancy-claude-98" 1000
out=$(name_render "$sid")
assert_contains "the addressable name is rendered" "$(first_line "$out")" "@fancy-claude-98"
assert_contains "the short ref rides along"        "$(first_line "$out")" "[6ba9f8b9]"

# with no topic the chip stands alone on line 0
assert_not_contains "no topic means no topic label" "$(first_line "$out")" "topic:"
assert_contains     "the rest of the bar still renders" "$out" "/tmp/proj"

# ── ordering against the topic ───────────────────────────────────────────────
printf '{"topic":"parser refactor","topic_source":"auto"}' > "$TOPIC_STATE_DIR/${sid}.json"
out=$(name_render "$sid")
line0=$(first_line "$out")
assert_contains "name and topic share line 0" "$line0" "parser refactor"
case "$line0" in
  *"@fancy-claude-98"*"parser refactor"*) order=before ;;
  *)                                      order=after  ;;
esac
assert_eq "the name chip precedes the topic" "$order" "before"
rm -f "$TOPIC_STATE_DIR/${sid}.json"

# ── choosing among duplicate registry entries ────────────────────────────────
# A resume leaves the old entry behind: a dead pid must lose to a live one even
# when its updatedAt is newer.
name_entry 2147483647 "$sid" "stale-name-01" 9999
out=$(name_render "$sid")
assert_contains     "a live entry wins over a dead one" "$out" "@fancy-claude-98"
assert_not_contains "the dead entry is ignored"         "$out" "stale-name-01"
rm -f "$SESS_DIR/2147483647.json"

# Two live entries: the freshest updatedAt wins.
name_entry "$PPID" "$sid" "fresher-name-02" 5000
out=$(name_render "$sid")
assert_contains     "the freshest live entry wins" "$out" "@fresher-name-02"
assert_not_contains "the older live entry loses"   "$out" "@fancy-claude-98"
rm -f "$SESS_DIR/$PPID.json"

# ── absent registry entry ───────────────────────────────────────────────────
out=$(name_render "no-such-session-id")
assert_contains "an unknown session gets no chip" "$(first_line "$out")" "$(hostname -s)"
assert_contains     "the bar renders without a chip"  "$out" "/tmp/proj"

# ── opt-out ─────────────────────────────────────────────────────────────────
out=$(FANCY_STATUSLINE_NAME=off name_render "$sid")
assert_not_contains "FANCY_STATUSLINE_NAME=off hides the chip" "$out" "fancy-claude-98"

# with the chip off and a topic present, line 0 is the topic alone
printf '{"topic":"parser refactor","topic_source":"auto"}' > "$TOPIC_STATE_DIR/${sid}.json"
out=$(FANCY_STATUSLINE_NAME=off name_render "$sid")
assert_contains     "the topic line survives the opt-out" "$(first_line "$out")" "parser refactor"
assert_not_contains "the opt-out leaves no separator"     "$(first_line "$out")" "|"
rm -f "$TOPIC_STATE_DIR/${sid}.json"

# ── a hostile registry name cannot repaint the terminal ──────────────────────
name_entry "$$" "$sid" 'evil\033[2Jwiped' 1000
out=$(name_render "$sid")
assert_not_contains "escape sequences are stripped from the name" "$out" "[2J"
assert_contains     "the safe characters survive"                 "$out" "wiped"
rm -f "$SESS_DIR/$$.json"

unset CLAUDE_PLUGIN_ROOT
sandbox_cleanup
