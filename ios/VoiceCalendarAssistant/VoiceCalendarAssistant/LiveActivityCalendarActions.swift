import ActivityKit
import AppIntents
import EventKit
import Foundation

enum LiveActivityCalendarPayload {
    static func encode(_ draft: CalendarEventDraft) -> String? {
        guard let data = try? JSONEncoder().encode(draft) else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ payload: String) throws -> CalendarEventDraft {
        guard let data = Data(base64Encoded: payload) else {
            throw LiveActivityCalendarActionError.invalidPayload
        }

        return try JSONDecoder().decode(CalendarEventDraft.self, from: data).validatedForCalendar()
    }
}

enum LiveActivityCalendarActionError: LocalizedError {
    case invalidPayload
    case calendarAccessDenied
    case noWritableCalendar
    case saveVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Kunne ikke læse kalenderaftalen."
        case .calendarAccessDenied:
            return "Tid har ikke adgang til at skrive i kalenderen."
        case .noWritableCalendar:
            return "Der blev ikke fundet en kalender, som kan ændres."
        case .saveVerificationFailed(let details):
            return "Kalenderen blev gemt, men verificeringen fejlede: \(details)."
        }
    }
}

@available(iOS 17.0, *)
struct DismissTidLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Luk Tid"
    static var description = IntentDescription("Lukker den aktive Tid Live Activity.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        let state = TidRecordingActivityAttributes.ContentState(
            phase: .idle,
            title: "Tid",
            subtitle: "Lukket",
            detail: nil,
            startedAt: Date()
        )

        for activity in Activity<TidRecordingActivityAttributes>.activities {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }

        return .result()
    }
}

