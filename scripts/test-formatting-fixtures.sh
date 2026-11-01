#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/derived/FormattingFixtures/module-cache
xcrun swiftc -swift-version 5 -module-cache-path build/derived/FormattingFixtures/module-cache \
  Shared/Models/MessageFormatting.swift Tests/FormattingFixtures/main.swift \
  -o build/derived/FormattingFixtures/run
build/derived/FormattingFixtures/run
