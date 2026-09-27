#!/bin/sh
# Adds one to CURRENT_PROJECT_VERSION (App Store Connect rejects a build number it has seen, or a
# lower one). Not the commit count: the public repo's history starts over at a lower number than
# builds already uploaded. Run before archiving.
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
CURRENT=$(sed -n -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)
[ -n "$CURRENT" ] || { echo "no CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }
N=$((CURRENT + 1))
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\1\"$N\"/" project.yml
grep -Eq "^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\"$N\"" project.yml || { echo "failed to set the build number in project.yml" >&2; exit 1; }
xcodegen generate -q
echo "build number $CURRENT → $N"
