#!/usr/bin/env bash
# scripts/sim.sh — leak-proof simulator workflow for WristAssistant.
#
# Why this exists: an earlier Codex job booted a simulator, launched the
# app multiple times with `simctl launch --console-pty … &`, never shut
# anything down, and left ~22 GB of RSS behind across SimulatorTrampoline
# instances, orphaned dyld cache pages, and three live WristAssistant
# processes inside the guest. This script makes the safe pattern the
# only path.
#
# Rules enforced:
#   * `xcrun simctl shutdown all` is the very first AND very last step.
#   * `simctl launch` is called exactly once per `boot` invocation.
#   * No `--console-pty`, no `&` on launch.
#   * The build always lands in a single derivedDataPath: ./build/derived.
#
# Usage:
#   scripts/sim.sh build            # build only, no sim interaction
#   scripts/sim.sh boot             # boot sim + install + launch + screenshot
#   scripts/sim.sh watch-build      # build watch app only
#   scripts/sim.sh watch-boot       # boot watch sim + install + launch + screenshot
#   WATCH_LAUNCH_ARGS="--auto-new-chat" scripts/sim.sh watch-boot
#   scripts/sim.sh watch-screenshot PATH
#   scripts/sim.sh screenshot PATH  # take a screenshot of the booted sim
#   scripts/sim.sh teardown         # terminate app + shutdown all sims
#   scripts/sim.sh status           # report booted sims + RSS of sim procs

set -euo pipefail

# ---- config ---------------------------------------------------------------

PROJECT="WristAssistant.xcodeproj"
SCHEME="WristAssistant"
DEVICE_NAME="${SIM_DEVICE_NAME:-iPhone 17}"
WATCH_DEVICE_NAME="${SIM_WATCH_DEVICE_NAME:-Apple Watch Series 11 (46mm)}"
# Section header in `simctl list devices` is "-- iOS 26.5 --".
DEVICE_OS_HEADER="-- iOS"
WATCH_DEVICE_OS_HEADER="-- watchOS"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."
DERIVED="${SCRIPT_DIR}/../build/derived"
BUNDLE_ID="com.wristassistant.app"
WATCH_BUNDLE_ID="com.wristassistant.app.watchkitapp"
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/WristAssistant.app"
WATCH_APP_PATH="${DERIVED}/Build/Products/Debug-watchsimulator/WristAssistantWatch.app"
LOG_DIR="${DERIVED}/sim-logs"

XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="${XCODE_DEV}/usr/bin:${XCODE_DEV}/bin:${PATH}"
export DEVELOPER_DIR="${XCODE_DEV}"

mkdir -p "${LOG_DIR}"

log() { printf '[sim.sh %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# A stalled CoreSimulator command must not hold a boot session open indefinitely.
# Alarm survives exec; EXIT cleanup still owns app termination and simulator shutdown.
simctl_bounded() {
  local limit=30
  case "$1" in
    bootstatus) limit=120 ;;
    install) limit=60 ;;
    launch) limit=45 ;;
    terminate) limit=10 ;;
  esac
  limit="${SIM_COMMAND_TIMEOUT_SECONDS:-${limit}}"
  if [[ ! "${limit}" =~ ^[1-9][0-9]*$ || "${limit}" -gt 180 ]]; then
    log "ERROR: invalid simulator command timeout"
    return 2
  fi
  /usr/bin/perl -e '$sim_timeout=shift; alarm $sim_timeout; exec @ARGV or die "cannot run simulator command\n"' "${limit}" xcrun simctl "$@"
}


# Find the UDID of ${DEVICE_NAME} under the iOS section.
# Output format from `simctl list devices available`:
#     == Devices ==
#     -- iOS 26.5 --
#         iPhone 17 (D8A36AF2-8154-4ED8-96CE-BF6B5C6424CA) (Shutdown)
resolve_device_udid() {
  simctl_bounded list devices available | awk -v dev="${DEVICE_NAME}" '
    $0 ~ "^-- iOS" { in_ios = 1; next }
    /^-- /         { in_ios = 0; next }
    in_ios {
      prefix = "    " dev " ("
      n = index($0, prefix)
      if (n > 0) {
        rest = substr($0, n + length(prefix))
        sub(/\).*/, "", rest)
        print rest
        exit
      }
    }
  '
}

# Find the UDID of ${WATCH_DEVICE_NAME} under the watchOS section.
resolve_watch_udid() {
  simctl_bounded list devices available | awk -v dev="${WATCH_DEVICE_NAME}" '
    $0 ~ "^-- watchOS" { in_watch = 1; next }
    /^-- /            { in_watch = 0; next }
    in_watch {
      prefix = "    " dev " ("
      n = index($0, prefix)
      if (n > 0) {
        rest = substr($0, n + length(prefix))
        sub(/\).*/, "", rest)
        print rest
        exit
      }
    }
  '
}

