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

printf '\n%d assertions, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
