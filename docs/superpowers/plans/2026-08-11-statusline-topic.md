# Session Topic in the Status Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a short, automatically derived topic for the current session as the top line of the fancy-statusline status bar.

**Architecture:** A `UserPromptSubmit` hook counts prompts and, on the 1st and then every Nth, spawns a detached worker that asks Haiku for a 3–5 word topic and caches it in the existing per-session state JSON. The status line only ever reads that cache, so rendering stays instant. A `/topic` command pins a manual topic that suppresses the worker.

**Tech Stack:** Bash 4+, `jq`, `awk`, the `claude` CLI in `-p` mode. Tests are plain bash with a hand-rolled assert helper; `shellcheck` runs as part of the suite.

**Spec:** `docs/superpowers/specs/2026-08-11-statusline-topic-design.md`

## Global Constraints

- Everything lives under `plugins/fancy-statusline/` except the test suite, which lives in `tests/` at the repository root.
- Target `bash` ≥ 4 with `jq` and `awk` only. No new runtime dependencies.
- Scripts must work on macOS (BSD `stat`, `sed`, `date`) and Linux (GNU). The existing code already does `bsd || gnu` fallbacks — follow that pattern.
- Every hook must exit 0 on any failure. A broken topic must never break a prompt or the status bar.
- State file: `~/.claude/fancy-statusline/sessions/<session_id>.json`. New keys: `topic`, `topic_source`, `topic_at`, `prompts`, `topic_at_prompt`. Existing keys (`session_id`, `started`, `last_event`, `last_event_at`, `restarts`) must survive every write.
- `topic_source` is one of exactly `auto`, `manual`, `off`.
- Configuration variables and their defaults, verbatim from the spec:
  `FANCY_STATUSLINE_TOPIC` (unset), `FANCY_STATUSLINE_TOPIC_EVERY` (`5`), `FANCY_STATUSLINE_TOPIC_WIDTH` (`60`), `FANCY_STATUSLINE_TOPIC_MODEL` (`claude-haiku-4-5-20251001`), `FANCY_STATUSLINE_TOPIC_CHILD` (internal).
- No test may invoke the real `claude` binary or touch the network. Tests run against a sandbox `$HOME`.
- Commit after every task.

---

### Task 1: Shared library — sanitizer and state helpers

The sanitizer is the security boundary of this feature: topic text comes from model output over arbitrary transcript content and is printed into a terminal. Build it first, with tests, before anything consumes it.

**Files:**
- Create: `plugins/fancy-statusline/lib/topic-lib.sh`
- Create: `tests/helpers.sh`
- Create: `tests/run.sh`
- Create: `tests/test_topic_lib.sh`

**Interfaces:**
- Consumes: nothing.
- Produces, all sourced via `. lib/topic-lib.sh`:
  - `topic_state_path <session_id>` → prints `$TOPIC_STATE_DIR/<session_id>.json` on stdout; returns 1 and prints nothing when the id contains anything outside `A-Za-z0-9._-` or is empty.
  - `topic_state_read <file> <key> [default]` → prints the value of `.<key>`, or `default` (empty when omitted) when the file, key, or value is missing.
  - `topic_state_merge <file> <json_object>` → deep-merges the object into the file atomically under a directory lock; creates the file and its parent when absent; returns 0 on success, 1 on failure.
  - `topic_sanitize <text>` → prints a single safe line, ANSI- and control-free, whitespace-collapsed, surrounding quotes removed, truncated to `FANCY_STATUSLINE_TOPIC_WIDTH` with a trailing `…`.
  - `TOPIC_STATE_DIR` — overridable state directory, defaults to `$HOME/.claude/fancy-statusline/sessions`.

- [ ] **Step 1: Write the test helper**

Create `tests/helpers.sh`:

```bash
#!/bin/bash
# Assertions and sandboxing shared by every test file. Sourced by tests/run.sh
# in a single shell, so the counters accumulate across files.

TESTS_RUN=0
TESTS_FAILED=0

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN_DIR="$REPO_ROOT/plugins/fancy-statusline"

_pass() { printf '  ok   %s\n' "$1"; }
_fail() {
  TESTS_FAILED=$(( TESTS_FAILED + 1 ))
  printf '  FAIL %s\n' "$1"
}

assert_eq() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    _fail "$1"
    printf '       expected: [%s]\n       actual:   [%s]\n' "$3" "$2"
  fi
}

assert_contains() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  case "$2" in
    *"$3"*) _pass "$1" ;;
    *) _fail "$1"; printf '       [%s] does not contain [%s]\n' "$2" "$3" ;;
  esac
}

assert_not_contains() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  case "$2" in
    *"$3"*) _fail "$1"; printf '       [%s] unexpectedly contains [%s]\n' "$2" "$3" ;;
    *) _pass "$1" ;;
  esac
}

assert_file_exists() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [ -e "$2" ]; then _pass "$1"; else _fail "$1"; printf '       missing: %s\n' "$2"; fi
}

assert_file_missing() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [ -e "$2" ]; then _fail "$1"; printf '       unexpected: %s\n' "$2"; else _pass "$1"; fi
}

# Redirect all plugin state into a throwaway HOME for the duration of a test file.
sandbox_home() {
  ORIG_HOME="${ORIG_HOME:-$HOME}"
  TEST_HOME=$(mktemp -d)
  export HOME="$TEST_HOME"
  export TOPIC_STATE_DIR="$HOME/.claude/fancy-statusline/sessions"
  mkdir -p "$TOPIC_STATE_DIR"
  unset FANCY_STATUSLINE_TOPIC FANCY_STATUSLINE_TOPIC_EVERY \
        FANCY_STATUSLINE_TOPIC_WIDTH FANCY_STATUSLINE_TOPIC_MODEL \
        FANCY_STATUSLINE_TOPIC_CHILD
}

sandbox_cleanup() {
  [ -n "$TEST_HOME" ] && rm -rf "$TEST_HOME"
  TEST_HOME=""
  [ -n "$ORIG_HOME" ] && export HOME="$ORIG_HOME"
}

# Put a stub executable named $1 on PATH, with $2 as its body.
stub_bin() {
  [ -z "$STUB_DIR" ] && { STUB_DIR=$(mktemp -d); export PATH="$STUB_DIR:$PATH"; }
  printf '#!/bin/bash\n%s\n' "$2" > "$STUB_DIR/$1"
  chmod +x "$STUB_DIR/$1"
}

stub_cleanup() {
  [ -n "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  STUB_DIR=""
}
```

