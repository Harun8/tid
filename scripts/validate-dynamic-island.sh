#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_PROJECT="$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant.xcodeproj"
IOS_SCHEME="${TID_IOS_SCHEME:-VoiceCalendarAssistant}"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
BUNDLE_ID="${TID_BUNDLE_ID:-com.tid.VoiceCalendarAssistant}"
DEVICE_ID="${TID_DEVICE_ID:-B71620EE-B621-53E5-91AF-7BB504E68452}"
DEVICE_DESTINATION="${TID_XCODE_DEVICE_DESTINATION:-id=00008140-000644A90CC1801C}"
BACKEND_CONFIG_URL="${TID_BACKEND_CONFIG_URL:-http://127.0.0.1:3000/config}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACTS_DIR="${TID_VALIDATION_ARTIFACTS_DIR:-$ROOT_DIR/.validation/dynamic-island-$TIMESTAMP}"
LOG_DIR="$ARTIFACTS_DIR/logs"
SCREENSHOT_DIR="$ARTIFACTS_DIR/screenshots"
REQUIRE_EXPANDED="${TID_REQUIRE_EXPANDED:-0}"
CAPTURE_EXPANDED=0

STATES=(listening thinking needs-clarification ready-to-save saved)
EXPECTED_PHASES=(listening thinking needsClarification readyToConfirm saved)

usage() {
  cat <<EOF
Usage: scripts/validate-dynamic-island.sh [options]

Options:
  --sim-only       Run simulator Dynamic Island visual regression only. Default.
  --device-smoke  Also build/install on the physical iPhone and launch debug ready-to-save.
  --backend       Also check the backend config endpoint before running.
  --help          Show this help.

Environment:
  TID_SIMULATOR_ID             Simulator UDID. Defaults to first booted iPhone.
  TID_DEVICE_ID                CoreDevice ID for physical install.
  TID_XCODE_DEVICE_DESTINATION xcodebuild destination for physical device.
  TID_VALIDATION_ARTIFACTS_DIR Output folder for logs/screenshots.
  TID_ISLAND_CLICK_X/Y         Override Dynamic Island long-press coordinate.
  TID_REQUIRE_EXPANDED=1       Fail if a Simulator.app window is not available.
EOF
}

RUN_DEVICE_SMOKE=0
CHECK_BACKEND=0

for arg in "$@"; do
  case "$arg" in
    --sim-only)
      RUN_DEVICE_SMOKE=0
      ;;
    --device-smoke)
      RUN_DEVICE_SMOKE=1
      ;;
    --backend)
      CHECK_BACKEND=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  printf '\n== %s ==\n' "$1"
}

