#!/bin/bash
# Idempotent install: copies the statusline script to ~/.claude/ and wires settings.json.
# Runs on every UserPromptSubmit but exits fast after first install.

SETTINGS="$HOME/.claude/settings.json"
SCRIPT_SRC="${CLAUDE_PLUGIN_ROOT}/statusline-command.sh"
SCRIPT_DEST="$HOME/.claude/statusline-command.sh"

# Keep script up to date with the installed plugin version
cp "$SCRIPT_SRC" "$SCRIPT_DEST" 2>/dev/null || exit 0
chmod +x "$SCRIPT_DEST"

# The status line sources lib/topic-lib.sh. The copy in ~/.claude/ has no plugin
# root to resolve, so mirror the library next to it and keep it current too.
LIB_SRC="${CLAUDE_PLUGIN_ROOT}/lib/topic-lib.sh"
LIB_DEST_DIR="$HOME/.claude/fancy-statusline/lib"
if [ -f "$LIB_SRC" ]; then
  mkdir -p "$LIB_DEST_DIR" 2>/dev/null && cp "$LIB_SRC" "$LIB_DEST_DIR/topic-lib.sh" 2>/dev/null
fi

# Wire settings.json only if not already pointing at our script
if [ -f "$SETTINGS" ]; then
  if ! jq -e '.statusLine.command' "$SETTINGS" 2>/dev/null | grep -q "statusline-command.sh"; then
    tmp=$(mktemp)
    if jq --arg cmd "bash $SCRIPT_DEST" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        "$SETTINGS" > "$tmp"; then
      mv "$tmp" "$SETTINGS"
    else
      rm -f "$tmp"
    fi
  fi
else
  printf '{"statusLine":{"type":"command","command":"bash %s"}}\n' "$SCRIPT_DEST" > "$SETTINGS"
fi