- [ ] **Step 2: Write the test runner**

Create `tests/run.sh`:

```bash
#!/bin/bash
# Runs every tests/test_*.sh in one shell so assertion counters accumulate.
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=helpers.sh
. ./helpers.sh

for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n%s\n' "$t"
  # shellcheck disable=SC1090
  . "./$t"
done

printf '\n%d assertions, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
```

Make both executable:

```bash
chmod +x tests/run.sh
```

- [ ] **Step 3: Write the failing tests for the library**

Create `tests/test_topic_lib.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/run.sh`
Expected: FAIL — `topic-lib.sh` does not exist, so every assertion errors out with "No such file or directory".

- [ ] **Step 5: Write the library**

Create `plugins/fancy-statusline/lib/topic-lib.sh`:

```bash
#!/bin/bash
# Shared helpers for the session-topic feature: where session state lives, how
# to update it without racing, and how to make a topic string safe to print.
#
# Sourced by the status line and by the topic hooks. Defines functions only —
# sourcing it must have no side effects.

TOPIC_STATE_DIR="${TOPIC_STATE_DIR:-$HOME/.claude/fancy-statusline/sessions}"

# topic_state_path <session_id>
# The session id becomes a filename, so refuse anything that is not a plain id.
topic_state_path() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/%s.json' "$TOPIC_STATE_DIR" "$1"
}

# topic_state_read <file> <key> [default]
topic_state_read() {
  local file="$1" key="$2" def="${3:-}" val=""
  if [ -f "$file" ]; then
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)
  fi
  [ -z "$val" ] && val="$def"
  printf '%s' "$val"
}

# topic_state_merge <file> <json_object>
# The prompt hook writes counters while the worker writes the topic, so writes
# are serialized with a directory lock. A failed jq leaves the old file intact.
topic_state_merge() {
  local file="$1" frag="$2" lock="${file}.lock" tries=0 base tmp
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$(( tries + 1 ))
    [ "$tries" -gt 50 ] && return 1
    sleep 0.02
  done
  base='{}'
  if [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
    base=$(cat "$file")
  fi
  tmp=$(mktemp) || { rmdir "$lock" 2>/dev/null; return 1; }
  if printf '%s' "$base" | jq --argjson frag "$frag" '. * $frag' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    rmdir "$lock" 2>/dev/null
    return 0
  fi
  rm -f "$tmp"
  rmdir "$lock" 2>/dev/null
  return 1
}

# topic_sanitize <text>
# Topic text reaches a terminal, and its ultimate source is model output over
# arbitrary transcript content. Strip anything that could move the cursor or
# repaint the screen, in both real and backslash-escaped form — the status line
# assembles strings that pass through printf %b, which would interpret the
# literal form.
topic_sanitize() {
  local raw="$1" width="${FANCY_STATUSLINE_TOPIC_WIDTH:-60}" out
  case "$width" in ''|*[!0-9]*) width=60 ;; esac
  [ "$width" -lt 8 ] && width=8

  out=$(printf '%s' "$raw" | head -n 1)
  # literal "\033[…m", "\x1b[…m", "\e[…m"
  out=$(printf '%s' "$out" | sed -E 's/\\+(033|x1[bB]|e)\[[0-9;]*[a-zA-Z]//g')
  # real ESC-introduced CSI sequences
  out=$(printf '%s' "$out" | LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')
  out=$(printf '%s' "$out" | tr -d '\\')
  out=$(printf '%s' "$out" | LC_ALL=C tr -d '\000-\037\177')
  out=$(printf '%s' "$out" | tr -s '[:space:]' ' ')
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  out="${out#\"}"; out="${out%\"}"
  out="${out#\'}"; out="${out%\'}"

  if [ "${#out}" -gt "$width" ]; then
    out="$(printf '%s' "$out" | cut -c "1-$(( width - 1 ))")…"
  fi
  printf '%s' "$out"
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — all assertions in `test_topic_lib.sh` report `ok`, final line reports `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add tests plugins/fancy-statusline/lib/topic-lib.sh
git commit -m "feat(statusline): add topic state helpers and sanitizer

The sanitizer is the security boundary for topic text, which originates
from model output over arbitrary transcript content and ends up in a
terminal. It strips ANSI in both real and backslash-escaped form.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Render the topic line in the status bar

