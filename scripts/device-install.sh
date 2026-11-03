#!/usr/bin/env bash
# Build and install the iOS app, including its embedded Watch app, onto a
# connected physical iPhone. The build product is staged outside Documents
# before install so FileProvider/Finder xattrs cannot poison code signing.
# The current distributable configuration also omits Apple's restricted
# CarPlay entitlement while the capability request is awaiting approval.
# WA_DEVICE_VOICE_ONLY=1 remains supported for older local test workflows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
PROJECT="${ROOT}/WristAssistant.xcodeproj"
SCHEME="WristAssistant"
DERIVED="${ROOT}/build/derived"
APP_PATH="${DERIVED}/Build/Products/Debug-iphoneos/WristAssistant.app"
STAGE_DIR="/tmp/WristAssistantDeviceInstall"
STAGED_APP="${STAGE_DIR}/WristAssistant.app"
LOG_DIR="${ROOT}/build/device-install"
DEVICE="${1:-}"
VOICE_ONLY="${WA_DEVICE_VOICE_ONLY:-0}"

XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="${XCODE_DEV}/usr/bin:${XCODE_DEV}/bin:${PATH}"
export DEVELOPER_DIR="${XCODE_DEV}"

log() { printf '[device-install.sh %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

resolve_device() {
  xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c '
import json, sys
matches = []
for device in json.load(sys.stdin).get("result", {}).get("devices", []):
    properties = device.get("properties", {})
    hardware = properties.get("hardware", device.get("hardwareProperties", {}))
    connection = properties.get("connection", device.get("connectionProperties", {}))
    if hardware.get("reality") == "physical" and hardware.get("deviceType") == "iPhone" and connection.get("pairingState") == "paired":
        matches.append(device["identifier"])
if len(matches) == 1:
    print(matches[0])
'
}

if [[ -z "${DEVICE}" ]]; then
  DEVICE="$(resolve_device)"
fi

if [[ -z "${DEVICE}" ]]; then
  log "ERROR: no unique paired physical iPhone found; supply its device identifier."
  xcrun devicectl list devices || true
  exit 2
fi

mkdir -p "${LOG_DIR}"

log "xcodegen generate"
( cd "${ROOT}" && xcodegen generate >/dev/null )

SIGNING_SETTINGS=("OTHER_CODE_SIGN_FLAGS=--strip-disallowed-xattrs")
if [[ "${VOICE_ONLY}" == 1 ]]; then
  # A development profile without Apple's restricted CarPlay capability can
  # still test phone/Watch voice. Keep iCloud and omit only CarPlay.
  TEST_ENTITLEMENTS="${LOG_DIR}/voice-only.entitlements"
  python3 - "${ROOT}/App/WristAssistant.entitlements" "${TEST_ENTITLEMENTS}" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
entitlements.pop('com.apple.developer.carplay-voice-based-conversation', None)
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(entitlements, destination)
PY
  SIGNING_SETTINGS+=("WRIST_DEVICE_ENTITLEMENTS_PATH=${TEST_ENTITLEMENTS}")
  log "voice-only device test: CarPlay capability omitted from this Debug signature"
elif [[ "${VOICE_ONLY}" != 0 ]]; then
  log "ERROR: WA_DEVICE_VOICE_ONLY must be 0 or 1"
  exit 2
fi

log "xcodebuild Debug iphoneos -> ${DERIVED}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  "${SIGNING_SETTINGS[@]}" \
  build 2>&1 | tee "${LOG_DIR}/build.log" | tail -40

if [[ ! -d "${APP_PATH}" ]]; then
  log "ERROR: expected app at ${APP_PATH}"
  exit 1
fi

log "stage app outside Documents -> ${STAGED_APP}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
ditto --noextattr --noqtn "${APP_PATH}" "${STAGED_APP}"
find "${STAGED_APP}" -exec xattr -c {} \;

log "verify staged app signature"
codesign --verify --deep --strict --verbose=4 "${STAGED_APP}" 2>&1 \
  | tee "${LOG_DIR}/codesign-verify.log"

log "connect to device before transfer (wireless tunnels can expire during build)"
xcrun devicectl device info details \
  --device "${DEVICE}" --quiet --timeout 30 \
  --json-output "${LOG_DIR}/device-before-install.json"

log "install to device ${DEVICE}"
xcrun devicectl device install app \
  --device "${DEVICE}" \
  "${STAGED_APP}" \
  --json-output "${LOG_DIR}/install.json" \
  --log-output "${LOG_DIR}/install.log"

log "installed ${STAGED_APP}"
