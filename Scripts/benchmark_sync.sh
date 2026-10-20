#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/threadline-sync-benchmark.XXXXXX")"
trap 'rm -f "$BENCHMARK_DIR/benchmark"; rmdir "$BENCHMARK_DIR" 2>/dev/null || true' EXIT
cd "$ROOT_DIR"

# Build the same optimized core as the app without touching SwiftPM's build
# products. All conversations, keys, sync files and databases are synthetic.
xcrun swiftc -O -parse-as-library -swift-version 6 \
    -module-name ConversationCore -target arm64-apple-macosx14.0 \
    -I Sources/CSQLite Scripts/benchmark_sync.swift \
    Sources/ConversationCore/*.swift Sources/ConversationCore/*/*.swift \
    -lsqlite3 -o "$BENCHMARK_DIR/benchmark"
"$BENCHMARK_DIR/benchmark" "$BENCHMARK_DIR"
