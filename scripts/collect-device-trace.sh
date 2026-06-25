#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${TID_DEVICE_ID:-B71620EE-B621-53E5-91AF-7BB504E68452}"
BUNDLE_ID="${TID_BUNDLE_ID:-com.tid.VoiceCalendarAssistant}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/.validation/device-trace-$TIMESTAMP"

mkdir -p "$OUT_DIR"

xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Library/Caches/tid-trace.log \
  --destination "$OUT_DIR/tid-trace-device.log"

if xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Library/Caches/tid-failure-bundles \
  --destination "$OUT_DIR/tid-failure-bundles" \
  >/dev/null 2>&1; then
  printf 'Failure bundles copied: %s\n' "$OUT_DIR/tid-failure-bundles"
else
  printf 'Failure bundles copied: none\n'
fi

cp "$ROOT_DIR/.validation/backend-launchagent.log" "$OUT_DIR/backend-launchagent.log" 2>/dev/null || true
cp "$ROOT_DIR/.validation/backend-launchagent.err.log" "$OUT_DIR/backend-launchagent.err.log" 2>/dev/null || true

printf 'Trace collected: %s\n' "$OUT_DIR"
printf '\nLatest app errors / relevant events:\n'
rg -n "error|Fejl|createRealtimeCallAnswer|stage_calendar_event|tool|readyToConfirm|saved|needsClarification|stopToDraft|finalTranscript" \
  "$OUT_DIR/tid-trace-device.log" | tail -120 || true

if [[ -d "$OUT_DIR/tid-failure-bundles" ]]; then
  printf '\nLatest automatic failure bundles:\n'
  find "$OUT_DIR/tid-failure-bundles" -name metadata.txt -print0 \
    | xargs -0 ls -t 2>/dev/null \
    | head -5 \
    | while read -r metadata; do
      printf '\n-- %s --\n' "$metadata"
      sed -n '1,80p' "$metadata"
    done
fi
