#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${PORTLIGHT_BUILD_DIR:-$ROOT/.build}"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD/ModuleCache"
OPTIONS=(--package-path "$ROOT" --scratch-path "$BUILD" --cache-path "$BUILD/cache" --config-path "$BUILD/config" --security-path "$BUILD/security" --disable-sandbox)
swift build "${OPTIONS[@]}" --product PortlightChecks
BIN="$(swift build "${OPTIONS[@]}" --show-bin-path)"
if [[ "${1:-}" == "--live" ]]; then
    export PORTLIGHT_INTEGRATION=1
    if command -v node >/dev/null 2>&1; then export PORTLIGHT_TEST_NODE="$(command -v node)"; fi
fi
"$BIN/PortlightChecks"
