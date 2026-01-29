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
    zig fmt src

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s globstar

    if [ -f validate.sh ]; then
        shellcheck validate.sh
    fi
    shellcheck scripts/*.sh

    zig fmt --check src/
    zig build run -- --use-widening src/**/*.zig

validate:
    ./validate.sh

ci: build test lint

release-check TAG:
    ./scripts/release-check.sh {{TAG}}
