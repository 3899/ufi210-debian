#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TARGET_PARTITION=system
exec bash "$PROJECT_ROOT/scripts/build_debian_cache_reproducibly.sh"
