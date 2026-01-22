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

    if [ -f validate.sh ]; then
        shellcheck validate.sh
    fi

    zig fmt --check src/
    zig build run -- src/**/*.zig

validate:
    ./validate.sh

ci: build test lint
