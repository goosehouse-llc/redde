#!/bin/sh
# Sets CURRENT_PROJECT_VERSION to the commit count so every commit has a unique, increasing
# build number (App Store Connect rejects re-uploads with a repeated build). Run before archiving.
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
N=$(git rev-list --count HEAD)
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\1\"$N\"/" project.yml
grep -Eq "^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\"$N\"" project.yml || { echo "failed to set the build number in project.yml" >&2; exit 1; }
xcodegen generate -q
echo "build number → $N"
