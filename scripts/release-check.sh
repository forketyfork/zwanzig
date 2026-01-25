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

version_line=$(grep -nE "^[[:space:]]*\\.version[[:space:]]*=" build.zig.zon | head -n1 || true)
if [ -z "$version_line" ]; then
    echo "Failed to locate .version in build.zig.zon" >&2
    exit 1
fi

version=$(printf '%s' "$version_line" | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$version" ]; then
    echo "Failed to parse version from build.zig.zon" >&2
    exit 1
fi

if [ "v$version" != "$tag" ]; then
    echo "Version mismatch: build.zig.zon has $version but tag is $tag" >&2
    exit 1
fi

readme_tags=$(grep -oE "refs/tags/v[0-9]+\.[0-9]+\.[0-9]+" README.md || true)
if [ -n "$readme_tags" ]; then
    mapfile -t uniq_tags < <(printf '%s\n' "$readme_tags" | sed 's#.*refs/tags/##' | sort -u)
    for readme_tag in "${uniq_tags[@]}"; do
        if [ "$readme_tag" != "$tag" ]; then
            echo "README tag mismatch: found $readme_tag, expected $tag" >&2
            exit 1
        fi
    done
else
    echo "Warning: no tag references found in README.md" >&2
fi

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
