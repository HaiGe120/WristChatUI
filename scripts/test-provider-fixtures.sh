#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p ./build/derived/provider-fixtures-module-cache
xcrun swiftc -swift-version 5 -module-cache-path ./build/derived/provider-fixtures-module-cache \
  Shared/Models/MessageRole.swift Shared/Models/ChatMessage.swift Shared/Models/AIProviderType.swift \
  Shared/Models/EndpointConfig.swift Shared/Networking/SSEParser.swift Shared/Networking/StreamingHTTP.swift \
  Shared/Providers/AIProvider.swift Shared/Providers/OpenAIProvider.swift Shared/Providers/AnthropicProvider.swift \
  Shared/Providers/ProviderRegistry.swift Tests/ProviderFixtures/main.swift \
  -o ./build/derived/provider-fixtures
./build/derived/provider-fixtures
