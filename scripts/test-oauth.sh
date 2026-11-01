#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wristassistant-oauth.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
swiftc -parse-as-library -module-cache-path "${TEST_DIR}/module-cache" \
  Shared/Auth/*.swift Tests/Auth/main.swift -o "${TEST_DIR}/auth-fixtures"
"${TEST_DIR}/auth-fixtures"
