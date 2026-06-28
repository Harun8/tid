#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
IOS_PROJECT="$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant.xcodeproj"
IOS_SCHEME="${TID_IOS_SCHEME:-VoiceCalendarAssistant}"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
IOS_DESTINATION="${TID_XCODE_SIM_DESTINATION:-generic/platform=iOS Simulator}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACTS_DIR="${TID_VALIDATION_ARTIFACTS_DIR:-$ROOT_DIR/.validation/calendar-intelligence-$TIMESTAMP}"
LOG_DIR="$ARTIFACTS_DIR/logs"
INDEX_PATH="$ARTIFACTS_DIR/index.md"

mkdir -p "$LOG_DIR"

log() {
  printf '\n== %s ==\n' "$1"
}

fail() {
  printf '\nValidation failed: %s\n' "$1" >&2
  printf 'Artifacts: %s\n' "$ARTIFACTS_DIR" >&2
  exit 1
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

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  grep -Fq "$needle" "$file" || fail "$label missing in $file"
  printf 'PASS: %s\n' "$label" >>"$LOG_DIR/static-checks.log"
}

assert_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  grep -Eq "$pattern" "$file" || fail "$label missing in $file"
  printf 'PASS: %s\n' "$label" >>"$LOG_DIR/static-checks.log"
}

log "Static calendar intelligence checks"
: >"$LOG_DIR/static-checks.log"

assert_contains "$SERVER_DIR/src/index.ts" "Hvis brugeren siger, hvem mødet er med" "attendee-aware title instruction"
assert_contains "$SERVER_DIR/src/index.ts" "location" "backend location schema"
assert_contains "$SERVER_DIR/src/index.ts" "attendees" "backend attendees schema"
assert_contains "$SERVER_DIR/src/index.ts" "recurrenceRule" "backend recurrence schema"
assert_contains "$SERVER_DIR/src/index.ts" "calendarName" "backend explicit calendar schema"
assert_contains "$SERVER_DIR/src/index.ts" "calendarCategory" "backend calendar category schema"
assert_contains "$SERVER_DIR/src/index.ts" "Påmindelsesregler" "smart reminder instruction"
assert_contains "$SERVER_DIR/src/index.ts" "Spørg aldrig om påmindelse, titel, kalender, varighed, sted, deltagere eller sluttidspunkt" "non-blocking optional fields instruction"
assert_contains "$SERVER_DIR/src/index.ts" "Hvis brugeren udtrykkeligt nævner en kalender" "explicit calendar routing instruction"
assert_regex "$SERVER_DIR/src/index.ts" "hver anden tirsdag|hver uge|hver måned" "Danish recurrence examples"

assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "var location: String?" "draft location field"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "var attendees: [String]" "draft attendees field"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "struct CalendarRecurrenceRule" "draft recurrence model"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "var notesForCalendar" "calendar notes enrichment"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "CalendarRoutingCategory" "draft calendar category model"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "var calendarName: String?" "draft explicit calendar field"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "Deltagere:" "attendees preserved in notes"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "participantTitleSuffix" "deterministic person-in-title fallback"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift" "cleanedUniqueValues" "attendees are cleaned and deduplicated"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/DateFormatting.swift" "Hver anden" "weekly recurrence review says every other weekday"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/DateFormatting.swift" "recurrenceLabel(for draft" "recurrence labels use draft start date"

assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "event.location = validatedDraft.location" "main save writes location"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "event.notes = validatedDraft.notesForCalendar" "main save writes enriched notes"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "event.addRecurrenceRule(recurrenceRule)" "main save writes recurrence"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "CalendarEventVerification.issues" "main save verifies persisted event fields"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "read_back_unavailable" "main save skips verification when write-only readback is unavailable"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityCalendarActions.swift" "event.location = validatedDraft.location" "Live Activity save writes location"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityCalendarActions.swift" "event.addRecurrenceRule(recurrenceRule)" "Live Activity save writes recurrence"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityCalendarActions.swift" "CalendarEventVerification.issues" "Live Activity save verifies persisted event fields"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityCalendarActions.swift" "guard let readBackEvent = eventStore.event" "Live Activity save skips verification when readback is unavailable"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventVerification.swift" "alarmMinutesBefore" "save verification checks reminders"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventVerification.swift" "recurrenceIssue" "save verification checks recurrence"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsStore.swift" "setRoutingCalendar" "settings persist calendar category mappings"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsSheet.swift" "Kalenderrouting" "settings expose calendar category mappings"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "routeCalendar(for" "draft calendar routing decision"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "matchingCalendar(named" "explicit calendar name matching"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "CalendarService.availableCalendars.preload" "Action Button calendar routing preload"

assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/ConfirmationSheet.swift" "mappin.and.ellipse" "confirmation UI shows location"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/ConfirmationSheet.swift" "person.2" "confirmation UI shows people"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/ConfirmationSheet.swift" "Gentagelse" "confirmation UI clearly labels recurrence"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistantLiveActivity/TidLiveActivityWidget.swift" "isRecurrenceDetail" "Dynamic Island keeps recurrence visible before save"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsSheet.swift" "SetupStatusSnapshot" "settings includes setup status checks"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsSheet.swift" "Lokalnetværk" "settings shows local network status"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsSheet.swift" "Action Button" "settings shows Action Button status"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "draftReviewReason" "auto-save uses review reason gate"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "date_risk" "auto-save reviews risky dates"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "recurrence" "auto-save reviews recurrence drafts"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "savedAlertConfiguration" "auto-save sends saved confirmation alert"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "BackendPreflightService.warmBackend" "Action Button cold start warms backend"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "VoiceAssistantViewModel.coldStartWarmups" "Action Button cold start warmups are traced separately"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "RealtimeClient.connect.coldStartWarmup" "Action Button cold start warms Realtime without blocking recording"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "calendarDraftValidated" "draft validation timing is traced"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "StartListeningSupersededError" "cold start can be superseded without surfacing false errors"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/RealtimeWebRTCClient.swift" "audioCaptureReady" "audio capture readiness trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/RealtimeWebRTCClient.swift" "peerConnectionReady" "peer connection readiness trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/RealtimeWebRTCClient.swift" "firstAudioFrameSent" "first audio frame send trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/RealtimeWebRTCClient.swift" "responseCreateSent" "Realtime response.create send trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/RealtimeWebRTCClient.swift" "toolCallReceived" "Realtime tool call receive trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "availableCalendarsIfAuthorized" "calendar preload avoids prompting on hot path"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift" "CalendarService.availableCalendars.cacheHit" "calendar list cache trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityManager.swift" "live_activity_update_skipped" "duplicate Live Activity updates are skipped"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "warmBackend.cacheHit" "backend warmup cache trace"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityManager.swift" "cleanupStaleTransientActivities" "Live Activity clears stale transient states"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/AppShortcuts.swift" "staleRecordingActivityCleared" "Action Button clears stale recording Live Activities"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/AppTrace.swift" "preserveFailureBundle" "app preserves automatic failure bundles"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/AppTrace.swift" "tid-failure-bundles" "failure bundles have stable cache directory"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "preserveFailureBundle(" "failure transitions write trace bundles"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "debug-error" "debug failure deep link validates bundles"
assert_contains "$ROOT_DIR/scripts/collect-device-trace.sh" "tid-failure-bundles" "trace collector pulls automatic failure bundles"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "Hvis sted, deltagere eller gentagelse ikke blev nævnt, skal de udelades." "automatic optional clarification answer"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "\"hvem\"" "people clarification treated optional"
assert_contains "$ROOT_DIR/ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift" "\"gentagelse\"" "recurrence clarification treated optional"

log "Regression command matrix"
run_logged regression-matrix \
  node "$ROOT_DIR/scripts/validate-regression-matrix.mjs" "$ARTIFACTS_DIR/regression-matrix.md"

log "Backend build"
run_logged backend-build npm --prefix "$SERVER_DIR" run build

log "iOS simulator build"
run_logged xcodebuild-simulator \
  xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration "$IOS_CONFIGURATION" \
    -destination "$IOS_DESTINATION" \
    build

cat >"$INDEX_PATH" <<EOF
# Tid Calendar Intelligence Validation

- Created: \`$(date -Iseconds)\`
- iOS destination: \`$IOS_DESTINATION\`
- Configuration: \`$IOS_CONFIGURATION\`

## Covered Contract

- Natural Danish attendee/title extraction: \`møde med Per\` should become \`Møde med Per\`.
- Optional fields stay optional: reminders, title, calendar, duration, location, attendees, and recurrence should not block draft creation.
- Smarter reminders: vague Danish reminder phrases are mapped instead of clarified.
- Recurring events are represented as \`recurrenceRule\` and saved to EventKit from both app and Live Activity.
- Locations and people are preserved in the calendar event; people are stored in notes because EventKit does not support reliable invitee creation from this flow.
- The regression matrix covers 30+ Danish command shapes for reminders, recurrence, attendees, locations, calendar routing, missing details, and high-confidence auto-save.

## Logs

- Static checks: \`logs/static-checks.log\`
- Regression matrix: \`logs/regression-matrix.log\`
- Regression matrix summary: \`regression-matrix.md\`
- Backend build: \`logs/backend-build.log\`
- iOS build: \`logs/xcodebuild-simulator.log\`
EOF

log "Validation passed"
printf 'Artifacts: %s\n' "$ARTIFACTS_DIR"
