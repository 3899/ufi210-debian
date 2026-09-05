#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TARGET_PARTITION=system
export BUILD_DIR="${BUILD_DIR:-/build/msm8909-debian-system}"
export OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-system}"
exec bash "$PROJECT_ROOT/scripts/build_debian_cache.sh"
