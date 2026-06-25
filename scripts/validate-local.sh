#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
IOS_PROJECT="$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant.xcodeproj"
IOS_SCHEME="VoiceCalendarAssistant"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
IOS_DESTINATION="${TID_XCODE_DESTINATION:-id=00008140-000644A90CC1801C}"
DEVICE_ID="${TID_DEVICE_ID:-B71620EE-B621-53E5-91AF-7BB504E68452}"
BACKEND_CONFIG_URL="${TID_BACKEND_CONFIG_URL:-http://127.0.0.1:3000/config}"

echo "== Backend build =="
npm --prefix "$SERVER_DIR" run build

echo "== iOS build =="
xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration "$IOS_CONFIGURATION" \
  -destination "$IOS_DESTINATION" \
  build

echo "== Backend config =="
if curl -fsS --max-time 2 "$BACKEND_CONFIG_URL"; then
  echo
else
  echo "Backend is not responding at $BACKEND_CONFIG_URL"
  echo "Start it with: cd $SERVER_DIR && TID_TRACE=1 npm start"
  exit 1
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  BUILT_PRODUCTS_DIR="$(xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration "$IOS_CONFIGURATION" \
    -destination "$IOS_DESTINATION" \
    -showBuildSettings \
    | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"

  APP_PATH="$BUILT_PRODUCTS_DIR/VoiceCalendarAssistant.app"

  echo "== Install app =="
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

  echo "== Launch app =="
  xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    com.tid.VoiceCalendarAssistant
fi

echo "Validation build checks passed."
