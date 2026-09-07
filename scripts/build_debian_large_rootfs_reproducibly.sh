#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TARGET_PARTITION=large-rootfs
export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_debian_cache.sh"
export VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify_debian_cache.sh"
exec bash "$PROJECT_ROOT/scripts/build_debian_cache_reproducibly.sh"
