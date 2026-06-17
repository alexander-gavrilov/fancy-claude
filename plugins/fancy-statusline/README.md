# fancy-statusline

A rich 4-line status bar for Claude Code.

## What it shows

```
Line 1  alexander@host:/current/dir
Line 2  🤖 model:sonnet-4-6 ⚖ auto | 📊 ctx:200k | 📈 used:23% | 📉 rem:77%
Line 3  🔧 skills:8 (5.0% ctx) | 🔌 mcp:3 srv / ~60 tools (~12.0% ctx)
Line 4  ⏱️ 5h:43% ↺14:30 EET (1h22m) | 📅 7d:18% ↺Fri 09:00 EET (3d14h)
```

**Line 1** — user@host and current directory  
**Line 2** — model ID, effort level (🐢 low · 🏃 medium · 🚀 high · 🔥 xhigh · ⚡ max · ⚖ auto), context size, used %, remaining %  
**Line 3** — loaded skills with estimated context %, MCP servers with estimated tool count and context %  
**Line 4** — 5-hour and 7-day rate limit usage, local reset time, and countdown  

Colors shift yellow then red as pressure increases (context usage, rate limits).

## Requirements

- `bash` (≥ 4)
- `jq`
- `awk`

## Installation

Add the marketplace and install the plugin:

```bash
claude plugin marketplace add alexander-gavrilov/fancy-claude
claude plugin install fancy-statusline@fancy-claude
```

The status bar is active from the next Claude Code session after installation.

## How it works

A `UserPromptSubmit` hook runs on every prompt. It always copies `statusline-command.sh` to `~/.claude/` to keep the script current with the installed plugin version. It wires `statusLine` in `~/.claude/settings.json` only once (idempotent after that).

## MCP tool count

Tool counts are estimated from plugin source files where available, with known fallbacks for common external servers (github: 52, context7: 4, exa: 3, etc.). The `~` prefix signals an approximation.
