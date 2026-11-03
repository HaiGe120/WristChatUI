#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/derived/VoiceFixtures build/derived/ModuleCache.noindex
swiftc -parse-as-library -module-cache-path build/derived/ModuleCache.noindex \
  Shared/Voice/VoicePreferences.swift Shared/Voice/VoiceTextFormatting.swift \
  Tests/VoiceFixtures/main.swift -o build/derived/VoiceFixtures/run
build/derived/VoiceFixtures/run
