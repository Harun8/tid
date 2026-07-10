#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const rootDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const matrixPath = path.join(rootDir, "tests", "calendar-command-matrix.json");
const summaryPath = process.argv[2] ? path.resolve(process.argv[2]) : "";

const matrix = JSON.parse(fs.readFileSync(matrixPath, "utf8"));

const codeFiles = {
  backend: read("server/src/index.ts"),
  draft: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarEventDraft.swift"),
  viewModel: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/VoiceAssistantViewModel.swift"),
  calendarService: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/CalendarService.swift"),
  liveActivityActions: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/LiveActivityCalendarActions.swift"),
  widget: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistantLiveActivity/TidLiveActivityWidget.swift"),
  settings: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/SettingsStore.swift"),
  trace: read("ios/VoiceCalendarAssistant/VoiceCalendarAssistant/AppTrace.swift")
};

const cases = matrix.cases ?? [];
const failures = [];

assert(matrix.version === 1, "matrix version must be 1");
assert(Array.isArray(cases), "matrix.cases must be an array");
assert(cases.length >= 30, "matrix must include at least 30 regression cases");

const ids = new Set();
for (const testCase of cases) {
  assertString(testCase.id, "case.id");
  assert(!ids.has(testCase.id), `duplicate case id: ${testCase.id}`);
  ids.add(testCase.id);
  assertString(testCase.utterance, `${testCase.id}.utterance`);
  assert(testCase.expected && typeof testCase.expected === "object", `${testCase.id}.expected is required`);
  assert(typeof testCase.expected.autoSaveEligible === "boolean", `${testCase.id}.expected.autoSaveEligible must be boolean`);
  assert("reviewReason" in testCase.expected, `${testCase.id}.expected.reviewReason is required`);
}

const counts = {
  attendees: count((c) => (c.expected.attendees ?? []).length > 0),
  emptyAttendees: count((c) => Array.isArray(c.expected.attendees) && c.expected.attendees.length === 0),
  reminders: count((c) => (c.expected.remindersMinutes ?? []).length > 0),
  noReminders: count((c) => Array.isArray(c.expected.remindersMinutes) && c.expected.remindersMinutes.length === 0),
  location: count((c) => Boolean(c.expected.location)),
  recurrence: count((c) => Boolean(c.expected.recurrence)),
  approximatePeriod: count((c) => c.expected.timePeriodDefault === true),
  danishClockPhrase: count((c) => c.expected.danishClockPhrase === true),
  recurrenceInterval: count((c) => (c.expected.recurrence?.interval ?? 0) >= 3),
  explicitCalendar: count((c) => c.expected.calendarStrategy === "explicit_name"),
  categoryCalendar: count((c) => c.expected.calendarStrategy === "category"),
  defaultCalendar: count((c) => c.expected.calendarStrategy === "default"),
  clarification: count((c) => Boolean(c.expected.clarification)),
  autoSave: count((c) => c.expected.autoSaveEligible === true),
  review: count((c) => c.expected.autoSaveEligible === false),
  defaultTitle: count((c) => c.expected.defaultTitle === true),
  dateRisk: count((c) => c.expected.reviewReason === "date_risk"),
  recurrenceReview: count((c) => c.expected.reviewReason === "recurrence"),
  unmatchedCalendar: count((c) => c.expected.reviewReason === "calendar_name_unmatched")
};

const thresholds = {
  attendees: 5,
  emptyAttendees: 1,
  reminders: 7,
  noReminders: 4,
  location: 5,
  recurrence: 5,
  approximatePeriod: 2,
  danishClockPhrase: 2,
  recurrenceInterval: 1,
  explicitCalendar: 5,
  categoryCalendar: 10,
  defaultCalendar: 5,
  clarification: 5,
  autoSave: 14,
  review: 8,
  defaultTitle: 1,
  dateRisk: 2,
  recurrenceReview: 5,
  unmatchedCalendar: 1
};

for (const [key, minimum] of Object.entries(thresholds)) {
  assert(counts[key] >= minimum, `matrix coverage for ${key} is ${counts[key]}, expected at least ${minimum}`);
}

