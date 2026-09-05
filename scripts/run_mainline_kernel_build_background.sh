#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$PROJECT_ROOT/out/mainline/kernel"
BUILD_DIR="${BUILD_DIR:-/build/msm8909-mainline-wcnss}"
SOURCE_ROOT="${SOURCE_ROOT:-$PROJECT_ROOT/.build/msm8909-kernel-source}"
BUILD_TMPFS_SIZE="${BUILD_TMPFS_SIZE:-3072M}"
LOG_FILE="$STATE_DIR/build-formal.log"
PID_FILE="$STATE_DIR/build-formal.pid"
STATUS_FILE="$STATE_DIR/build-formal.status"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

ensure_build_mount() {
    mkdir -p /build
    if ! mountpoint -q /build; then
        mount -t tmpfs -o "size=$BUILD_TMPFS_SIZE,mode=0755,exec,dev,nosuid" tmpfs /build
    else
        mount -o "remount,size=$BUILD_TMPFS_SIZE" /build
    fi
}

is_running() {
    local pid
    [[ -s "$PID_FILE" ]] || return 1
    pid="$(cat "$PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

run_build() {
    local rc=0

    trap 'rc=$?; printf "exit_code=%s\ncompleted_at=%s\n" "$rc" "$(date -Iseconds)" > "$STATUS_FILE"' EXIT
    cd "$PROJECT_ROOT"
    FORCE=1 BUILD_DIR="$BUILD_DIR" SOURCE_ROOT="$SOURCE_ROOT" \
        bash scripts/build_mainline_kernel.sh
}

start_build() {
    mkdir -p "$STATE_DIR"
    if is_running; then
        die "已有内核构建正在运行，PID=$(cat "$PID_FILE")"
    fi

    ensure_build_mount
    rm -f "$PID_FILE" "$STATUS_FILE"
    printf 'running\nstarted_at=%s\n' "$(date -Iseconds)" > "$STATUS_FILE"
    nohup setsid "$0" run > "$LOG_FILE" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$PID_FILE"
    printf '已启动后台内核构建，PID=%s\n日志=%s\n状态=%s\n' \
        "$!" "$LOG_FILE" "$STATUS_FILE"
}

show_status() {
    if is_running; then
        printf 'running pid=%s\n' "$(cat "$PID_FILE")"
    elif [[ -s "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        printf 'not_started\n'
    fi
    [[ ! -f "$LOG_FILE" ]] || tail -n 20 "$LOG_FILE"
}

wait_build() {
    local pid rc

    if is_running; then
        pid="$(cat "$PID_FILE")"
        tail --pid="$pid" -f /dev/null
    fi

    show_status
    if grep -q '^exit_code=' "$STATUS_FILE" 2>/dev/null; then
        rc="$(sed -n 's/^exit_code=//p' "$STATUS_FILE")"
        [[ "$rc" =~ ^[0-9]+$ ]] || die "构建状态中的退出码无效：$rc"
        return "$rc"
    fi
    die "构建未结束或没有最终退出状态"
}

case "${1:-status}" in
    start) start_build ;;
    run) run_build ;;
    status) show_status ;;
    wait) wait_build ;;
    *) die "用法：$0 start|status|wait" ;;
esac