**Files:**
- Modify: `plugins/fancy-statusline/statusline-command.sh` (add a library source near the top; add a new first output line before the existing `LINE 1` block at line 247)
- Modify: `plugins/fancy-statusline/hooks/install.sh` (copy `lib/topic-lib.sh` alongside the status line script)
- Create: `tests/test_statusline_topic.sh`

**Interfaces:**
- Consumes: `topic_state_path`, `topic_state_read`, `topic_sanitize` from Task 1.
- Produces: a status-bar line of the exact form `🏷️  topic: <text>` (emoji, two spaces, bold `topic:`, text), printed before the `user@host` line, or nothing at all.

Resolution order — env var, then manual/auto cache, then nothing:

| condition | rendered |
|---|---|
| `FANCY_STATUSLINE_TOPIC=off` | nothing |
| `FANCY_STATUSLINE_TOPIC` non-empty | its sanitized value |
| state `topic_source` is `off` | nothing |
| state `topic` non-empty | its value |
| otherwise | nothing |

- [ ] **Step 1: Write the failing test**

Create `tests/test_statusline_topic.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — assertions like "auto topic is rendered" fail because no `topic:` line is printed.

- [ ] **Step 3: Source the library from the status line**

In `plugins/fancy-statusline/statusline-command.sh`, directly after `input=$(cat)` (line 2), insert:

```bash

# Shared topic helpers. install.sh mirrors the plugin's lib/ next to the copied
# status line script, so both the in-plugin and the installed path are tried.
for _topic_lib in "${CLAUDE_PLUGIN_ROOT:-}/lib/topic-lib.sh" \
                  "$HOME/.claude/fancy-statusline/lib/topic-lib.sh"; do
  if [ -f "$_topic_lib" ]; then
    # shellcheck source=lib/topic-lib.sh
    . "$_topic_lib"
    break
  fi
done
```

- [ ] **Step 4: Render the topic line**

In the same file, immediately before the `# ── LINE 1 — machine identity ──` comment (line 247), insert:

```bash
# ── LINE 0 — session topic ───────────────────────────────────────────────────
# Rendering only ever reads the cache written by hooks/topic-worker.sh. It never
# calls a model and never blocks. When there is no topic the line is omitted
# entirely, so the bar does not jump while the first summary is still running.
topic=""
if command -v topic_sanitize >/dev/null 2>&1; then
  topic_env="${FANCY_STATUSLINE_TOPIC:-}"
  if [ "$topic_env" = "off" ]; then
    topic=""
  elif [ -n "$topic_env" ]; then
    topic=$(topic_sanitize "$topic_env")
  else
    topic_state=$(topic_state_path "$session_id" 2>/dev/null)
    if [ -n "$topic_state" ] && [ -f "$topic_state" ]; then
      if [ "$(topic_state_read "$topic_state" topic_source auto)" != "off" ]; then
        topic=$(topic_sanitize "$(topic_state_read "$topic_state" topic)")
      fi
    fi
  fi
fi

if [ -n "$topic" ]; then
  printf "${C_BRIGHT_MAGENTA}\xF0\x9F\x8F\xB7\xEF\xB8\x8F  ${BOLD}topic:${RESET}${C_BRIGHT_MAGENTA}%s${RESET}\n" "$topic"
fi
```

The topic is passed as a `printf` **argument**, never spliced into the format string — that is what keeps a `%` inside a topic harmless.

- [ ] **Step 5: Add the colour**

In the ANSI palette block, after the `C_BRIGHT_BLUE` definition (line 185), add:

```bash
C_BRIGHT_MAGENTA="\033[1;35m"
```

- [ ] **Step 6: Mirror the library on install**

In `plugins/fancy-statusline/hooks/install.sh`, after the `chmod +x "$SCRIPT_DEST"` line (line 11), insert:

```bash

# The status line sources lib/topic-lib.sh. The copy in ~/.claude/ has no plugin
# root to resolve, so mirror the library next to it and keep it current too.
LIB_SRC="${CLAUDE_PLUGIN_ROOT}/lib/topic-lib.sh"
LIB_DEST_DIR="$HOME/.claude/fancy-statusline/lib"
if [ -f "$LIB_SRC" ]; then
  mkdir -p "$LIB_DEST_DIR" 2>/dev/null && cp "$LIB_SRC" "$LIB_DEST_DIR/topic-lib.sh" 2>/dev/null
fi
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add plugins/fancy-statusline/statusline-command.sh \
        plugins/fancy-statusline/hooks/install.sh \
        tests/test_statusline_topic.sh
git commit -m "feat(statusline): render the session topic as the top line

Reads only the cached topic, so the bar stays instant. The topic is a
printf argument rather than part of the format string.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The `UserPromptSubmit` trigger hook

**Files:**
- Create: `plugins/fancy-statusline/hooks/topic.sh`
- Modify: `plugins/fancy-statusline/hooks/hooks.json` (add to the existing `UserPromptSubmit` array)
- Create: `tests/test_topic_hook.sh`

**Interfaces:**
- Consumes: `topic_state_path`, `topic_state_read`, `topic_state_merge` from Task 1.
- Produces: increments `prompts`; sets `topic_at_prompt` when it decides to recompute; spawns `$FANCY_STATUSLINE_TOPIC_WORKER` (default `<hooks dir>/topic-worker.sh`) detached with the arguments `<session_id> <transcript_path>`.

Decision table — the hook fires the worker only when every condition holds:

| condition | fire? |
|---|---|
| `FANCY_STATUSLINE_TOPIC_CHILD` set | never |
| `FANCY_STATUSLINE_TOPIC` set to anything | never |
| `topic_source` is `manual` or `off` | never |
| `prompts == 1` | yes |
| `prompts - topic_at_prompt >= N` | yes |
| otherwise | no |

- [ ] **Step 1: Write the failing test**

Create `tests/test_topic_hook.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `hooks/topic.sh` does not exist, so nothing fires and no state is written.

