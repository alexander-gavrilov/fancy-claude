# fancy-statusline

A rich 5-line status bar for Claude Code.

## What it shows

```
Line 1  alexander@host | 🕒 up:17h50m | ⟳ compacted:09:15 ×2
Line 2  /current/dir
Line 3  🤖 model:sonnet-4-6 ⚖ auto | 📊 ctx:200k | 📈 used:23% | 📉 rem:77%
Line 4  🔧 skills:8 (5.0% ctx) | 🔌 mcp:3 srv / ~60 tools (~12.0% ctx)
Line 5  ⏱️ 5h:43% ↺14:30 EET (1h22m) | 📅 7d:18% ↺Fri 09:00 EET (3d14h)
```

**Line 1** — user@host, session age, and last restart  
**Line 2** — current working directory  
**Line 3** — model ID, effort level (🐢 low · 🏃 medium · 🚀 high · 🔥 xhigh · ⚡ max · ⚖ auto), context size, used %, remaining %  
**Line 4** — loaded skills with estimated context %, MCP servers with estimated tool count and context %  
**Line 5** — 5-hour and 7-day rate limit usage, local reset time, and countdown  

Colors shift yellow then red as pressure increases (context usage, rate limits).

## Session age and restarts

`🕒 up:` is how long this session has existed — not how long since it was last
restarted. A session resumed five minutes ago may have been running since
yesterday, and the two are reported separately:

- `🕒 up:17h50m` — time since the session originally started
- `⟳ compacted:09:15 ×2` — what last interrupted it, when, and how many restarts
  so far. Omitted until the first restart; the `×N` count appears from the second.

Restarts are `--continue` / `--resume` (`resumed`), `/clear` (`cleared`), and
auto-compact (`compacted`). Each also prints a single line into the chat at the
moment it happens, since the status bar cannot show that something *just*
occurred:

```
⟳ Context compacted · 2026-08-05 09:15 · restart #2
   session started 2026-08-04 15:25 (17h 50m ago)
```

Set `FANCY_STATUSLINE_SESSION=off` to disable both the chip and the chat line.

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

A `SessionStart` hook records session state under `~/.claude/fancy-statusline/sessions/<session_id>.json`. The original start time is taken from the birth time of the session transcript, which survives both `/clear` and `--resume` because those keep the same session id and the same file; the state file supplies the event type and restart count, which the transcript cannot. Records older than 30 days are pruned automatically. If the state file is missing or unreadable the status bar falls back to the transcript for session age and simply omits the restart chip.

## MCP tool count

Tool counts are estimated from plugin source files where available, with known fallbacks for common external servers (github: 52, context7: 4, exa: 3, etc.). The `~` prefix signals an approximation.