const codeContracts = [
  {
    label: "Danish attendee-aware title extraction",
    file: "backend",
    tokens: ["Hvis brugeren siger, hvem modet er med", "Mode med Per"]
  },
  {
    label: "Generic role exclusion",
    file: "backend",
    tokens: ["Brug ikke generiske ord som kunde"]
  },
  {
    label: "Location extraction",
    file: "backend",
    tokens: ["Hvis brugeren naevner et sted", "location"]
  },
  {
    label: "Reminder defaults and vague reminders",
    file: "backend",
    tokens: ["Pamindelsesregler", "samme morgen", "dagen for", "en time for"]
  },
  {
    label: "Approximate time periods",
    file: "backend",
    tokens: ["formiddag uden klokkeslaet betyder start kl. 09:00", "Brug ikke 'i morgen' alene", "lavere confidence end 0.90"]
  },
  {
    label: "Danish clock phrases",
    file: "backend",
    tokens: ["halv otte", "kvart over ni", "kvart i fem"]
  },
  {
    label: "Recurring events",
    file: "backend",
    tokens: ["Gentagelser skal udfyldes som recurrenceRule", "hver anden tirsdag", "hver tredje uge", "monthly", "yearly"]
  },
  {
    label: "Explicit calendar names",
    file: "backend",
    tokens: ["calendarName", "udtrykkeligt naevner en kalender"]
  },
  {
    label: "Calendar categories",
    file: "backend",
    tokens: ["calendarCategory", "work", "personal", "family"]
  },
  {
    label: "No optional clarification",
    file: "backend",
    tokens: ["Sporg aldrig om pamindelse, titel, kalender, varighed, sted, deltagere eller sluttidspunkt"]
  },
  {
    label: "Draft model carries calendar intelligence",
    file: "draft",
    tokens: ["CalendarRoutingCategory", "calendarName", "calendarCategory", "attendees", "recurrenceRule"]
  },
  {
    label: "Auto-save confidence gate",
    file: "viewModel",
    tokens: ["draftReviewReason", "low_confidence", "date_risk", "recurrence", "approximatePeriodWithoutExplicitTime"]
  },
  {
    label: "Calendar routing decision",
    file: "viewModel",
    tokens: ["routeCalendar(for", "matchingCalendar(named", "calendar_name_unmatched"]
  },
  {
    label: "Calendar save writes rich fields",
    file: "calendarService",
    tokens: ["event.location", "event.notes", "applyAlarms", "event.addRecurrenceRule"]
  },
  {
    label: "Live Activity save writes rich fields",
    file: "liveActivityActions",
    tokens: ["event.location", "event.notes", "applyAlarms", "event.addRecurrenceRule"]
  },
  {
    label: "Dynamic Island states",
    file: "widget",
    tokens: ["needsClarification", "readyToConfirm", "saved", "error"]
  },
  {
    label: "Settings calendar mappings",
    file: "settings",
    tokens: ["workCalendarIdentifier", "personalCalendarIdentifier", "familyCalendarIdentifier"]
  },
  {
    label: "Automatic failure bundles",
    file: "trace",
    tokens: ["preserveFailureBundle", "tid-failure-bundles"]
  }
];

for (const contract of codeContracts) {
  const content = normalize(codeFiles[contract.file]);
  for (const token of contract.tokens) {
    assert(
      content.includes(normalize(token)),
      `code contract '${contract.label}' missing token '${token}' in ${contract.file}`
    );
  }
}

if (summaryPath) {
  fs.mkdirSync(path.dirname(summaryPath), { recursive: true });
  fs.writeFileSync(summaryPath, renderSummary(), "utf8");
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`FAIL: ${failure}`);
  }
  process.exit(1);
}

console.log(`Regression matrix passed: ${cases.length} cases`);
for (const [key, value] of Object.entries(counts)) {
  console.log(`${key}: ${value}`);
}

function read(relativePath) {
  return fs.readFileSync(path.join(rootDir, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) failures.push(message);
}

function assertString(value, label) {
  assert(typeof value === "string" && value.trim().length > 0, `${label} must be a non-empty string`);
}

function count(predicate) {
  return cases.filter(predicate).length;
}

function normalize(value) {
  return String(value)
    .toLowerCase()
    .replaceAll("æ", "ae")
    .replaceAll("ø", "o")
    .replaceAll("å", "a")
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "");
}

function renderSummary() {
  const lines = [
    "# Tid Calendar Command Regression Matrix",
    "",
    `- Created: \`${new Date().toISOString()}\``,
    `- Cases: \`${cases.length}\``,
    "",
    "## Coverage",
    "",
    "| Area | Count | Minimum |",
    "| --- | ---: | ---: |"
  ];

  for (const [key, minimum] of Object.entries(thresholds)) {
    lines.push(`| ${key} | ${counts[key]} | ${minimum} |`);
  }

  lines.push("", "## Cases", "", "| ID | Utterance | Expected behavior |", "| --- | --- | --- |");

  for (const testCase of cases) {
    const expected = testCase.expected;
    const behavior = [
      expected.title ? `title: ${expected.title}` : null,
      expected.clarification ? `clarification: ${expected.clarification}` : null,
      expected.startTime ? `start: ${expected.startTime}` : null,
      expected.endTime ? `end: ${expected.endTime}` : null,
      expected.durationMinutes ? `duration: ${expected.durationMinutes}m` : null,
      expected.calendarStrategy ? `calendar: ${expected.calendarStrategy}` : null,
      expected.calendarName ? `name: ${expected.calendarName}` : null,
      expected.calendarCategory ? `category: ${expected.calendarCategory}` : null,
      expected.remindersMinutes ? `reminders: [${expected.remindersMinutes.join(", ")}]` : null,
      expected.recurrence ? `recurrence: ${expected.recurrence.frequency}/${expected.recurrence.interval}` : null,
      expected.reviewReason ? `review: ${expected.reviewReason}` : "auto-save"
    ]
      .filter(Boolean)
      .join("; ");

    lines.push(`| ${testCase.id} | ${escapeMarkdown(testCase.utterance)} | ${escapeMarkdown(behavior)} |`);
  }

  return `${lines.join("\n")}\n`;
}

function escapeMarkdown(value) {
  return String(value).replace(/\|/g, "\\|");
}
