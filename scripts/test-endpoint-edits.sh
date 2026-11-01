#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/derived/endpoint-edit-fixtures-module-cache
xcrun swiftc -swift-version 5 -module-cache-path build/derived/endpoint-edit-fixtures-module-cache \
  Shared/Models/AIProviderType.swift Shared/Models/EndpointConfig.swift Shared/Models/EndpointProfileEdit.swift \
  Tests/EndpointEditFixtures/main.swift -o build/derived/endpoint-edit-fixtures
build/derived/endpoint-edit-fixtures
