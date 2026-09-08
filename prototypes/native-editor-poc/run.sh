#!/bin/sh
set -eu
cd "$(dirname "$0")"
lock="$PWD/.build/poc-run.lock"
if ! mkdir "$lock" 2>/dev/null; then
    if [ -f "$lock/pid" ] && kill -0 "$(cat "$lock/pid")" 2>/dev/null; then
        echo 'PoC already running. Close its window before starting another mode.' >&2
        exit 1
    fi
    rm -f "$lock/pid"
    rmdir "$lock"
    mkdir "$lock"
fi
echo $$ > "$lock/pid"
child=''
cleanup() {
    if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi
    rm -f "$lock/pid"
    rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
python3 package-app.py
"$PWD/.build/Clair Native PoC.app/Contents/MacOS/NativeEditorPoC" "$@" &
child=$!
wait "$child"
