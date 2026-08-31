#!/usr/bin/env bash
set -uo pipefail

mode="${1:-all}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_rust_channel="$(
    awk -F '"' '/^channel = / { print $2; exit }' "$repo_root/rust-toolchain.toml"
)"
errors=0

report_error() {
    printf 'doctor: %s\n' "$1" >&2
    errors=$((errors + 1))
}

check_xcode() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        report_error "xcodebuild was not found; install Xcode 16 or later."
        return
    fi

    local version_output
    if ! version_output="$(xcodebuild -version 2>&1)"; then
        report_error "full Xcode is not selected; install Xcode 16+ and run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'."
        return
    fi

    local version
    local major
    version="$(printf '%s\n' "$version_output" | awk 'NR == 1 { print $2 }')"
    major="${version%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ ]] || ((major < 16)); then
        report_error "Xcode 16 or later is required; found ${version:-unknown}."
    else
        printf 'doctor: Xcode %s\n' "$version"
    fi

    if ! xcrun --find swiftc >/dev/null 2>&1; then
        report_error "the selected Xcode does not provide swiftc."
    fi
}

check_swift_format() {
    if ! swift format --version >/dev/null 2>&1; then
        report_error "'swift format' is required from the selected Swift toolchain."
    else
        printf 'doctor: %s\n' "$(swift format --version)"
    fi
}

check_rust() {
    local tool
    local rust_version_output
    local actual_rust_version

    for tool in rustc cargo; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            report_error "$tool was not found; install rustup and the repository-pinned Rust toolchain."
        fi
    done

    if command -v rustc >/dev/null 2>&1; then
        if ! rust_version_output="$(rustc --version 2>&1)"; then
            report_error "the repository Rust toolchain is unavailable; run 'rustup toolchain install $expected_rust_channel --profile minimal --component rustfmt --component clippy'."
            return
        fi
        actual_rust_version="$(printf '%s\n' "$rust_version_output" | awk '{ print $2 }')"
        if [[ "$actual_rust_version" != "$expected_rust_channel" ]]; then
            report_error "Rust $expected_rust_channel is required; found $actual_rust_version."
        else
            printf 'doctor: %s\n' "$rust_version_output"
        fi
    fi

    if command -v cargo >/dev/null 2>&1; then
        if ! cargo fmt --version >/dev/null 2>&1; then
            report_error "rustfmt is missing; run 'rustup component add rustfmt'."
        fi
        if ! cargo clippy --version >/dev/null 2>&1; then
            report_error "Clippy is missing; run 'rustup component add clippy'."
        fi
    fi
}

case "$mode" in
    all)
        check_xcode
        check_swift_format
        check_rust
        ;;
    xcode)
        check_xcode
        check_swift_format
        ;;
    rust)
        check_rust
        ;;
    *)
        printf 'usage: %s [all|xcode|rust]\n' "$0" >&2
        exit 2
        ;;
esac

if ((errors > 0)); then
    printf 'doctor: %d prerequisite issue(s) found.\n' "$errors" >&2
    exit 1
fi

printf 'doctor: %s toolchain is ready.\n' "$mode"