- [ ] **Step 3: Write the hook**

Create `plugins/fancy-statusline/hooks/topic.sh`:

```bash
#!/bin/bash
# UserPromptSubmit hook: count prompts and decide when the session topic should
# be recomputed. It never talks to a model itself — it spawns the worker
# detached and returns, so a prompt is never delayed by a summary.
#
# Disable with FANCY_STATUSLINE_TOPIC=off.

# Recursion guard. topic-worker.sh runs `claude -p`, which is itself a Claude
# Code session and fires this hook again. Without this line, one prompt would
# spawn summarizers without end.
[ -n "${FANCY_STATUSLINE_TOPIC_CHILD:-}" ] && exit 0

# Any value pins or disables the topic, and a computed one would never be shown.
[ -n "${FANCY_STATUSLINE_TOPIC:-}" ] && exit 0

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || exit 0

input=$(cat)

session_id=$(printf '%s' "$input"  | jq -r '.session_id      // empty' 2>/dev/null)
transcript=$(printf '%s' "$input"  | jq -r '.transcript_path // empty' 2>/dev/null)

state_file=$(topic_state_path "$session_id") || exit 0

every="${FANCY_STATUSLINE_TOPIC_EVERY:-5}"
case "$every" in ''|*[!0-9]*) every=5 ;; esac
[ "$every" -lt 1 ] && every=1

prompts=$(topic_state_read      "$state_file" prompts 0)
at_prompt=$(topic_state_read    "$state_file" topic_at_prompt 0)
source_kind=$(topic_state_read  "$state_file" topic_source auto)
case "$prompts"   in ''|*[!0-9]*) prompts=0   ;; esac
case "$at_prompt" in ''|*[!0-9]*) at_prompt=0 ;; esac

prompts=$(( prompts + 1 ))

# A pinned or disabled topic still counts prompts, so that clearing the pin
# later resumes from an honest number.
if [ "$source_kind" = "manual" ] || [ "$source_kind" = "off" ]; then
  topic_state_merge "$state_file" "$(jq -nc --argjson p "$prompts" '{prompts:$p}')"
  exit 0
fi

recompute=0
if [ "$prompts" -eq 1 ] || [ $(( prompts - at_prompt )) -ge "$every" ]; then
  recompute=1
fi

if [ "$recompute" -eq 0 ]; then
  topic_state_merge "$state_file" "$(jq -nc --argjson p "$prompts" '{prompts:$p}')"
  exit 0
fi

topic_state_merge "$state_file" \
  "$(jq -nc --argjson p "$prompts" '{prompts:$p, topic_at_prompt:$p}')"

worker="${FANCY_STATUSLINE_TOPIC_WORKER:-$HOOK_DIR/topic-worker.sh}"
[ -x "$worker" ] || [ -f "$worker" ] || exit 0

# Detached: the hook must not wait for the model, and the worker must survive
# this process exiting.
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$worker" "$session_id" "$transcript" >/dev/null 2>&1 &
else
  nohup bash "$worker" "$session_id" "$transcript" >/dev/null 2>&1 &
fi
disown 2>/dev/null

exit 0
```

- [ ] **Step 4: Wire the hook**

In `plugins/fancy-statusline/hooks/hooks.json`, extend the existing `UserPromptSubmit` entry so its `hooks` array holds both scripts:

```json
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/install.sh\"",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/topic.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `0 failed`.

- [ ] **Step 6: Verify the hooks file is still valid JSON**

Run: `jq -e . plugins/fancy-statusline/hooks/hooks.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 7: Commit**

```bash
git add plugins/fancy-statusline/hooks/topic.sh \
        plugins/fancy-statusline/hooks/hooks.json \
        tests/test_topic_hook.sh
git commit -m "feat(statusline): trigger topic recomputation from UserPromptSubmit

Fires on the first prompt and then every Nth, spawning the worker
detached. Guards against the recursion that claude -p would otherwise
cause by firing this same hook.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The background summarizer

**Files:**
- Create: `plugins/fancy-statusline/hooks/topic-worker.sh`
- Create: `tests/test_topic_worker.sh`

**Interfaces:**
- Consumes: `topic_state_path`, `topic_state_merge`, `topic_sanitize` from Task 1. Invoked by Task 3 as `topic-worker.sh <session_id> <transcript_path>`.
- Produces: writes `{topic, topic_source:"auto", topic_at}` into the session state file. Holds `<state_file>.topic.lock` for the duration.

- [ ] **Step 1: Write the failing test**

Create `tests/test_topic_worker.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `topic-worker.sh` does not exist, so `.topic` stays `null`.

- [ ] **Step 3: Write the worker**

Create `plugins/fancy-statusline/hooks/topic-worker.sh`:

