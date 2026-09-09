#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_PARTITION="${TARGET_PARTITION:-cache}"
RESUME_VERIFIED_A="${RESUME_VERIFIED_A:-0}"
DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN="${DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN:-}"
case "$TARGET_PARTITION" in
    cache|system|large-rootfs) ;;
    *)
        printf '错误：TARGET_PARTITION 只允许 cache、system 或 large-rootfs\n' >&2
        exit 1
        ;;
esac
case "$RESUME_VERIFIED_A" in
    0|1) ;;
    *)
        printf '错误：RESUME_VERIFIED_A 只允许 0 或 1\n' >&2
        exit 1
        ;;
esac
STATE_DIR="$PROJECT_ROOT/out/mainline/debian-${TARGET_PARTITION}-reproducibility-state"
BUILD_ROOT="${BUILD_ROOT:-/build/msm8909-debian-${TARGET_PARTITION}-reproducibility}"
LOG_FILE="$STATE_DIR/build.log"
PID_FILE="$STATE_DIR/build.pid"
STATUS_FILE="$STATE_DIR/build.status"
RUNNER_FILE="$STATE_DIR/runner.sh"
REPRO_SCRIPT_FILE="$STATE_DIR/build-debian-cache-reproducibly.sh"
BUILD_SCRIPT_FILE="$STATE_DIR/build-debian-cache.sh"
VERIFY_SCRIPT_FILE="$STATE_DIR/verify-debian-cache.sh"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

is_running() {
    local pid
    [[ -s "$PID_FILE" ]] || return 1
    pid="$(cat "$PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

ensure_build_mount() {
    local test_dir

    mkdir -p /build
    if ! mountpoint -q /build; then
        mount -t tmpfs -o size=1536M,mode=0755,exec,dev,nosuid tmpfs /build
    fi
    test_dir="/build/.device-test-$$"
    mkdir -p "$test_dir"
    if ! mknod "$test_dir/null" c 1 3 || ! printf 'ok\n' > "$test_dir/null"; then
        rm -rf -- "$test_dir"
        die "/build 不允许设备节点，不能运行 debootstrap"
    fi
    rm -rf -- "$test_dir"
}

stage_scripts() {
    install -m 0755 "${BASH_SOURCE[0]}" "$RUNNER_FILE.tmp"
    install -m 0755 "$PROJECT_ROOT/scripts/build_debian_cache_reproducibly.sh" "$REPRO_SCRIPT_FILE.tmp"
    install -m 0755 "$PROJECT_ROOT/scripts/build_debian_cache.sh" "$BUILD_SCRIPT_FILE.tmp"
    install -m 0755 "$PROJECT_ROOT/scripts/verify_debian_cache.sh" "$VERIFY_SCRIPT_FILE.tmp"
    mv -f "$RUNNER_FILE.tmp" "$RUNNER_FILE"
    mv -f "$REPRO_SCRIPT_FILE.tmp" "$REPRO_SCRIPT_FILE"
    mv -f "$BUILD_SCRIPT_FILE.tmp" "$BUILD_SCRIPT_FILE"
    mv -f "$VERIFY_SCRIPT_FILE.tmp" "$VERIFY_SCRIPT_FILE"
}

run_build() {
    local rc=0

    trap 'rc=$?; printf "exit_code=%s\ncompleted_at=%s\n" "$rc" "$(date -Iseconds)" > "$STATUS_FILE"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cd "$PROJECT_ROOT"
    bash scripts/register_qemu_arm_binfmt.sh
    PROJECT_ROOT_OVERRIDE="$PROJECT_ROOT" \
    TARGET_PARTITION="$TARGET_PARTITION" \
    RESUME_VERIFIED_A="$RESUME_VERIFIED_A" \
    BUILD_ROOT="$BUILD_ROOT" \
    DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN="$DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN" \
    BUILD_SCRIPT="$BUILD_SCRIPT_FILE" \
    VERIFY_SCRIPT="$VERIFY_SCRIPT_FILE" \
        bash "$REPRO_SCRIPT_FILE"
}

start_build() {
    mkdir -p "$STATE_DIR"
    if is_running; then
        die "已有双构建正在运行，PID=$(cat "$PID_FILE")"
    fi
    ensure_build_mount
    rm -f "$PID_FILE" "$STATUS_FILE" "$LOG_FILE"
    stage_scripts
    printf 'running\nstarted_at=%s\n' "$(date -Iseconds)" > "$STATUS_FILE"
    nohup env \
        PROJECT_ROOT_OVERRIDE="$PROJECT_ROOT" \
        TARGET_PARTITION="$TARGET_PARTITION" \
        RESUME_VERIFIED_A="$RESUME_VERIFIED_A" \
        BUILD_ROOT="$BUILD_ROOT" \
        DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN="$DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN" \
        setsid "$RUNNER_FILE" run > "$LOG_FILE" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$PID_FILE"
    printf '已启动 %s 固定快照双构建，PID=%s\n日志=%s\n状态=%s\n' \
        "$TARGET_PARTITION" "$!" "$LOG_FILE" "$STATUS_FILE"
}

show_status() {
    if is_running; then
        printf 'running pid=%s\n' "$(cat "$PID_FILE")"
    elif [[ -s "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        printf 'not_started\n'
    fi
    [[ ! -f "$LOG_FILE" ]] || tail -n 30 "$LOG_FILE"
}

wait_build() {
    local pid rc

    if is_running; then
        pid="$(cat "$PID_FILE")"
        tail --pid="$pid" -f /dev/null
    fi
    show_status
    rc="$(sed -n 's/^exit_code=//p' "$STATUS_FILE" 2>/dev/null || true)"
    [[ "$rc" =~ ^[0-9]+$ ]] || die "双构建没有最终退出状态"
    return "$rc"
}

case "${1:-status}" in
    start) start_build ;;
    run) run_build ;;
    status) show_status ;;
    wait) wait_build ;;
    *) die "用法：$0 start|status|wait" ;;
esac
