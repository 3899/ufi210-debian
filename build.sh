#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-ufi210-debian-builder}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/work}"

log() {
    printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

if [[ "${MSM8909_IN_CONTAINER:-0}" == 1 ]]; then
    exec bash "$PROJECT_ROOT/scripts/build_firmware.sh" "$@"
fi

command -v docker >/dev/null 2>&1 \
    || die "未找到 Docker；请安装 Docker Engine 或 Docker Desktop"

log "构建 Docker 镜像：$IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$PROJECT_ROOT"

docker_env=(
    -e MSM8909_IN_CONTAINER=1
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR"
)
for variable in BUILD_ROOT BUILD_TMPFS_SIZE SOURCE_ROOT FORCE RELEASE_VERSION SOURCE_DATE_EPOCH; do
    if [[ -n "${!variable+x}" ]]; then
        docker_env+=(-e "$variable=${!variable}")
    fi
done

log "在容器中构建 Debian for UFI210"
docker run --rm --privileged \
    --tmpfs /build:rw,exec,dev,nosuid,size="${BUILD_TMPFS_SIZE:-6g}" \
    "${docker_env[@]}" \
    -v "$PROJECT_ROOT:$CONTAINER_WORKDIR" \
    -w "$CONTAINER_WORKDIR" \
    "$IMAGE_NAME" "$@"