@available(iOS 17.0, *)
struct EditDraftFromLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Ret aftale"
    static var description = IntentDescription("Åbner Tid, så aftalen kan rettes.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopRecordingFromLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop optagelse"
    static var description = IntentDescription("Stopper den aktive Tid-optagelse fra Dynamic Island.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        let requestID = UUID().uuidString

        for activity in Activity<TidRecordingActivityAttributes>.activities {
            var state = activity.content.state
            guard state.phase == .listening || state.phase == .connecting else { continue }

            let isAnsweringClarification = state.title.localizedCaseInsensitiveContains("svaret") ||
                state.subtitle.localizedCaseInsensitiveContains("svar")
            state.phase = .thinking
            state.title = isAnsweringClarification ? "Forstår svaret" : "Forstår aftalen"
            state.subtitle = isAnsweringClarification ? "Behandler dit svar" : "Behandler din kalenderaftale"
            state.detail = nil
            state.confirmationPayload = nil
            state.stopRequestID = requestID

            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        return .result()
    }
}

@available(iOS 18.0, *)
struct AnswerClarificationFromLiveActivityIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Svar"
    static var description = IntentDescription("Starter en kort opfølgende optagelse til Tid.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        let requestID = UUID().uuidString

        #if LIVE_ACTIVITY_EXTENSION
        await prepareLiveActivityForAnswer(requestID: requestID)
        await keepAudioRecordingIntentAlive(requestID: requestID)
        #else
        var fields = Self.processTraceFields
        fields["request_id"] = requestID
        AppTrace.point("AnswerClarificationIntent.perform.begin", fields: fields)

        await prepareLiveActivityForAnswer(requestID: requestID)

        await withTaskCancellationHandler {
            await VoiceCalendarAssistantSession.shared.handleClarificationAnswerIntent(requestID: requestID)
        } onCancel: {
            Task { @MainActor in
                AppTrace.point("AnswerClarificationIntent.perform.cancelled", fields: ["request_id": requestID])
                await VoiceCalendarAssistantSession.shared.stopActionButtonRecordingIfNeeded(reason: "clarification_cancelled")
            }
        }

        AppTrace.point(
            "AnswerClarificationIntent.perform.end",
            fields: ["request_id": requestID]
        )
        #endif

        return .result()
    }

    private func prepareLiveActivityForAnswer(requestID: String) async {
        for activity in Activity<TidRecordingActivityAttributes>.activities {
            var state = activity.content.state
            guard state.phase == .needsClarification else { continue }

            state.phase = .connecting
            state.title = "Starter svar"
            state.subtitle = "Gør mikrofonen klar"
            state.confirmationPayload = nil
            state.answerRequestID = requestID

            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func keepAudioRecordingIntentAlive(requestID: String) async {
        let deadline = Date().addingTimeInterval(45)

        while Date() < deadline, !Task.isCancelled {
            let matchingActivity = Activity<TidRecordingActivityAttributes>.activities.first {
                $0.content.state.answerRequestID == requestID
            }

            guard let matchingActivity else { return }

            switch matchingActivity.content.state.phase {
            case .connecting, .listening, .thinking:
                try? await Task.sleep(nanoseconds: 250_000_000)
            case .idle, .needsClarification, .readyToConfirm, .saved, .error:
                return
            }
        }
    }

    #if !LIVE_ACTIVITY_EXTENSION
    private static var processTraceFields: [String: String] {
        [
            "bundle": Bundle.main.bundleIdentifier ?? "nil",
            "path": Bundle.main.bundlePath,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)"
        ]
    }
    #endif
}

@available(iOS 17.0, *)
struct SaveCalendarEventFromLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Gem i Kalender"
    static var description = IntentDescription("Gemmer den foreslåede Tid-aftale direkte i Kalender.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Aftale")
    var payload: String

    init() {
        payload = ""
    }

    init(payload: String) {
        self.payload = payload
    }

    func perform() async throws -> some IntentResult {
        do {
            let draft = try LiveActivityCalendarPayload.decode(payload)
            _ = try await LiveActivityCalendarEventWriter().createEvent(from: draft)
            await updateLiveActivityAfterSave(draft)
            return .result()
        } catch {
            await updateLiveActivityAfterFailure(error)
            throw error
        }
    }

    private func updateLiveActivityAfterSave(_ draft: CalendarEventDraft) async {
        let state = TidRecordingActivityAttributes.ContentState(
            phase: .saved,
            title: "Gemt i Kalender",
            subtitle: draft.title,
            detail: Self.detail(for: draft),
            startedAt: Date(),
            confirmationPayload: nil
        )

        for activity in Activity<TidRecordingActivityAttributes>.activities {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(30))
            )
        }
    }

    private func updateLiveActivityAfterFailure(_ error: Error) async {
        let presentation = TidRecoveryPresentation.make(for: error, context: .liveActivitySave)
        let state = TidRecordingActivityAttributes.ContentState(
            phase: .error,
            title: presentation.shortTitle,
            subtitle: presentation.shortMessage,
            detail: presentation.recovery,
            startedAt: Date(),
            confirmationPayload: nil
        )

        for activity in Activity<TidRecordingActivityAttributes>.activities {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private static func detail(for draft: CalendarEventDraft) -> String {
        [
            DateFormatting.danishShortDate(draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier),
            DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier),
            DateFormatting.recurrenceLabel(for: draft),
            draft.location,
            alarmSummary(draft.alarmsMinutesBefore)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private static func alarmSummary(_ alarmsMinutesBefore: [Int]) -> String {
        guard !alarmsMinutesBefore.isEmpty else { return "" }
        return alarmsMinutesBefore
            .sorted(by: >)
            .map(DateFormatting.alarmLabel(minutesBefore:))
            .joined(separator: ", ")
    }
}

struct LiveActivityCalendarEventWriter {
    private let eventStore = EKEventStore()

    func createEvent(from draft: CalendarEventDraft) async throws -> String {
        try await requestCalendarWriteAccess()
        let validatedDraft = try draft.validatedForCalendar()
        let calendar = try writableCalendar(for: validatedDraft)

        if let existingEvent = existingEvent(matching: validatedDraft, calendar: calendar) {
            return try verifiedEventIdentifier(
                for: existingEvent,
                draft: validatedDraft,
                calendar: calendar
            )
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = validatedDraft.title
        event.startDate = validatedDraft.startDate
        event.endDate = validatedDraft.endDate
        event.timeZone = TimeZone(identifier: validatedDraft.timeZoneIdentifier)
        event.location = validatedDraft.location
        event.notes = validatedDraft.notesForCalendar
        event.calendar = calendar

        applyAlarms(validatedDraft.alarmsMinutesBefore, to: event)

        if let recurrenceRule = eventKitRecurrenceRule(for: validatedDraft.recurrenceRule) {
            event.addRecurrenceRule(recurrenceRule)
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        return try verifiedEventIdentifier(
            for: event,
            draft: validatedDraft,
            calendar: calendar
        )
    }

    private func requestCalendarWriteAccess() async throws {
        if #available(iOS 17.0, *) {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            guard granted else { throw LiveActivityCalendarActionError.calendarAccessDenied }
        } else {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw LiveActivityCalendarActionError.calendarAccessDenied }
        }
    }

    private func writableCalendar(for draft: CalendarEventDraft) throws -> EKCalendar {
        if let calendarIdentifier = draft.calendarIdentifier,
           let selectedCalendar = eventStore.calendar(withIdentifier: calendarIdentifier),
           selectedCalendar.allowsContentModifications {
            return selectedCalendar
        }

        if let defaultCalendar = eventStore.defaultCalendarForNewEvents {
            return defaultCalendar
        }

        throw LiveActivityCalendarActionError.noWritableCalendar
    }

    private func existingEvent(matching draft: CalendarEventDraft, calendar: EKCalendar) -> EKEvent? {
        let predicate = eventStore.predicateForEvents(
            withStart: draft.startDate.addingTimeInterval(-60),
            end: draft.endDate.addingTimeInterval(60),
            calendars: [calendar]
        )

        return eventStore.events(matching: predicate)
            .first { event in
                CalendarEventVerification.issues(
                    for: event,
                    draft: draft,
                    expectedCalendar: calendar
                )
                .isEmpty
            }
    }

    private func verifiedEventIdentifier(
        for event: EKEvent,
        draft: CalendarEventDraft,
        calendar: EKCalendar
    ) throws -> String {
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw LiveActivityCalendarActionError.saveVerificationFailed("Kalenderen gav ikke et event-id.")
        }

        guard let readBackEvent = eventStore.event(withIdentifier: identifier) else { return identifier }

        let issues = CalendarEventVerification.issues(
            for: readBackEvent,
            draft: draft,
            expectedCalendar: calendar
        )

        guard issues.isEmpty else {
            throw LiveActivityCalendarActionError.saveVerificationFailed(CalendarEventVerification.summary(issues))
        }

        return identifier
    }

    private func applyAlarms(_ alarmsMinutesBefore: [Int], to event: EKEvent) {
        event.alarms?.forEach { event.removeAlarm($0) }

        alarmsMinutesBefore.forEach { minutes in
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
    }

    private func eventKitRecurrenceRule(for recurrenceRule: CalendarRecurrenceRule?) -> EKRecurrenceRule? {
        guard let recurrenceRule else { return nil }

        let end: EKRecurrenceEnd?
        if let endDate = recurrenceRule.endDate {
            end = EKRecurrenceEnd(end: endDate)
        } else if let occurrenceCount = recurrenceRule.occurrenceCount {
            end = EKRecurrenceEnd(occurrenceCount: occurrenceCount)
        } else {
            end = nil
        }

        return EKRecurrenceRule(
            recurrenceWith: eventKitFrequency(for: recurrenceRule.frequency),
            interval: recurrenceRule.interval,
            end: end
        )
    }

    private func eventKitFrequency(for frequency: CalendarRecurrenceRule.Frequency) -> EKRecurrenceFrequency {
        switch frequency {
        case .daily:
            return .daily
        case .weekly:
            return .weekly
        case .monthly:
            return .monthly
        case .yearly:
            return .yearly
        }
    }
}
