#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p ./build/derived/search-fixtures-module-cache
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path ./build/derived/search-fixtures-module-cache \
  Shared/Models/MessageRole.swift Shared/Models/ChatMessage.swift Shared/Models/AIProviderType.swift \
  Shared/Models/EndpointConfig.swift Shared/Providers/AIProvider.swift Shared/Search/*.swift \
  Tests/SearchFixtures/main.swift -o ./build/derived/search-fixtures
./build/derived/search-fixtures
