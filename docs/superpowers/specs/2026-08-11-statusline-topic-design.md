# Session topic in the status bar

**Date:** 2026-08-11
**Plugin:** `plugins/fancy-statusline`
**Status:** approved, ready for planning

## Problem

The status bar shows what the session *is* (model, context, limits) but never what it is *about*.
With several terminals open, the only way to tell sessions apart is the working directory — which
is identical for two sessions on the same repo. We want a short human-readable topic rendered
immediately above the input box.

Claude Code does not expose a session title. The status-line JSON has no such field, and
transcripts contain no `type:"summary"` records until a compaction happens. The topic must
therefore be derived by the plugin itself.

## Solution overview

A background summarizer produces a 3–5 word topic with Haiku, caches it in the existing
per-session state file, and the status line renders the cached value. Rendering never calls an
LLM and never blocks.

Precedence, highest first:

1. `FANCY_STATUSLINE_TOPIC` environment variable
2. manual override set by `/topic <text>`
3. auto topic from the summarizer
4. nothing — the line is omitted entirely

## State

Extends `~/.claude/fancy-statusline/sessions/<session_id>.json`, already written by
`hooks/session-state.sh`. New fields:

| field             | type            | meaning                                            |
|-------------------|-----------------|----------------------------------------------------|
| `topic`           | string \| null  | current topic text, already sanitized              |
| `topic_source`    | `auto`\|`manual`\|`off` | who set it; `manual` and `off` block the summarizer |
| `topic_at`        | epoch \| null   | when the topic was last written                    |
| `prompts`         | int             | user prompts seen in this session                  |
| `topic_at_prompt` | int             | value of `prompts` at the last auto recompute      |

Existing fields (`started`, `last_event`, `last_event_at`, `restarts`) are untouched. All writes
go through a temp file plus `mv`, matching the current code, so a half-written file is never read.

## Components

### 1. `hooks/topic.sh` — new `UserPromptSubmit` hook

Runs on every prompt, must stay far below the 5 s hook timeout.

- Exit immediately when `FANCY_STATUSLINE_TOPIC_CHILD` is set (see *Recursion* below).
- Exit immediately when `FANCY_STATUSLINE_TOPIC` is set to anything at all — the variable either
  disables the feature or pins a fixed topic, and in both cases a summary would never be shown.
- Increment `prompts` in the state file.
- Skip when `topic_source` is `manual` or `off`.
- Trigger a recompute when `prompts == 1` (topic appears right after the first prompt) or
  `prompts - topic_at_prompt >= N`, where N is `FANCY_STATUSLINE_TOPIC_EVERY`, default `5`.
- A recompute means spawning `topic-worker.sh` **detached** (`setsid`/`nohup … &`, stdout and
  stderr to `/dev/null`) and returning at once. The hook itself never waits for the model.

### 2. `hooks/topic-worker.sh` — background summarizer

- Takes a lock with `mkdir "$state_dir/<session_id>.topic.lock"`. If the lock exists and is
  younger than 120 s, exit; if older, treat it as stale, reclaim it. The lock is removed on exit
  via `trap`.
- Reads the transcript JSONL and extracts the last ~10 user/assistant **text** turns. Tool calls,
  tool results, thinking blocks, and hook attachments are dropped — they are bulky and say little
  about the topic. Each turn is truncated so the whole prompt stays roughly under 4 000 characters.
- Calls `claude -p --model claude-haiku-4-5-20251001` with the excerpt and an instruction to
  answer with a 3–5 word topic and nothing else. The call is wrapped in a timeout (default 30 s).
- Sanitizes the answer (see below) and writes `topic`, `topic_source: "auto"`, `topic_at`, and
  `topic_at_prompt` into the state file.
- Any failure — `claude` missing from `PATH`, non-zero exit, timeout, empty answer — leaves the
  previous state untouched and exits 0.

The worker sets `FANCY_STATUSLINE_TOPIC_CHILD=1` in the environment of the `claude -p` call.

### 3. `statusline-command.sh` — rendering

A new first line, above `user@host`:

```
🏷️  topic: statusline topic chip design
a.haurylau@mbp | 🕒 up:1h04m
/Users/…/projects/fancy-claude
🤖 model:opus-5 🚀 high | 📊 ctx:200k | 📈 used:34%
⏱️  5h:12% | 📅 7d:41%
```

