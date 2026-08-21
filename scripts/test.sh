#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -d)/DualPadMapper-test"

swiftc "$PROJECT_ROOT/Sources/DualPadMapper/main.swift" \
  -o "$TEST_BINARY" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework IOKit

"$TEST_BINARY" --self-test
