#!/usr/bin/env bash
set -uo pipefail

mode="${1:-all}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

case "$mode" in
    all)
        check_xcode
        check_swift_format
        ;;
    xcode)
        check_xcode
        check_swift_format
        ;;
    *)
        printf 'usage: %s [all|xcode]\n' "$0" >&2
        exit 2
        ;;
esac

if ((errors > 0)); then
    printf 'doctor: %d prerequisite issue(s) found.\n' "$errors" >&2
    exit 1
fi

printf 'doctor: %s toolchain is ready.\n' "$mode"