```bash
#!/bin/bash
# Background summarizer: turn the tail of a session transcript into a short
# topic and cache it in the session state file.
#
# Spawned detached by hooks/topic.sh as:  topic-worker.sh <session_id> <transcript>
# Never called from the status line — rendering must not depend on a model.
#
# Any failure is silent and leaves the previous topic in place.

session_id="$1"
transcript="$2"

[ -z "$session_id" ] && exit 0
[ -f "$transcript" ] || exit 0

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || exit 0

command -v claude >/dev/null 2>&1 || exit 0

state_file=$(topic_state_path "$session_id") || exit 0
mkdir -p "$(dirname "$state_file")" 2>/dev/null || exit 0

# ── lock ─────────────────────────────────────────────────────────────────────
# One summarizer per session. A lock older than two minutes belonged to a run
# that died without cleaning up, so it is reclaimed.
lock="${state_file}.topic.lock"
if ! mkdir "$lock" 2>/dev/null; then
  stale=$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)
  [ -z "$stale" ] && exit 0
  rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

# ── excerpt ──────────────────────────────────────────────────────────────────
# The last ten plain-text turns. Tool calls, tool results, thinking blocks and
# sidechain agents are bulk without signal about what the session is about.
excerpt=$(jq -rs '
  [ .[]
    | select(type == "object")
    | select(.type == "user" or .type == "assistant")
    | select(.isSidechain != true)
    | select(.isMeta != true)
    | { role: .type,
        text: ( if (.message.content | type) == "string"
                then .message.content
                else [ .message.content[]? | select(.type == "text") | .text ] | join("\n")
                end ) }
    | select(.text != null and .text != "")
    | select(.text | startswith("<system-reminder>") | not)
  ]
  | .[-10:]
  | map("\(.role): \(.text[0:400])")
  | join("\n---\n")
' "$transcript" 2>/dev/null)

[ -z "$excerpt" ] && exit 0

prompt="Below is the tail of a coding session.

Reply with a 3-5 word topic naming what the session is about. Reply with the
topic and nothing else: no quotes, no trailing punctuation, no preamble.

<session>
${excerpt}
</session>"

# ── model call ───────────────────────────────────────────────────────────────
model="${FANCY_STATUSLINE_TOPIC_MODEL:-claude-haiku-4-5-20251001}"

run_claude() {
  # FANCY_STATUSLINE_TOPIC_CHILD stops hooks/topic.sh dead inside the child
  # session this call creates.
  if command -v timeout >/dev/null 2>&1; then
    FANCY_STATUSLINE_TOPIC_CHILD=1 timeout 30 claude -p --model "$model" "$prompt" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    FANCY_STATUSLINE_TOPIC_CHILD=1 gtimeout 30 claude -p --model "$model" "$prompt" 2>/dev/null
  else
    FANCY_STATUSLINE_TOPIC_CHILD=1 claude -p --model "$model" "$prompt" 2>/dev/null
  fi
}

answer=$(run_claude) || exit 0

topic=$(topic_sanitize "$answer")
[ -z "$topic" ] && exit 0

topic_state_merge "$state_file" "$(jq -nc \
  --arg t "$topic" \
  --argjson at "$(date +%s)" \
  '{topic:$t, topic_source:"auto", topic_at:$at}')"

exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `0 failed`.

- [ ] **Step 5: Verify the recursion guard by hand**

Confirm the guard the tests cannot exercise (they never run the real CLI):

Run: `grep -n 'FANCY_STATUSLINE_TOPIC_CHILD' plugins/fancy-statusline/hooks/topic.sh plugins/fancy-statusline/hooks/topic-worker.sh`
Expected: the variable is checked on the first executable line of `topic.sh` and exported into every `claude` invocation in `topic-worker.sh` — three matches in total.

- [ ] **Step 6: Commit**

```bash
git add plugins/fancy-statusline/hooks/topic-worker.sh tests/test_topic_worker.sh
git commit -m "feat(statusline): summarize the session topic with Haiku

Reads the last ten plain-text turns of the transcript, asks for a 3-5
word topic, and caches it. Locked per session; every failure path leaves
the previous topic untouched.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The `/topic` command

**Files:**
- Create: `plugins/fancy-statusline/hooks/topic-set.sh`
- Create: `plugins/fancy-statusline/commands/topic.md`
- Create: `tests/test_topic_set.sh`

**Interfaces:**
- Consumes: `topic_state_path`, `topic_state_merge`, `topic_sanitize` from Task 1.
- Produces: `topic-set.sh [<text>|off]` — writes `topic_source` `manual` / `auto` / `off` and prints a one-line confirmation on stdout.

Session id resolution, in order: `$CLAUDE_SESSION_ID`; otherwise the most recently modified `*.jsonl` under `~/.claude/projects/<slugified cwd>/`, since the active session is the transcript being written right now. When neither resolves, print an error and exit 1.

