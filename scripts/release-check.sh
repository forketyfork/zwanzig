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

check_doc_tags() {
    local file="$1"
    local found
    found=$(grep -oE "refs/tags/v[0-9]+\.[0-9]+\.[0-9]+" "$file" || true)
    if [ -z "$found" ]; then
        echo "Warning: no tag references found in $file" >&2
        return 0
    fi
    local uniq_tags
    mapfile -t uniq_tags < <(printf '%s\n' "$found" | sed 's#.*refs/tags/##' | sort -u)
    for found_tag in "${uniq_tags[@]}"; do
        if [ "$found_tag" != "$tag" ]; then
            echo "$file tag mismatch: found $found_tag, expected $tag" >&2
            return 1
        fi
    done
}

check_doc_tags README.md
check_doc_tags docs/USAGE.md

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
