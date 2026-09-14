#!/bin/sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."

set +e
matches="$(grep -RIn --include='*.sol' 'block\.timestamp' src/lcc)"
grep_status=$?
set -e

if [ "$grep_status" -gt 1 ]; then
    printf '%s\n' 'Failed to scan LCC sources for wall-clock reads.' >&2
    exit "$grep_status"
fi

set +e
violations="$(printf '%s\n' "$matches" | grep -v '// deliberate wall-clock read')"
filter_status=$?
set -e

if [ "$filter_status" -gt 1 ]; then
    printf '%s\n' 'Failed to filter documented LCC wall-clock reads.' >&2
    exit "$filter_status"
fi

if [ -n "$violations" ]; then
    printf '%s\n' 'LCC wall-clock reads must flow through _now() or documented pause bookkeeping.'
    printf '%s\n' "$violations"
    exit 1
fi