The slug is the working directory with every `/` and `.` replaced by `-`, matching the directory names Claude Code already creates (e.g. `/Users/x/projects/fancy-claude` → `-Users-x-projects-fancy-claude`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_topic_set.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `topic-set.sh` does not exist; `jq -r '.topic'` still reports `auto topic`.

- [ ] **Step 3: Write the setter**

Create `plugins/fancy-statusline/hooks/topic-set.sh`:

```bash
#!/bin/bash
# Backend for the /topic command.
#
#   topic-set.sh <text>   pin a manual topic for this session
#   topic-set.sh          drop the pin and let the summarizer take over again
#   topic-set.sh off      hide the topic line and stop summarizing
#
# Prints a one-line confirmation for the model to relay to the user.

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/topic-lib.sh
. "$HOOK_DIR/../lib/topic-lib.sh" 2>/dev/null || {
  printf 'fancy-statusline: topic library not found\n'
  exit 1
}

# ── which session are we in ──────────────────────────────────────────────────
# The transcript being written right now belongs to the active session, so the
# newest .jsonl for this directory is the answer when the id is not exported.
resolve_session() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_SESSION_ID"
    return 0
  fi
  local slug proj newest
  slug=$(pwd | tr '/.' '--')
  proj="$HOME/.claude/projects/$slug"
  [ -d "$proj" ] || return 1
  newest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -n 1)
  [ -z "$newest" ] && return 1
  newest=$(basename "$newest" .jsonl)
  printf '%s' "$newest"
}

session_id=$(resolve_session) || {
  printf 'fancy-statusline: could not determine the current session\n'
  exit 1
}

state_file=$(topic_state_path "$session_id") || {
  printf 'fancy-statusline: could not determine the current session\n'
  exit 1
}

arg="$*"

case "$arg" in
  off)
    topic_state_merge "$state_file" '{"topic":null,"topic_source":"off"}'
    printf 'Topic line turned off for this session.\n'
    ;;
  '')
    # Rewinding topic_at_prompt makes the next prompt recompute immediately
    # rather than waiting out the remainder of the interval.
    topic_state_merge "$state_file" '{"topic":null,"topic_source":"auto","topic_at_prompt":0}'
    printf 'Topic reset to auto; it will be recomputed on the next prompt.\n'
    ;;
  *)
    topic=$(topic_sanitize "$arg")
    if [ -z "$topic" ]; then
      printf 'fancy-statusline: that topic is empty after sanitization\n'
      exit 1
    fi
    topic_state_merge "$state_file" "$(jq -nc \
      --arg t "$topic" \
      --argjson at "$(date +%s)" \
      '{topic:$t, topic_source:"manual", topic_at:$at}')"
    printf 'Topic pinned: %s\n' "$topic"
    ;;
esac

exit 0
```

- [ ] **Step 4: Write the command definition**

Create `plugins/fancy-statusline/commands/topic.md`:

```markdown
---
description: Pin, reset, or hide the session topic shown in the status bar
argument-hint: [text | off]
allowed-tools: Bash(bash:*)
---

Run this exact command and report its output to the user verbatim, in one line:

!`bash "${CLAUDE_PLUGIN_ROOT}/hooks/topic-set.sh" $ARGUMENTS`

- With text, the topic is pinned and the automatic summarizer stops touching it.
- With no argument, the pin is dropped and the topic goes back to being derived automatically.
- With `off`, the topic line is hidden for the rest of this session.

Do not add commentary beyond the command's own output.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add plugins/fancy-statusline/hooks/topic-set.sh \
        plugins/fancy-statusline/commands/topic.md \
        tests/test_topic_set.sh
git commit -m "feat(statusline): add the /topic command

Pins a manual topic, resets to auto, or hides the line. A pin suppresses
the summarizer for the rest of the session.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Carry the topic through session restarts

`hooks/session-state.sh` rewrites the whole state file with `jq -n` on every `SessionStart`. As written it would erase every topic field the worker had stored. It must carry them across a `resume` and deliberately reset them on `clear` and `compact`.

**Files:**
- Modify: `plugins/fancy-statusline/hooks/session-state.sh:59-88` (read the topic fields, then include them in the `jq -n` object)
- Create: `tests/test_session_state_topic.sh`

**Interfaces:**
- Consumes: the state file layout from Task 1.
- Produces: no new functions. Behaviour contract — on `startup`/`resume` the topic fields survive unchanged; on `clear`/`compact` `topic` becomes `null`, `topic_source` becomes `auto`, and `prompts`/`topic_at_prompt` become `0`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_session_state_topic.sh`:

```bash
#!/bin/bash
# hooks/session-state.sh — topic fields across restarts

sandbox_home

WORK_DIR=$(mktemp -d)
TRANSCRIPT="$WORK_DIR/transcript.jsonl"
printf '{}\n' > "$TRANSCRIPT"

session_start() {
  jq -nc --arg src "$1" --arg sid "$2" --arg tr "$TRANSCRIPT" \
    '{source:$src, session_id:$sid, transcript_path:$tr}' \
    | bash "$PLUGIN_DIR/hooks/session-state.sh" >/dev/null 2>&1
}

seed() {
  printf '{"session_id":"%s","started":1000,"restarts":1,"topic":"kept topic","topic_source":"manual","topic_at":1234567890,"prompts":7,"topic_at_prompt":5}' \
    "$1" > "$TOPIC_STATE_DIR/$1.json"
}

# resume keeps everything
seed rsess
session_start resume rsess
sf="$TOPIC_STATE_DIR/rsess.json"
assert_eq "resume keeps the topic"        "$(jq -r '.topic' "$sf")" "kept topic"
assert_eq "resume keeps the source"       "$(jq -r '.topic_source' "$sf")" "manual"
assert_eq "resume keeps the prompt count" "$(jq -r '.prompts' "$sf")" "7"
assert_eq "resume still counts restarts"  "$(jq -r '.restarts' "$sf")" "2"

# startup keeps everything too
seed usess
session_start startup usess
assert_eq "startup keeps the topic" "$(jq -r '.topic' "$TOPIC_STATE_DIR/usess.json")" "kept topic"

# clear wipes the topic
seed csess
session_start clear csess
sf="$TOPIC_STATE_DIR/csess.json"
assert_eq "clear drops the topic"          "$(jq -r '.topic' "$sf")" "null"
assert_eq "clear returns to auto"          "$(jq -r '.topic_source' "$sf")" "auto"
assert_eq "clear resets the prompt count"  "$(jq -r '.prompts' "$sf")" "0"
assert_eq "clear rewinds topic_at_prompt"  "$(jq -r '.topic_at_prompt' "$sf")" "0"
assert_eq "clear preserves the start time" "$(jq -r '.started' "$sf")" "1000"

# compact wipes it as well
seed psess
session_start compact psess
assert_eq "compact drops the topic" "$(jq -r '.topic' "$TOPIC_STATE_DIR/psess.json")" "null"

rm -rf "$WORK_DIR"
sandbox_cleanup
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — "resume keeps the topic" reports `null`, because the current `jq -n` object has no topic fields.

- [ ] **Step 3: Read the existing topic fields**

In `plugins/fancy-statusline/hooks/session-state.sh`, immediately after the `last_event`/`last_event_at` block that ends at line 68, insert:

```bash

# The worker and the prompt hook write topic fields into the same file, and the
# jq -n below rewrites it wholesale — so carry them across. A restart that ends
# the conversation (clear, compact) ends the topic with it; a resume does not.
topic=$(jq -r        '.topic          // empty' "$state_file" 2>/dev/null)
topic_source=$(jq -r '.topic_source   // empty' "$state_file" 2>/dev/null)
topic_at=$(jq -r     '.topic_at       // empty' "$state_file" 2>/dev/null)
prompts=$(jq -r      '.prompts        // 0'     "$state_file" 2>/dev/null)
topic_at_prompt=$(jq -r '.topic_at_prompt // 0' "$state_file" 2>/dev/null)
case "$prompts"         in ''|*[!0-9]*) prompts=0         ;; esac
case "$topic_at_prompt" in ''|*[!0-9]*) topic_at_prompt=0 ;; esac
case "$topic_at"        in ''|*[!0-9]*) topic_at=""       ;; esac

