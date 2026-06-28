# Tid Action Button Regression Checklist

Run these on the physical iPhone, outside the app, with the backend running on the Mac at `http://192.168.0.121:3000`.

## Automated Dynamic Island Harness

Before manual Action Button testing, run the deterministic Live Activity validation:

```sh
scripts/validate-dynamic-island.sh
```

This builds the simulator app, installs it, drives the DEBUG Live Activity states through deep links, captures compact and expanded Dynamic Island screenshots, and asserts that the trace contains each expected Live Activity phase:

- `listening`
- `thinking`
- `needsClarification`
- `readyToConfirm`
- `saved`

Artifacts are written to `.validation/dynamic-island-<timestamp>/`:

- `screenshots/*-compact.png`
- `screenshots/*-expanded.png`
- `tid-trace-simulator.log`
- `logs/xcodebuild-simulator.log`
- `index.md`

If Simulator.app is running without a visible device window, the harness still captures compact screenshots and validates the Live Activity trace. Expanded screenshots need a visible Simulator.app window because they require a long press on the Dynamic Island. To make expanded screenshots mandatory:

```sh
TID_REQUIRE_EXPANDED=1 scripts/validate-dynamic-island.sh
```

To include a backend config check:

```sh
scripts/validate-dynamic-island.sh --backend
```

To validate the calendar-intelligence contract after prompt/schema/calendar changes:

```sh
scripts/validate-calendar-intelligence.sh
```

This checks backend prompt/schema support for Danish phrases, attendees, location, recurrence, reminders, calendar routing, optional clarification behavior, and the command regression matrix, then compiles the backend and iOS app.

To run only the command matrix:

```sh
node scripts/validate-regression-matrix.mjs .validation/regression-matrix.md
```

To also build/install on the physical iPhone and launch the debug ready-to-save Live Activity:

```sh
scripts/validate-dynamic-island.sh --device-smoke
```

Keep the iPhone unlocked and awake for `--device-smoke`; `devicectl` cannot launch the app on a locked phone.

The harness cannot physically press the Action Button. Use it to catch visual and Live Activity state regressions, then run the manual tests below for the real Action Button/App Intent/microphone path.

## GitHub Actions

The `Tid Validation` workflow runs `scripts/validate-calendar-intelligence.sh` on pushes to `main` and pull requests. This covers the backend prompt/schema contract, command regression matrix, backend build, and iOS build.

The same workflow has a manual `dynamic_island` option. Enable it from `workflow_dispatch` when you want CI to boot a simulator and run `scripts/validate-dynamic-island.sh`. Expanded screenshots may be skipped in CI if the simulator window is not available, but compact screenshots and trace assertions still run.

## Required Passes

1. Basic Action Button flow
   - Press Action Button.
   - Say: `Jeg har et møde med Per i morgen fra 12 til 13, og jeg skal have en påmindelse 2 minutter før.`
   - Press Action Button again to stop.
   - Expected: Dynamic Island moves from `Lytter` to `Forstår`, then shows save UI.
   - Expected: Save from Dynamic Island works.
   - Expected: Calendar title is `Møde med Per`.
   - Expected: Reminder is 2 minutes before.

2. Second run stability
   - Repeat the basic flow immediately.
   - Expected: blue Tid Dynamic Island UI appears again, not the default orange microphone-only state.
   - Expected: no app launch required.
   - Expected: no `Fejl` state.

3. Missing required time
   - Press Action Button.
   - Say: `Jeg har et møde med Per i morgen.`
   - Stop.
   - Expected: Dynamic Island asks for the missing time.
   - Tap `Svar`.
   - Say: `Fra klokken 12 til 13.`
   - Stop.
   - Expected: save UI appears without opening the app.

4. No optional reminder question
   - Press Action Button.
   - Say: `Jeg har et møde med Per i morgen fra 12 til 13.`
   - Stop.
   - Expected: no question about reminders.
   - Expected: save UI appears with no reminder.

5. Relative date without confirmation
   - Press Action Button.
   - Say: `Jeg har et møde tirsdag om to uger klokken 14.`
   - Stop.
   - Expected: no date confirmation question.
   - Expected: save UI appears with the computed date.

6. Calendar intelligence polish
   - Press Action Button.
   - Say: `Jeg har kaffemøde med Jonas på Café Paludan hver anden tirsdag klokken 14 de næste 5 gange, og jeg vil have en påmindelse lidt før.`
   - Stop.
   - Expected: no optional clarification questions.
   - Expected: title includes `Jonas`.
   - Expected: location is `Café Paludan`.
   - Expected: recurrence is every other Tuesday for 5 occurrences.
   - Expected: reminder is 10 minutes before.

7. Smarter default title
   - Press Action Button.
   - Say: `Jeg har et møde i morgen fra 12 til 13.`
   - Stop.
   - Expected: title is `Møde`.
   - Expected: no title question.

## Failure Signals

- Dynamic Island disappears before processing starts.
- It shows `Lytter` after the user stopped recording.
- It shows the orange default microphone UI instead of Tid's blue UI on a second run.
- `Svar` opens the app or hits a mic error.
- Save UI only appears inside the app.
- `Fejl` appears without a specific recoverable message.

## Debugging

- In the app, open `Indstillinger > Sporing` to inspect the latest trace lines.
- The key span is `VoiceAssistantViewModel.stopToDraft`.
- Backend traces are printed by `TID_TRACE=1 npm start`.
