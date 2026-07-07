#!/bin/sh
# Pre-commit hook: check Swift braces are balanced
# Install: ln -s ../../../pre-commit.sh .git/hooks/pre-commit

for f in $(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$'); do
    python3 "$(dirname "$0")/../../check_braces.py" "$f" || exit 1
done