case "$source" in
  clear|compact)
    topic=""
    topic_source="auto"
    topic_at=""
    prompts=0
    topic_at_prompt=0
    ;;
esac
```

Note that this reads `$state_file` a second time, after the `restarts` block already read it — that is fine, and it keeps the topic logic in one readable place instead of threading it through the earlier reads.

- [ ] **Step 4: Write the fields back**

Replace the `jq -n` invocation (lines 71-83) with:

```bash
if jq -n \
    --arg  sid   "$session_id" \
    --argjson st "$started_epoch" \
    --arg  ev    "$last_event" \
    --arg  evat  "$last_event_at" \
    --argjson n  "$restarts" \
    --arg  tp    "$topic" \
    --arg  tsrc  "$topic_source" \
    --arg  tat   "$topic_at" \
    --argjson pc "$prompts" \
    --argjson ta "$topic_at_prompt" \
    '{
       session_id:      $sid,
       started:         $st,
       last_event:      (if $ev   == "" then null else $ev             end),
       last_event_at:   (if $evat == "" then null else ($evat|tonumber) end),
       restarts:        $n,
       topic:           (if $tp   == "" then null else $tp             end),
       topic_source:    (if $tsrc == "" then "auto" else $tsrc         end),
       topic_at:        (if $tat  == "" then null else ($tat|tonumber)  end),
       prompts:         $pc,
       topic_at_prompt: $ta
     }' \
    > "$tmp" 2>/dev/null; then
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `0 failed`, including every assertion from the earlier tasks.

- [ ] **Step 6: Commit**

```bash
git add plugins/fancy-statusline/hooks/session-state.sh tests/test_session_state_topic.sh
git commit -m "fix(statusline): keep topic state across session restarts

SessionStart rewrites the state file wholesale and would otherwise erase
the cached topic. Resume carries it over; clear and compact reset it,
since the conversation it described is gone.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Lint, documentation, and version bump

**Files:**
- Modify: `tests/run.sh` (add a shellcheck pass)
- Modify: `plugins/fancy-statusline/README.md` (new section; update the sample output and the "How it works" section)
- Modify: `README.md` (repository root — mention the topic line)
- Modify: `plugins/fancy-statusline/.claude-plugin/plugin.json` (version `1.2.0` → `1.3.0`, add the `topic` keyword)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: nothing new in code.

- [ ] **Step 1: Add shellcheck to the suite**

In `tests/run.sh`, immediately before the final summary `printf`, insert:

```bash
printf '\nshellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r script; do
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if shellcheck -x -S warning "$script" >/dev/null 2>&1; then
      _pass "$script"
    else
      _fail "$script"
      shellcheck -x -S warning "$script" 2>&1 | sed 's/^/       /'
    fi
  done < <(find "$REPO_ROOT/plugins" -name '*.sh' -type f | sort)
else
  printf '  skipped (shellcheck not installed)\n'
fi
```

- [ ] **Step 2: Run the suite and fix what shellcheck reports**

Run: `bash tests/run.sh`
Expected: PASS. If shellcheck flags anything at warning level or above, fix the script rather than suppressing the check — the one exception is a `source` of a path it cannot follow, which the `# shellcheck source=` directives already declare.

- [ ] **Step 3: Document the feature in the plugin README**

In `plugins/fancy-statusline/README.md`, change the heading `A rich 5-line status bar for Claude Code.` to `A rich 6-line status bar for Claude Code.`, prepend the topic line to the sample block, renumber the existing `Line 1`…`Line 5` labels to `Line 2`…`Line 6`, and add a `**Line 1** — the session topic` bullet at the top of the list. The sample block becomes:

