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
