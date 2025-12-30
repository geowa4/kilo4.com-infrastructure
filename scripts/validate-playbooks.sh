#!/usr/bin/env bash
set -uo pipefail

# Check if any playbook files have changed
if ! git diff --name-only | grep -q "^playbooks/"; then
    exit 0
fi

echo "Playbook changes detected, running validation..." >&2

# Validate YAML syntax for all playbooks
for f in playbooks/*.yml; do
    if ! uv run python -c "import yaml; yaml.safe_load(open('$f'))" 2>&1; then
        echo "" >&2
        echo "YAML syntax error in $f - please fix the syntax errors above." >&2
        exit 2
    fi
done

# Run ansible-lint and capture output
lint_output=$(uv run ansible-lint playbooks/*.yml 2>&1) || {
    echo "$lint_output" >&2
    echo "" >&2
    echo "ansible-lint failed - please fix the linting errors above." >&2
    exit 2
}

echo "All playbook validations passed" >&2
