#!/usr/bin/env bash
# Build, validate and package the combined iOS + watchOS App Store distribution.
# No simulator is started. Xcode intermediates always remain in build/derived.
#
# Usage:
#   scripts/release.sh          # archive, export and package; no upload
#   scripts/release.sh upload   # additionally upload using the existing ASC API key
#
# Upload-only credentials are supplied by environment, never written to source:
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID, API_PRIVATE_KEYS_DIR
# Legacy Apple ID uploads may use APPLE_ID and APP_SPECIFIC_PWD instead.
# Output is a fresh directory under build/release/<version>-<build>-<UTC-run>.
# The IPA and standalone Watch app are distribution products; they are not
# unrestricted sideload installers. See the generated INSTALLATION.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"
PROJECT="${ROOT}/WristAssistant.xcodeproj"
SCHEME="WristAssistant"
DERIVED="${ROOT}/build/derived"
EXPORT_OPTIONS="${SCRIPT_DIR}/ExportOptions-AppStore.plist"
MODE="${1:-build}"
case "${MODE}" in build|upload) ;; *) printf 'Usage: scripts/release.sh [build|upload]\n' >&2; exit 2 ;; esac

XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="${XCODE_DEV}/usr/bin:${XCODE_DEV}/bin:${PATH}"
export DEVELOPER_DIR="${XCODE_DEV}"
log() { printf '[release.sh %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Avoid publishing an artifact that cannot be tied to the committed source.
if [[ "${ALLOW_DIRTY_RELEASE:-0}" != 1 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "ERROR: commit the release source/version first, or set ALLOW_DIRTY_RELEASE=1 for a local validation build."
    exit 2
  fi
  untracked_source="$(git ls-files --others --exclude-standard -- App Shared Watch WatchWidgets scripts project.yml)"
  if [[ -n "${untracked_source}" ]]; then
    log "ERROR: untracked application/release source must be reviewed and committed first."
    exit 2
  fi
fi

VERSION="$(awk '/^    MARKETING_VERSION:/ { sub(/^    MARKETING_VERSION: */, ""); gsub(/"/, ""); print; exit }' project.yml)"
BUILD="$(awk '/^    CURRENT_PROJECT_VERSION:/ { sub(/^    CURRENT_PROJECT_VERSION: */, ""); gsub(/"/, ""); print; exit }' project.yml)"
if [[ ! "${VERSION}" =~ ^[0-9]+([.][0-9]+){0,2}$ || ! "${BUILD}" =~ ^[0-9]+$ ]]; then
  log "ERROR: expected numeric MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml."
  exit 2
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${ROOT}/build/release/${VERSION}-${BUILD}-${RUN_ID}"
ARCHIVE_PATH="${OUTPUT_DIR}/WristChatUI.xcarchive"
EXPORT_DIR="${OUTPUT_DIR}/export"
ASSET_DIR="${OUTPUT_DIR}/github-assets"
mkdir -p "${OUTPUT_DIR}" "${EXPORT_DIR}" "${ASSET_DIR}"
printf '%s\n' "${OUTPUT_DIR}" > "${ROOT}/build/release/latest-output.txt"

log "xcodegen generate"
xcodegen generate 2>&1 | tee "${OUTPUT_DIR}/project-generation.log"
log "archive -> ${ARCHIVE_PATH}"
# Release signing in project.yml is manual; ExportOptions uses the same
# certificate and three explicit App Store profile mappings.
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED}" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  OTHER_CODE_SIGN_FLAGS="--strip-disallowed-xattrs" \
  archive 2>&1 | tee "${OUTPUT_DIR}/archive.log" | tail -45

log "export App Store distribution"
xcodebuild \
  -exportArchive \
  -allowProvisioningUpdates \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  2>&1 | tee "${OUTPUT_DIR}/export.log" | tail -35

# Validate the exported artifact, not a cached archive or simulator product.
python3 "${SCRIPT_DIR}/package-release.py" \
  --archive "${ARCHIVE_PATH}" --export "${EXPORT_DIR}" --output "${ASSET_DIR}" \
  --version "${VERSION}" --build "${BUILD}" --commit "${SOURCE_COMMIT}" \
  2>&1 | tee "${OUTPUT_DIR}/package.log"
IPA_PATH="${ASSET_DIR}/WristChatUI-${VERSION}-${BUILD}-iOS-with-watchOS.ipa"
log "distribution assets ready: ${ASSET_DIR}"

if [[ "${MODE}" == upload ]]; then
  if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    log "upload App Store distribution using existing API-key authentication"
    xcrun altool --upload-app -f "${IPA_PATH}" -t ios \
      --apiKey "${ASC_API_KEY_ID}" --apiIssuer "${ASC_API_ISSUER_ID}" \
      --output-format json 2>&1 | tee "${OUTPUT_DIR}/upload.log"
  elif [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PWD:-}" ]]; then
    log "upload App Store distribution using Apple ID authentication"
    xcrun altool --upload-app -f "${IPA_PATH}" -t ios \
      -u "${APPLE_ID}" -p '@env:APP_SPECIFIC_PWD' \
      --output-format json 2>&1 | tee "${OUTPUT_DIR}/upload.log"
  else
    log "ERROR: upload requires existing ASC_API_KEY_ID/ASC_API_ISSUER_ID or APPLE_ID/APP_SPECIFIC_PWD credentials."
    log "The validated local artifact is preserved at ${IPA_PATH}."
    exit 2
  fi
  log "upload command completed; processing/review status must be read from App Store Connect."
fi
