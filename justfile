default:
    @just --list

build:
    zig build

test:
    zig build test

run:
    zig build run

run-release:
    zig build run -Doptimize=ReleaseFast

fmt:
    #!/usr/bin/env bash
    set -euo pipefail

    zig_version="$(zig version)"
    if [ "$zig_version" != "0.15.2" ]; then
        echo "zig fmt is canonical under Zig 0.15.2; use 'nix develop -c just fmt'" >&2
        exit 1
    fi
    zig fmt src

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s globstar

    if [ -f validate.sh ]; then
        shellcheck validate.sh
    fi
    shellcheck scripts/*.sh
    ./scripts/check-doc-versions.sh

    zig_version="$(zig version)"
    case "$zig_version" in
        0.15.2)
            zig fmt --check src/
            ;;
        0.16.0)
            ;;
        *)
            echo "unsupported Zig formatter version: $zig_version" >&2
            exit 1
            ;;
    esac

    if [ -n "${CI:-}" ]; then
        zig build run -- --use-widening --format sarif src/**/*.zig > results.sarif || true
    else
        zig build run -- --use-widening src/**/*.zig
    fi

validate:
    ./validate.sh

ci: build test lint

release-check TAG:
    ./scripts/release-check.sh {{TAG}}
