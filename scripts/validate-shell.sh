#!/usr/bin/env bash
set -uo pipefail

# Check if any shell scripts have changed
changed_scripts=$(git diff --name-only | grep -E '\.sh$' || true)

if [ -z "$changed_scripts" ]; then
    exit 0
fi

echo "Shell script changes detected, running validation..." >&2

errors=0

for f in $changed_scripts; do
    # Skip if file doesn't exist (was deleted)
    [ -f "$f" ] || continue

    # Run bash -n syntax check
    if ! bash -n "$f" 2>&1; then
        echo "Syntax error in $f" >&2
        errors=1
    fi

    # Run shellcheck if available
    if command -v shellcheck &>/dev/null; then
        if ! shellcheck "$f" 2>&1; then
            echo "shellcheck failed for $f" >&2
            errors=1
        fi
    fi
done

if [ "$errors" -ne 0 ]; then
    echo "" >&2
    echo "Shell script validation failed - please fix the errors above." >&2
    exit 2
fi

echo "All shell script validations passed" >&2
