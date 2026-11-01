#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/derived/RecoveryFixtures build/derived/ModuleCache.noindex
swiftc -parse-as-library -module-cache-path build/derived/ModuleCache.noindex \
  Shared/Models/*.swift Shared/Providers/*.swift Shared/Networking/*.swift \
  Shared/Search/*.swift Shared/Chat/*.swift Shared/Storage/*.swift Shared/Sync/*.swift \
  Tests/RecoveryFixtures/main.swift -o build/derived/RecoveryFixtures/run
WA_SEARCH_FIXTURE_DIRECTORY="${PWD}/build/derived/RecoveryFixtures" build/derived/RecoveryFixtures/run
