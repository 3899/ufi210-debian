#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TARGET_PARTITION=large-rootfs
export OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-large-rootfs}"
exec bash "$PROJECT_ROOT/scripts/verify_debian_cache.sh"
