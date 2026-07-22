#!/usr/bin/env bash
set -euo pipefail
shopt -s globstar

usage() {
    echo "Usage: $0 vX.Y.Z" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

tag="$1"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid tag format: $tag" >&2
    usage
    exit 2
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit or stash changes before releasing." >&2
    exit 1
fi

./scripts/check-doc-versions.sh "$tag"

if command -v just >/dev/null 2>&1; then
    just ci
else
    echo "just not found; running zig build/test/lint equivalents" >&2
    zig build
    zig build test
    zig fmt --check src/
    zig build run -- src/**/*.zig
fi

echo "Release checks passed for $tag"