fail() {
  printf '\nValidation failed: %s\n' "$1" >&2
  printf 'Artifacts: %s\n' "$ARTIFACTS_DIR" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run_logged() {
  local name="$1"
  shift
  local log_file="$LOG_DIR/$name.log"

  "$@" >"$log_file" 2>&1 || {
    tail -120 "$log_file" >&2 || true
    fail "$name failed"
  }
}

detect_booted_iphone_simulator() {
  xcrun simctl list devices booted \
    | awk -F'[()]' '/iPhone/ {print $2; exit}'
}

simulator_window_rect() {
  local attempt
  local rect

  for attempt in 1 2 3 4 5; do
    open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_ID" >/dev/null 2>&1 || open -a Simulator >/dev/null 2>&1 || true
    sleep 0.5
    if rect="$(osascript \
      -e 'tell application "Simulator" to activate' \
      -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1' \
      2>/dev/null)"; then
      printf '%s\n' "$rect"
      return
    fi
    sleep 0.5
  done

  return 1
}

island_click_point() {
  if [[ -n "${TID_ISLAND_CLICK_X:-}" && -n "${TID_ISLAND_CLICK_Y:-}" ]]; then
    printf '%s,%s\n' "$TID_ISLAND_CLICK_X" "$TID_ISLAND_CLICK_Y"
    return
  fi

  local rect
  rect="$(simulator_window_rect)"
  printf '%s\n' "$rect" \
    | awk -F', ' '{printf "%d,%d\n", $1 + ($3 / 2), $2 + 114}'
}

dismiss_click_point() {
  local rect
  rect="$(simulator_window_rect)"
  printf '%s\n' "$rect" \
    | awk -F', ' '{printf "%d,%d\n", $1 + ($3 / 2), $2 + ($4 * 0.68)}'
}

sim_home() {
  xcrun simctl launch "$SIMULATOR_ID" com.apple.springboard >/dev/null 2>&1 || true
}

capture_state() {
  local simulator_id="$1"
  local state="$2"
  local url="voicecalendar://debug-$state"
  local compact_path="$SCREENSHOT_DIR/$state-compact.png"
  local expanded_path="$SCREENSHOT_DIR/$state-expanded.png"
  local point
  local dismiss_point

  log "Capture $state"
  xcrun simctl openurl "$simulator_id" "$url" >>"$LOG_DIR/simctl-openurl.log" 2>&1
  sleep 1

  sim_home
  sleep 1.5
  xcrun simctl io "$simulator_id" screenshot "$compact_path" >>"$LOG_DIR/screenshots.log" 2>&1

  if [[ "$CAPTURE_EXPANDED" == "1" ]]; then
    point="$(island_click_point)"
    /opt/homebrew/bin/cliclick "dd:$point" w:1800 "du:$point"
    sleep 1.5
    xcrun simctl io "$simulator_id" screenshot "$expanded_path" >>"$LOG_DIR/screenshots.log" 2>&1

    dismiss_point="$(dismiss_click_point)"
    /opt/homebrew/bin/cliclick "c:$dismiss_point" || true
    sleep 0.4

    [[ -s "$expanded_path" ]] || fail "Missing expanded screenshot for $state"
  else
    printf 'Expanded screenshot skipped because Simulator.app had no visible window.\n' \
      >"$SCREENSHOT_DIR/$state-expanded-skipped.txt"
  fi

  [[ -s "$compact_path" ]] || fail "Missing compact screenshot for $state"
}

copy_simulator_trace() {
  local simulator_id="$1"
  local container
  container="$(xcrun simctl get_app_container "$simulator_id" "$BUNDLE_ID" data)"

  if [[ -f "$container/Library/Caches/tid-trace.log" ]]; then
    cp "$container/Library/Caches/tid-trace.log" "$ARTIFACTS_DIR/tid-trace-simulator.log"
  else
    fail "Simulator trace file was not created"
  fi
}

assert_simulator_trace() {
  local trace_file="$ARTIFACTS_DIR/tid-trace-simulator.log"
  local index=1

  for state in "${STATES[@]}"; do
    grep -q "host=debug-$state" "$trace_file" \
      || fail "Trace is missing debug deep link for $state"
  done

  for phase in "${EXPECTED_PHASES[@]}"; do
    grep -Eq "live_activity_(started|updated|ended).*phase=$phase" "$trace_file" \
      || fail "Trace is missing Live Activity phase $phase"
    index=$((index + 1))
  done
}

write_index() {
  local index_path="$ARTIFACTS_DIR/index.md"
  local expanded_cell

  {
    printf '# Tid Dynamic Island Validation\n\n'
    printf '- Created: `%s`\n' "$(date -Iseconds)"
    printf '- Simulator: `%s`\n' "$SIMULATOR_ID"
    printf '- Configuration: `%s`\n\n' "$IOS_CONFIGURATION"
    printf '## Screenshots\n\n'
    printf '| State | Compact | Expanded |\n'
    printf '| --- | --- | --- |\n'
    for state in "${STATES[@]}"; do
      if [[ -f "$SCREENSHOT_DIR/$state-expanded.png" ]]; then
        expanded_cell="screenshots/$state-expanded.png"
      else
        expanded_cell="skipped: no Simulator.app window"
      fi
      printf '| `%s` | `%s` | `%s` |\n' \
        "$state" \
        "screenshots/$state-compact.png" \
        "$expanded_cell"
    done
    printf '\n## Logs\n\n'
    printf '- Simulator trace: `tid-trace-simulator.log`\n'
    printf '- Build log: `logs/xcodebuild-simulator.log`\n'
    if [[ "$RUN_DEVICE_SMOKE" == "1" ]]; then
      printf '- Device trace: `tid-trace-device.log`\n'
      printf '- Device build log: `logs/xcodebuild-device.log`\n'
    fi
  } >"$index_path"
}

run_device_smoke() {
  local built_products_dir
  local app_path

  log "Device build"
  run_logged xcodebuild-device \
    xcodebuild \
      -project "$IOS_PROJECT" \
      -scheme "$IOS_SCHEME" \
      -configuration "$IOS_CONFIGURATION" \
      -destination "$DEVICE_DESTINATION" \
      build

  built_products_dir="$(xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration "$IOS_CONFIGURATION" \
    -destination "$DEVICE_DESTINATION" \
    -showBuildSettings \
    | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"
  app_path="$built_products_dir/VoiceCalendarAssistant.app"

  log "Device install"
  run_logged device-install \
    xcrun devicectl device install app --device "$DEVICE_ID" "$app_path"

  log "Device debug launch"
  if ! xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    --payload-url voicecalendar://debug-ready-to-save \
    "$BUNDLE_ID" \
    >"$LOG_DIR/device-debug-ready.log" 2>&1; then
    tail -120 "$LOG_DIR/device-debug-ready.log" >&2 || true
    if grep -q "Locked" "$LOG_DIR/device-debug-ready.log"; then
      fail "Physical iPhone is locked. Unlock it, keep it awake, then rerun with --device-smoke."
    fi
    fail "device-debug-ready failed"
  fi

  cat "$LOG_DIR/device-debug-ready.log"
  sleep 2

  log "Device trace"
  if xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source Library/Caches/tid-trace.log \
    --destination "$ARTIFACTS_DIR/tid-trace-device.log" \
    >"$LOG_DIR/device-trace-copy.log" 2>&1; then
    grep -q "host=debug-ready-to-save" "$ARTIFACTS_DIR/tid-trace-device.log" \
      || fail "Device trace is missing debug-ready-to-save"
    grep -Eq "live_activity_(started|updated).*phase=readyToConfirm" "$ARTIFACTS_DIR/tid-trace-device.log" \
      || fail "Device trace is missing readyToConfirm Live Activity"
  else
    tail -80 "$LOG_DIR/device-trace-copy.log" >&2 || true
    fail "Could not copy device trace"
  fi
}

require_command xcrun
require_command xcodebuild
require_command osascript
require_command awk
if [[ -x /opt/homebrew/bin/cliclick ]]; then
  :
elif [[ "$REQUIRE_EXPANDED" == "1" ]]; then
  fail "Missing /opt/homebrew/bin/cliclick, required for expanded screenshots"
fi

mkdir -p "$LOG_DIR" "$SCREENSHOT_DIR"

SIMULATOR_ID="${TID_SIMULATOR_ID:-$(detect_booted_iphone_simulator)}"
[[ -n "$SIMULATOR_ID" ]] || fail "No booted iPhone simulator found. Boot one or set TID_SIMULATOR_ID."

log "Artifacts"
printf '%s\n' "$ARTIFACTS_DIR"

if [[ "$CHECK_BACKEND" == "1" ]]; then
  log "Backend config"
  curl -fsS --max-time 2 "$BACKEND_CONFIG_URL" >"$ARTIFACTS_DIR/backend-config.json" \
    || fail "Backend is not responding at $BACKEND_CONFIG_URL"
fi

log "Simulator boot"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
run_logged simulator-bootstatus xcrun simctl bootstatus "$SIMULATOR_ID" -b

log "Simulator build"
run_logged xcodebuild-simulator \
  xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration "$IOS_CONFIGURATION" \
    -destination "id=$SIMULATOR_ID" \
    build

SIM_BUILT_PRODUCTS_DIR="$(xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration "$IOS_CONFIGURATION" \
  -destination "id=$SIMULATOR_ID" \
  -showBuildSettings \
  | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"
SIM_APP_PATH="$SIM_BUILT_PRODUCTS_DIR/VoiceCalendarAssistant.app"

log "Simulator install"
run_logged simulator-install xcrun simctl install "$SIMULATOR_ID" "$SIM_APP_PATH"

xcrun simctl privacy "$SIMULATOR_ID" grant calendar "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl privacy "$SIMULATOR_ID" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true

SIM_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data)"
rm -f "$SIM_CONTAINER/Library/Caches/tid-trace.log"

