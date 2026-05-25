#!/bin/sh

# Work around Zig 0.15.2 failing to link against the macOS 26.x SDK family,
# whose top-level libSystem.tbd no longer advertises arm64-macos.
# Upstream tracker: https://codeberg.org/ziglang/zig/issues/31756
#
# Designed to be sourced from the Nix dev shell's shellHook so the exports
# below reach the calling environment. If executed directly the function body
# still runs but PATH/DEVELOPER_DIR changes will not propagate.
#
# Remove this once Zwanzig no longer uses Zig 0.15.2, or once Zig's Darwin
# SDK discovery / linker handles the arm64e-only stub layout correctly.

_zwanzig_setup_macos_sdk_workaround() {
    legacy_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

    if [ ! -d "$legacy_sdk" ]; then
        return 0
    fi

    active_sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null) || return 0
    active_stub="$active_sdk/usr/lib/libSystem.tbd"

    if [ ! -f "$active_stub" ]; then
        return 0
    fi

    if sed -n '1,5p' "$active_stub" | grep -q 'arm64-macos'; then
        return 0
    fi

    project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    workaround_root="$project_root/.tmp/macos-sdk-workaround"
    bin_dir="$workaround_root/bin"
    developer_dir="$workaround_root/developer"
    developer_bin_dir="$developer_dir/usr/bin"
    sdk_link="$developer_dir/SDKs/MacOSX.sdk"

    mkdir -p "$bin_dir" "$developer_dir/SDKs" "$developer_bin_dir"
    ln -sfn "$legacy_sdk" "$sdk_link"

    xcrun_wrapper="$developer_bin_dir/xcrun"
    cat > "$xcrun_wrapper" <<EOF
#!/bin/sh

if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ] && [ "\$#" -eq 3 ]; then
    printf '%s\n' '$legacy_sdk'
    exit 0
fi

exec env DEVELOPER_DIR= /usr/bin/xcrun "\$@"
EOF
    chmod +x "$xcrun_wrapper"
    ln -sfn "$xcrun_wrapper" "$bin_dir/xcrun"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) PATH="$bin_dir:$PATH" ;;
    esac
    export PATH

    DEVELOPER_DIR="$developer_dir"
    export DEVELOPER_DIR

    echo "Applied Zig 0.15.2 macOS SDK workaround using $legacy_sdk"
}

_zwanzig_setup_macos_sdk_workaround
unset -f _zwanzig_setup_macos_sdk_workaround
