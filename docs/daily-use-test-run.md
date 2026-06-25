# Tid Daily-Use Test Run

Goal: add 10-20 realistic calendar events using only the Action Button and Dynamic Island. Log only misses or surprising behavior.

## Before Testing

- Backend should return config at `http://192.168.0.121:3000/config`.
- Use the Action Button outside the app.
- Stop recording with the Action Button when you are done speaking.
- Save from the Dynamic Island when the save UI appears.

## Good Coverage Set

Use real calendar-safe variations of these:

1. `Jeg har et møde med Per i morgen fra 12 til 13.`
2. `Jeg har kaffemøde med Jonas på Café Paludan hver anden tirsdag klokken 14 de næste 5 gange, og jeg vil have en påmindelse lidt før.`
3. `Tandlæge på fredag klokken 10, mind mig om det dagen før og 10 minutter før.`
4. `Frokost med Anna på kontoret på tirsdag klokken 12.`
5. `Ring til banken i morgen formiddag.`
6. `Møde med teamet hver mandag klokken 9.`
7. `Træning i Fitness World på torsdag fra 18 til 19:30.`
8. `Hent pakke i dag klokken 16 med påmindelse en halv time før.`
9. `Møde tirsdag om to uger klokken 14.`
10. `Jeg har et møde med Per i morgen.` Then answer via `Svar`: `Fra 12 til 13.`

## Pass Criteria

- No optional questions for title, reminder, location, attendee, recurrence, or calendar.
- It only asks when date or start time is truly missing.
- Person names appear in titles when natural, for example `Møde med Per`.
- Locations are saved as calendar locations.
- Recurrence is saved when you say `hver`, `hver anden`, `de næste X gange`, or `indtil`.
- Reminders match the phrase you used.
- Second and third Action Button runs still show Tid's blue Dynamic Island UI.

## Miss Log

For each miss, record:

```text
Time:
Exact phrase:
Expected:
Actual:
Did Dynamic Island show save UI? yes/no
Did it ask a question? yes/no, what question:
Did it save wrong data? title/date/time/location/reminder/recurrence:
```

After a miss, run:

```sh
scripts/collect-device-trace.sh
```

Then send the latest file path from `.validation/device-trace-*`.
