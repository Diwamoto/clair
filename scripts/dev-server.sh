#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
usage: dev-server.sh <status|start|stop> <project-dir> [port]

Manage Clair Node/Vite dev servers so agents do not spawn duplicates.

  status <project-dir> [port]   Check whether a dev server is already listening.
  start  <project-dir> [port]   Start or reuse a dev server. Prints "PID=<pid> URL=<url>".
  stop   <pid>                  Stop a previously started dev server.

Examples:
  dev-server.sh status prototypes/clair-interaction-lab 5173
  dev-server.sh start  prototypes/clair-interaction-lab 5173
  dev-server.sh stop   12345
EOF
}

action="${1:-}"
project_dir="${2:-}"
port="${3:-5173}"

if [[ -z "$action" || -z "$project_dir" ]]; then
    usage >&2
    exit 2
fi

# Resolve relative to repo root when not absolute.
if [[ "$project_dir" != /* ]]; then
    project_dir="$repo_root/$project_dir"
fi

if [[ ! -d "$project_dir" ]]; then
    printf 'dev-server: project directory does not exist: %s\n' "$project_dir" >&2
    exit 1
fi

pid_file="$repo_root/.tmp/dev-server-$(basename "$project_dir").pid"

is_port_open() {
    local p="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an -ptcp 2>/dev/null | grep -q "\.$p .*LISTEN"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1
    fi
}

wait_for_port() {
    local p="$1"
    local tries=0
    while ! is_port_open "$p"; do
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            printf 'dev-server: timed out waiting for port %s to open\n' "$p" >&2
            return 1
        fi
        sleep 1
    done
}

status() {
    if is_port_open "$port"; then
        printf 'dev-server: port %s is already listening (project: %s)\n' "$port" "$project_dir"
        return 0
    fi
    printf 'dev-server: port %s is not listening (project: %s)\n' "$port" "$project_dir"
    return 1
}

start() {
    if is_port_open "$port"; then
        printf 'dev-server: reusing existing dev server on port %s\n' "$port"
        printf 'PID=existing URL=http://127.0.0.1:%s\n' "$port"
        return 0
    fi

    if [[ ! -f "$project_dir/package.json" ]]; then
        printf 'dev-server: no package.json in %s\n' "$project_dir" >&2
        exit 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        printf 'dev-server: npm is not available\n' >&2
        exit 1
    fi

    # Determine the dev command. Prefer "dev" if present, otherwise fall back
    # to "start" for wrangler/vite style projects.
    dev_cmd="dev"
    if ! grep -q '"dev"' "$project_dir/package.json"; then
        if grep -q '"start"' "$project_dir/package.json"; then
            dev_cmd="start"
        fi
    fi

    printf 'dev-server: starting "npm run %s" in %s on port %s\n' "$dev_cmd" "$project_dir" "$port"
    (
        cd "$project_dir"
        PORT="$port" npm run "$dev_cmd" >/dev/null 2>&1 &
        echo $! >"$pid_file"
    )

    if wait_for_port "$port"; then
        server_pid=$(cat "$pid_file" 2>/dev/null || echo "unknown")
        printf 'dev-server: dev server ready (pid %s)\n' "$server_pid"
        printf 'PID=%s URL=http://127.0.0.1:%s\n' "$server_pid" "$port"
    else
        printf 'dev-server: dev server failed to start; see %s/.dev-server.log if present\n' "$project_dir" >&2
        return 1
    fi
}

stop() {
    local target_pid="$1"
    if [[ "$target_pid" == "existing" || -z "$target_pid" ]]; then
        printf 'dev-server: no pid to stop (server was reused, not started)\n'
        return 0
    fi

    if kill -0 "$target_pid" >/dev/null 2>&1; then
        printf 'dev-server: stopping pid %s\n' "$target_pid"
        kill "$target_pid" || true
        # Give it a moment to shut down gracefully.
        for _ in $(seq 1 10); do
            if ! kill -0 "$target_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        if kill -0 "$target_pid" >/dev/null 2>&1; then
            kill -9 "$target_pid" || true
        fi
    else
        printf 'dev-server: pid %s is not running\n' "$target_pid"
    fi

    if [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
    fi
}

case "$action" in
    status)
        status
        ;;
    start)
        start
        ;;
    stop)
        target_pid="${2:-}"
        if [[ -z "$target_pid" ]]; then
            printf 'dev-server: stop requires a pid argument\n' >&2
            usage >&2
            exit 2
        fi
        stop "$target_pid"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