```
Line 1  🏷️  topic: fancy-statusline topic chip
Line 2  alexander@host | 🕒 up:17h50m | ⟳ compacted:09:15 ×2
Line 3  /current/dir
Line 4  🤖 model:sonnet-4-6 ⚖ auto | 📊 ctx:200k | 📈 used:23% | 📉 rem:77%
Line 5  🔧 skills:8 (5.0% ctx) | 🔌 mcp:3 srv / ~60 tools (~12.0% ctx)
Line 6  ⏱️ 5h:43% ↺14:30 EET (1h22m) | 📅 7d:18% ↺Fri 09:00 EET (3d14h)
```

Then add this section directly after the "Session age and restarts" section:

```markdown
## Session topic

Claude Code has no session title, so the plugin derives one. On your first
prompt — and then every fifth — a background job reads the last few turns of the
transcript and asks Haiku for a three-to-five word topic:

```
🏷️  topic: parser refactor and tests
```

**This costs tokens.** Every recomputation is a real model call against your own
rate limits. It is small and infrequent, but it is not free. Set
`FANCY_STATUSLINE_TOPIC=off` to switch the feature off entirely.

The status bar itself never calls a model — it only reads a cached value, so it
stays instant. Until the first topic arrives the line is simply absent.

### Controlling the topic

| command | effect |
|---------|--------|
| `/topic <text>` | pin a topic for this session and stop the automatic updates |
| `/topic` | drop the pin and recompute on the next prompt |
| `/topic off` | hide the line for this session |

`/clear` and `/compact` reset the topic — the conversation it described is gone.
Resuming a session keeps it.

### Configuration

| variable | default | effect |
|----------|---------|--------|
| `FANCY_STATUSLINE_TOPIC` | unset | `off` disables the feature; any other value is used as a fixed topic |
| `FANCY_STATUSLINE_TOPIC_EVERY` | `5` | prompts between automatic recomputations |
| `FANCY_STATUSLINE_TOPIC_WIDTH` | `60` | maximum rendered length |
| `FANCY_STATUSLINE_TOPIC_MODEL` | `claude-haiku-4-5-20251001` | model used for the summary |
```

Finally, in the "How it works" section, append this paragraph:

```markdown
A second `UserPromptSubmit` hook counts prompts and, on the first and then every
fifth, spawns `topic-worker.sh` detached. The worker asks Haiku for a topic and
caches it in the same session state file. Because `claude -p` is itself a Claude
Code session that fires the same hook, the worker exports
`FANCY_STATUSLINE_TOPIC_CHILD=1`, which makes the hook exit on its first line; a
per-session lock is the second line of defence. Topic text is stripped of ANSI
and control characters — in both real and backslash-escaped form — before it is
stored or printed.
```

- [ ] **Step 4: Document it in the root README**

In `README.md` at the repository root, update the fancy-statusline description to mention that the status bar now leads with an automatically derived session topic, and note the `FANCY_STATUSLINE_TOPIC=off` switch alongside it. Match the surrounding tone and length; do not restructure the file.

- [ ] **Step 5: Bump the version**

In `plugins/fancy-statusline/.claude-plugin/plugin.json`:
- set `"version"` to `"1.3.0"`
- change `"description"` to start with `Rich 6-line status bar for Claude Code showing the session topic, model, effort, …` keeping the rest of the sentence intact
- add `"topic"` to the `keywords` array

- [ ] **Step 6: Verify the manifest and run the full suite**

Run: `jq -e . plugins/fancy-statusline/.claude-plugin/plugin.json > /dev/null && bash tests/run.sh`
Expected: valid JSON, then `0 failed`.

- [ ] **Step 7: Smoke-test the real thing**

The suite never runs the real CLI, so exercise it once by hand:

Run:
```bash
bash plugins/fancy-statusline/hooks/topic-worker.sh "$(basename "$(ls -t ~/.claude/projects/*/*.jsonl | head -1)" .jsonl)" "$(ls -t ~/.claude/projects/*/*.jsonl | head -1)"
jq '{topic, topic_source, topic_at}' ~/.claude/fancy-statusline/sessions/"$(basename "$(ls -t ~/.claude/projects/*/*.jsonl | head -1)" .jsonl)".json
```
Expected: after roughly 5–20 seconds, a plausible three-to-five word topic with `"topic_source": "auto"`. Confirm the run terminates and does not spawn further `claude` processes (`pgrep -fl 'claude -p' | wc -l` returns 0 afterwards).

- [ ] **Step 8: Commit**

```bash
git add tests/run.sh README.md \
        plugins/fancy-statusline/README.md \
        plugins/fancy-statusline/.claude-plugin/plugin.json
git commit -m "docs(statusline): document the session topic, bump to 1.3.0

Adds shellcheck to the test suite and documents the topic line, the
/topic command, the configuration variables, and the token cost.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review notes

Spec coverage checked section by section: state layout (Task 1), `topic.sh` trigger (Task 3), `topic-worker.sh` (Task 4), rendering and precedence (Task 2), `/topic` (Task 5), sanitization (Task 1, applied by Tasks 2/4/5), recursion guard (Tasks 3/4), session lifecycle (Task 6), configuration and cost warning (Task 7), testing (all tasks plus shellcheck in Task 7).

One thing the spec did not call out and this plan adds: `hooks/install.sh` must mirror `lib/topic-lib.sh` into `~/.claude/fancy-statusline/lib/`, because the status line runs from a standalone copy in `~/.claude/` that has no plugin root to resolve (Task 2, Step 6).