Resolution order is the precedence list above. The line is omitted when the resolved topic is
empty — no placeholder, no layout jitter while the first summary is still running. Rendering only
reads the state file; it never spawns anything.

### 4. `commands/topic.md` — `/topic` slash command

- `/topic <text>` — set `topic` to `<text>`, `topic_source: "manual"`. Pinned for the rest of the
  session; the summarizer stops touching it.
- `/topic` — clear the override, `topic_source: "auto"`, and force a recompute on the next prompt.
- `/topic off` — `topic_source: "off"`, hide the line and stop summarizing for this session.

The command body invokes `hooks/topic-set.sh "$ARGUMENTS"`. That script resolves the session id
from `CLAUDE_SESSION_ID` when present, otherwise from the most recently modified `.jsonl` in the
current project's transcript directory — the active session is the one being written to right now.

## Sanitization

The topic originates from model output over arbitrary transcript content and is interpolated into
`printf "%b"` strings in the status line. The same sanitizer runs on every source: the worker
applies it before storing an auto topic, `topic-set.sh` before storing a manual one, and the
status line applies it to `FANCY_STATUSLINE_TOPIC`, which is never stored. A topic must be:

- reduced to its first line;
- stripped of real ESC bytes **and** of literal backslash escape sequences (`\033`, `\x1b`, `\e`),
  because `%b` would interpret the literal form and let a topic repaint the terminal;
- stripped of other control characters, with runs of whitespace collapsed to single spaces;
- truncated to `FANCY_STATUSLINE_TOPIC_WIDTH` characters, default `60`, with a `…` suffix when cut.

## Recursion

`claude -p` is itself a Claude Code run and fires `UserPromptSubmit`, which would spawn another
summarizer, and so on. This is the single largest risk in the feature. Two independent guards:

1. The worker exports `FANCY_STATUSLINE_TOPIC_CHILD=1`, and `topic.sh` exits on its first line
   when that variable is set.
2. The per-session lock means even a leaked child cannot start a second concurrent worker.

## Session lifecycle

`hooks/session-state.sh` already detects `resume`, `clear`, and `compact`. On `clear` and
`compact` it additionally resets `topic`, `prompts`, and `topic_at_prompt` — the conversation
starts over, so the topic should too. A `manual` override survives `resume` but is cleared by
`clear`, since `/clear` ends the subject the user pinned. On `resume` nothing is reset.

## Configuration

| variable                          | default | effect                                       |
|-----------------------------------|---------|----------------------------------------------|
| `FANCY_STATUSLINE_TOPIC`          | unset   | `off` disables the feature; any other value is used as a fixed topic |
| `FANCY_STATUSLINE_TOPIC_EVERY`    | `5`     | prompts between automatic recomputes         |
| `FANCY_STATUSLINE_TOPIC_WIDTH`    | `60`    | maximum rendered length                      |
| `FANCY_STATUSLINE_TOPIC_MODEL`    | `claude-haiku-4-5-20251001` | model used by the summarizer |
| `FANCY_STATUSLINE_TOPIC_CHILD`    | unset   | internal recursion guard; not user-facing    |

Every recompute is a real Haiku call and consumes the user's rate limits. The README must say so
plainly, next to the `off` switch.

## Testing

The repository has no tests today. This adds `tests/run.sh`, runnable locally and in CI:

- **Status-line rendering** — feed fixture JSON on stdin against a fixture state file: topic
  present, topic absent, over-long topic, topic carrying ANSI and literal `\033` sequences
  (asserting the escape does not survive), `FANCY_STATUSLINE_TOPIC` set, `…=off`.
- **Trigger logic** — drive `topic.sh` with a stubbed worker on `PATH` and assert it fires on
  prompt 1, stays quiet on 2–5, fires on 6, and never fires under `topic_source: manual`,
  `topic_source: off`, or `FANCY_STATUSLINE_TOPIC_CHILD=1`.
- **Worker** — with a stub `claude` returning canned output: state is updated on success, left
  untouched on non-zero exit, on empty output, and when `claude` is absent; a held lock suppresses
  a second run.
- **Sanitization** — unit-level checks of the sanitizer against the cases above.
- `shellcheck` over every script in the plugin.

No test may invoke the real `claude` binary or the network.

## Out of scope

- Sharing topics across sessions or projects.
- Any topic history or a `/topics` listing.
- Changing what the other status-line rows show.