cmd_build() {
  log "build -> ${DERIVED}"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=${DEVICE_NAME}" \
    -derivedDataPath "${DERIVED}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    OTHER_CODE_SIGN_FLAGS="--strip-disallowed-xattrs" \
    build 2>&1 | tee "${LOG_DIR}/build.log" | tail -30
  log "build done: ${APP_PATH}"
}

cmd_watch_build() {
  log "watch build -> ${DERIVED}"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "WristAssistantWatch" \
    -configuration Debug \
    -destination "generic/platform=watchOS Simulator" \
    -derivedDataPath "${DERIVED}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    OTHER_CODE_SIGN_FLAGS="--strip-disallowed-xattrs" \
    build 2>&1 | tee "${LOG_DIR}/watch-build.log" | tail -30
  log "watch build done: ${WATCH_APP_PATH}"
}

cmd_boot() {
  install_cleanup_traps
  log "shutdown all (precaution)"
  cmd_teardown

  local udid
  udid="$(resolve_device_udid)"
  if [[ -z "${udid}" ]]; then
    log "ERROR: no ${DEVICE_NAME} device under ${DEVICE_OS_HEADER}"
    log "available iOS devices:"
    simctl_bounded list devices available | awk '/^-- iOS/,/^-- / { print "    " $0 }'
    exit 2
  fi
  log "device: ${DEVICE_NAME} (${udid})"

  cmd_build

  echo "${udid}" > "${LOG_DIR}/udid"
  log "boot"
  simctl_bounded boot "${udid}"
  simctl_bounded bootstatus "${udid}" -b 2>&1 | tail -3

  log "post-build: fix embedded watch app UIDeviceFamily (=4)"
  local watch_plist="${APP_PATH}/Watch/WristAssistantWatch.app/Info.plist"
  if [[ -f "${watch_plist}" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :UIDeviceFamily" "${watch_plist}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" "${watch_plist}"
    /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily: integer 4" "${watch_plist}"
  fi

  log "install"
  simctl_bounded install "${udid}" "${APP_PATH}"

  log "launch (foreground, no --console-pty, no &)"
  simctl_bounded launch "${udid}" "${BUNDLE_ID}"

  sleep 3 # bounded first-frame settling time; always below AGENTS.md's 10-second limit
  log "screenshot -> ${LOG_DIR}/launch.png"
  simctl_bounded io "${udid}" screenshot "${LOG_DIR}/launch.png"
  log "capture complete. udid=${udid}; cleaning up on exit"
}

cmd_watch_boot() {
  install_cleanup_traps
  log "shutdown all (precaution)"
  cmd_teardown

  local udid
  udid="$(resolve_watch_udid)"
  if [[ -z "${udid}" ]]; then
    log "ERROR: no ${WATCH_DEVICE_NAME} device under ${WATCH_DEVICE_OS_HEADER}"
    log "available watchOS devices:"
    simctl_bounded list devices available | awk '/^-- watchOS/,/^-- / { print "    " $0 }'
    exit 2
  fi
  log "watch device: ${WATCH_DEVICE_NAME} (${udid})"

  cmd_watch_build

  echo "${udid}" > "${LOG_DIR}/watch-udid"
  log "watch boot"
  simctl_bounded boot "${udid}"
  simctl_bounded bootstatus "${udid}" -b 2>&1 | tail -3

  log "watch install"
  simctl_bounded install "${udid}" "${WATCH_APP_PATH}"

  log "watch launch (foreground, no --console-pty, no &)"
  if [[ -n "${WATCH_LAUNCH_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local launch_args=( ${WATCH_LAUNCH_ARGS} )
    simctl_bounded launch "${udid}" "${WATCH_BUNDLE_ID}" "${launch_args[@]}"
  else
    simctl_bounded launch "${udid}" "${WATCH_BUNDLE_ID}"
  fi

  sleep 3 # bounded first-frame settling time
  log "watch screenshot -> ${LOG_DIR}/watch-launch.png"
  simctl_bounded io "${udid}" screenshot "${LOG_DIR}/watch-launch.png"
  log "watch capture complete. udid=${udid}; cleaning up on exit"
}

cmd_screenshot() {
  local out="${1:-${LOG_DIR}/shot.png}"
  local udid
  udid="$(cat "${LOG_DIR}/udid" 2>/dev/null || resolve_device_udid)"
  [[ -z "${udid}" ]] && { log "no booted sim"; exit 1; }
  simctl_bounded io "${udid}" screenshot "${out}"
  log "saved ${out}"
}

cmd_watch_screenshot() {
  local out="${1:-${LOG_DIR}/watch-shot.png}"
  local udid
  udid="$(cat "${LOG_DIR}/watch-udid" 2>/dev/null || resolve_watch_udid)"
  [[ -z "${udid}" ]] && { log "no watch sim"; exit 1; }
  simctl_bounded io "${udid}" screenshot "${out}"
  log "saved ${out}"
}

cmd_teardown() {
  local udid
  udid="$(cat "${LOG_DIR}/udid" 2>/dev/null || true)"
  if [[ -n "${udid}" ]]; then
    simctl_bounded terminate "${udid}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  else
    simctl_bounded terminate booted "${BUNDLE_ID}" >/dev/null 2>&1 || true
  fi
  udid="$(cat "${LOG_DIR}/watch-udid" 2>/dev/null || true)"
  if [[ -n "${udid}" ]]; then
    simctl_bounded terminate "${udid}" "${WATCH_BUNDLE_ID}" >/dev/null 2>&1 || true
  else
    simctl_bounded terminate booted "${WATCH_BUNDLE_ID}" >/dev/null 2>&1 || true
  fi
  simctl_bounded shutdown all >/dev/null 2>&1 || true
  log "all sims shutdown"
  rm -f "${LOG_DIR}/udid" "${LOG_DIR}/watch-udid"
  check_regressions
}

# A boot session always ends in teardown, including build/install/launch errors.
# SIGKILL cannot be trapped; the next invocation still performs the safety check.
install_cleanup_traps() {
  trap 'cleanup_after_session "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

cleanup_after_session() {
  local result="$1"
  trap - EXIT INT TERM HUP
  if ! cmd_teardown; then
    result=3
  fi
  exit "${result}"
}

check_regressions() {
  local excessive_rss app_processes process_snapshot device_snapshot pgrep_status=0
  if ! process_snapshot="$(ps -axo pid=,rss=,command=)"; then
    log "ERROR: cannot inspect simulator memory/processes; cleanup is unverified"
    return 3
  fi
  excessive_rss="$(printf '%s\n' "${process_snapshot}" | awk '$0 ~ /SimulatorTrampoline/ && $0 !~ /awk/ && $2 > 204800 { print }')"
  app_processes="$(pgrep -lf 'com[.]wristassistant|/WristAssistant(Watch)?[.]app/')" || pgrep_status=$?
  if [[ "${pgrep_status}" -gt 1 ]]; then
    log "ERROR: cannot inspect app processes; cleanup is unverified"
    return 3
  fi
  if ! device_snapshot="$(simctl_bounded list devices)"; then
    log "ERROR: cannot verify simulator shutdown"
    return 3
  fi
  if printf '%s\n' "${device_snapshot}" | grep -q '(Booted)'; then
    log "ERROR: simulator still booted after teardown"
    return 3
  fi
  if [[ -n "${excessive_rss}" || -n "${app_processes}" ]]; then
    local report="${LOG_DIR}/cleanup-regression-$(date +%Y%m%d-%H%M%S).txt"
    {
      printf 'Simulator cleanup regression detected at %s\n' "$(date -u +%FT%TZ)"
      printf 'SimulatorTrampoline above 200 MiB:\n%s\n' "${excessive_rss}"
      printf 'Remaining WristAssistant app processes:\n%s\n' "${app_processes}"
    } > "${report}"
    log "ERROR: simulator cleanup regression; stopped. Report: ${report}"
    return 3
  fi
  log "cleanup check passed: no app processes or SimulatorTrampoline above 200 MiB"
}

cmd_status() {
  local devices processes apps app_status=0
  echo "=== booted devices ==="
  if ! devices="$(simctl_bounded list devices)"; then
    log "ERROR: simulator state unavailable"
    return 3
  fi
  printf '%s\n' "${devices}" | grep -E "Booted" || echo "  (none)"
  echo
  echo "=== sim process RSS ==="
  if ! processes="$(ps -o pid,user,rss,command -ax)"; then
    log "ERROR: process access unavailable; memory check is unverified"
    return 3
  fi
  printf '%s\n' "${processes}" | grep -E "SimulatorTrampoline|CoreSimulator\.CoreSimulatorService|SimStreamProcessor|SimAudioProcessor" \
    | grep -v grep || echo "  (none)"
  echo
  echo "=== wristassistant app procs ==="
  apps="$(pgrep -lf 'com[.]wristassistant|/WristAssistant(Watch)?[.]app/')" || app_status=$?
  if [[ "${app_status}" -gt 1 ]]; then
    log "ERROR: app process access unavailable"
    return 3
  fi
  if [[ -n "${apps}" ]]; then printf '%s\n' "${apps}"; else echo "  (none)"; fi
}

case "${1:-}" in
  build)        cmd_build ;;
  boot)         cmd_boot ;;
  watch-build)  cmd_watch_build ;;
  watch-boot)   cmd_watch_boot ;;
  watch-screenshot) cmd_watch_screenshot "${2:-}" ;;
  screenshot)   cmd_screenshot "${2:-}" ;;
  teardown)     cmd_teardown ;;
  status)       cmd_status ;;
  devices)      simctl_bounded list devices available ;;
  ""|"-h"|"--help")
    sed -n '2,25p' "$0"
    ;;
  *)
    echo "unknown command: $1" >&2
    exit 2
    ;;
esac
