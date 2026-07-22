#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [vX.Y.Z]" >&2
}

if [ "$#" -gt 1 ]; then
    usage
    exit 2
fi

release_tag="${1:-}"
if [ -n "$release_tag" ] && [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid tag format: $release_tag" >&2
    usage
    exit 2
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

package_tag="v$version"
if [ -n "$release_tag" ] && [ "$package_tag" != "$release_tag" ]; then
    echo "Version mismatch: build.zig.zon has $version but tag is $release_tag" >&2
    exit 1
fi
expected_tag="${release_tag:-$package_tag}"

check_version_references() {
    local file="$1"
    local description="$2"
    local pattern="$3"
    local -a found_tags=()

    mapfile -t found_tags < <(
        grep -oE "$pattern" "$file" |
            grep -oE "v[0-9]+\\.[0-9]+\\.[0-9]+" |
            sort -u || true
    )

    if [ "${#found_tags[@]}" -eq 0 ]; then
        echo "$file: no $description references found" >&2
        return 1
    fi

    local found_tag
    for found_tag in "${found_tags[@]}"; do
        if [ "$found_tag" != "$expected_tag" ]; then
            echo "$file $description mismatch: found $found_tag, expected $expected_tag" >&2
            return 1
        fi
    done
}

tag_pattern="refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+"
actions_pattern="ZWANZIG_VERSION:[[:space:]]*v[0-9]+\\.[0-9]+\\.[0-9]+"

check_version_references README.md "tagged source URL" "$tag_pattern"
check_version_references docs/USAGE.md "tagged source URL" "$tag_pattern"
check_version_references README.md ZWANZIG_VERSION "$actions_pattern"

echo "Documentation versions match $expected_tag"
