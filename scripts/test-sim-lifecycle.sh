#!/usr/bin/env bash
# Exercises cleanup with fake Xcode commands. Never starts a real simulator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wristassistant-sim-fixture.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
mkdir -p "${TEST_DIR}/repo/scripts" "${TEST_DIR}/xcode/usr/bin"
cp "${SCRIPT_DIR}/sim.sh" "${TEST_DIR}/repo/scripts/sim.sh"
export DEVELOPER_DIR="${TEST_DIR}/xcode"
export SIM_FIXTURE_LOG="${TEST_DIR}/calls"
cat > "${DEVELOPER_DIR}/usr/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SIM_FIXTURE_LOG}"
case "$*" in
  'simctl list devices available')
    printf '%s\n' '-- iOS 26.5 --' '    iPhone 17 (11111111-1111-1111-1111-111111111111) (Shutdown)' '-- watchOS 26.5 --' '    Apple Watch Series 11 (46mm) (22222222-2222-2222-2222-222222222222) (Shutdown)' ;;
  'simctl install '*) [[ "${SIM_FIXTURE_FAIL:-}" != install ]] ;;
  'simctl get_app_container '*) [[ "${SIM_FIXTURE_FAIL:-}" != registration ]] ;;
  'simctl io '*' screenshot '*) touch "${@: -1}" ;;
  'simctl launch '*)
    if [[ "${SIM_FIXTURE_FAIL:-}" == launch-timeout ]]; then sleep 2; fi
    [[ "${SIM_FIXTURE_FAIL:-}" != launch ]] ;;
esac
STUB
cat > "${DEVELOPER_DIR}/usr/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "xcodebuild $*" >> "${SIM_FIXTURE_LOG}"
[[ "${SIM_FIXTURE_FAIL:-}" != build ]]
STUB
cat > "${DEVELOPER_DIR}/usr/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "${DEVELOPER_DIR}/usr/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [[ "${SIM_FIXTURE_FAIL:-}" == process-access ]]; then exit 2; fi
if [[ "${SIM_FIXTURE_FAIL:-}" == review-process-access ]] && /usr/bin/grep -q '^simctl spawn ' "${SIM_FIXTURE_LOG}"; then exit 2; fi
if [[ "${SIM_FIXTURE_FAIL:-}" == rss ]]; then printf '%s\n' '99999 250000 SimulatorTrampoline'; fi
STUB
chmod +x "${DEVELOPER_DIR}/usr/bin/"*
run_case() {
  local command="$1" failure="$2" expected="$3" result=0
  : > "${SIM_FIXTURE_LOG}"
  SIM_FIXTURE_FAIL="${failure}" bash "${TEST_DIR}/repo/scripts/sim.sh" "${command}" > "${TEST_DIR}/output" 2>&1 || result=$?
  if [[ "${result}" != "${expected}" ]]; then cat "${TEST_DIR}/output"; exit 1; fi
  local shutdowns launches
  shutdowns="$(awk '/^simctl shutdown all$/ { n++ } END { print n+0 }' "${SIM_FIXTURE_LOG}")"
  launches="$(awk '/^simctl launch / { n++ } END { print n+0 }' "${SIM_FIXTURE_LOG}")"
  [[ "${shutdowns}" -ge 2 ]]
  if [[ -z "${failure}" ]]; then [[ "${launches}" == 1 ]]; fi
  if [[ "${failure}" == build || "${failure}" == install || "${failure}" == registration || "${failure}" == rss ]]; then [[ "${launches}" == 0 ]]; fi
  if [[ "${failure}" == rss ]]; then ! rg -q '^simctl boot ' "${SIM_FIXTURE_LOG}"; fi
  [[ ! -e "${TEST_DIR}/repo/build/derived/sim-logs/udid" ]]
  [[ ! -e "${TEST_DIR}/repo/build/derived/sim-logs/watch-udid" ]]
}
run_case boot '' 0
run_case watch-boot '' 0
run_case boot build 1
run_case boot install 1
run_case boot registration 2
run_case watch-boot launch 1
SIM_COMMAND_TIMEOUT_SECONDS=1 run_case boot launch-timeout 142
run_case boot rss 3
run_case boot process-access 3
SIM_CAPTURE_COUNT=3 run_case boot '' 0
SIM_CAPTURE_COUNT=0 run_case boot invalid-capture 2
SIM_DISPLAY=3 SIM_REVIEW_SECONDS=1 run_case boot '' 0
rg -q '^simctl io .* screenshot --display=3 ' "${SIM_FIXTURE_LOG}"
rg -q '^simctl spawn .* launchctl print system$' "${SIM_FIXTURE_LOG}"
SIM_REVIEW_SECONDS=1 run_case boot review-process-access 3
for invalid_review in -1 abc 181; do
  : > "${SIM_FIXTURE_LOG}"
  result=0
  SIM_REVIEW_SECONDS="${invalid_review}" bash "${TEST_DIR}/repo/scripts/sim.sh" boot > "${TEST_DIR}/output" 2>&1 || result=$?
  [[ "${result}" == 2 ]]
  [[ ! -s "${SIM_FIXTURE_LOG}" ]]
done
printf '%s\n' 'Simulator lifecycle fixtures passed: one launch, success/error teardown, watch cleanup, RSS protection, bounded launch and review, display capture, invalid options rejected before boot'
