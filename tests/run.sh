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