log "Simulator launch"
run_logged simulator-launch xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"
sleep 1

if simulator_window_rect >"$LOG_DIR/simulator-window.txt"; then
  if [[ -x /opt/homebrew/bin/cliclick ]]; then
    CAPTURE_EXPANDED=1
    log "Expanded screenshots enabled"
  else
    log "Expanded screenshots skipped"
    printf 'Missing /opt/homebrew/bin/cliclick.\n' >"$LOG_DIR/expanded-screenshots-skipped.log"
  fi
else
  if [[ "$REQUIRE_EXPANDED" == "1" ]]; then
    fail "Simulator.app has no visible device window. Open the simulator window, then rerun."
  fi
  log "Expanded screenshots skipped"
  printf 'Simulator.app has no visible device window. Compact screenshots and trace assertions still ran.\n' \
    >"$LOG_DIR/expanded-screenshots-skipped.log"
fi

for state in "${STATES[@]}"; do
  capture_state "$SIMULATOR_ID" "$state"
done

log "Simulator trace assertions"
copy_simulator_trace "$SIMULATOR_ID"
assert_simulator_trace

if [[ "$RUN_DEVICE_SMOKE" == "1" ]]; then
  run_device_smoke
fi

write_index

log "Validation passed"
printf 'Artifacts: %s\n' "$ARTIFACTS_DIR"
