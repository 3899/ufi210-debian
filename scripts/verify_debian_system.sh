#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TARGET_PARTITION=system
export OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-system}"
exec bash "$PROJECT_ROOT/scripts/verify_debian_cache.sh"
