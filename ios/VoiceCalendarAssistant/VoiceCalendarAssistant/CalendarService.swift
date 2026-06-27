import EventKit
import Foundation

@MainActor
final class CalendarService {
    private let eventStore = EKEventStore()
    private var cachedCalendars: [CalendarInfo]?
    private var cachedCalendarsLoadedAt: Date?
    private var cachedCalendarsAuthorizationStatus: EKAuthorizationStatus?
    private static let calendarCacheTTL: TimeInterval = 60

    func requestCalendarWriteAccess() async throws {
        invalidateCalendarCache()

        if #available(iOS 17.0, *) {
            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestWriteOnlyAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }

            guard granted else { throw CalendarServiceError.accessDenied }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }

            guard granted else { throw CalendarServiceError.accessDenied }
        }
    }

    func createEvent(from draft: CalendarEventDraft) async throws -> String {
        AppTrace.point(
            "CalendarService.createEvent.requested",
            fields: [
                "alarms_count": "\(draft.alarmsMinutesBefore.count)",
                "has_recurrence": "\(draft.recurrenceRule != nil)",
                "title_chars": "\(draft.title.count)"
            ]
        )

        try await AppTrace.measure("CalendarService.requestCalendarWriteAccess") {
            try await requestCalendarWriteAccess()
        }
        let validatedDraft = try AppTrace.measure("CalendarService.validateDraft") {
            try draft.validatedForCalendar()
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = validatedDraft.title
        event.startDate = validatedDraft.startDate
        event.endDate = validatedDraft.endDate
        event.timeZone = TimeZone(identifier: validatedDraft.timeZoneIdentifier)
        event.location = validatedDraft.location
        event.notes = validatedDraft.notesForCalendar

        let selectedCalendar = validatedDraft.calendarIdentifier.flatMap { calendarIdentifier in
            AppTrace.measure("CalendarService.resolveSelectedCalendar") {
                eventStore.calendar(withIdentifier: calendarIdentifier)
            }
        }

        if let selectedCalendar, selectedCalendar.allowsContentModifications {
            event.calendar = selectedCalendar
        } else if let defaultCalendar = eventStore.defaultCalendarForNewEvents {
            event.calendar = defaultCalendar
        } else {
            throw CalendarServiceError.noWritableCalendar
        }

        if let existingEvent = existingEvent(matching: validatedDraft, calendar: event.calendar) {
            AppTrace.point("CalendarService.existingEventMatched")
            return try verifiedEventIdentifier(
                for: existingEvent,
                draft: validatedDraft,
                calendar: event.calendar,
                source: "existing"
            )
        }

        applyAlarms(validatedDraft.alarmsMinutesBefore, to: event)

        if let recurrenceRule = eventKitRecurrenceRule(for: validatedDraft.recurrenceRule) {
            event.addRecurrenceRule(recurrenceRule)
        }

        try AppTrace.measure("CalendarService.eventStore.save") {
            try eventStore.save(event, span: .thisEvent, commit: true)
        }
        return try verifiedEventIdentifier(
            for: event,
            draft: validatedDraft,
            calendar: event.calendar,
            source: "created"
        )
    }

    func availableCalendars() async throws -> [CalendarInfo] {
        if let cachedCalendars = cachedCalendarsIfFresh() {
            AppTrace.point(
                "CalendarService.availableCalendars.cacheHit",
                fields: ["count": "\(cachedCalendars.count)"]
            )
            return cachedCalendars
        }

        if #available(iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .writeOnly else {
                try await requestCalendarWriteAccess()
                let calendars = defaultCalendarOnly()
                cacheCalendars(calendars)
                return calendars
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .authorized else {
                try await requestCalendarWriteAccess()
                let calendars = defaultCalendarOnly()
                cacheCalendars(calendars)
                return calendars
            }
        }

        let calendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                CalendarInfo(
                    identifier: $0.calendarIdentifier,
                    title: $0.title,
                    allowsContentModifications: $0.allowsContentModifications
                )
            }

        let resolvedCalendars = calendars.isEmpty ? defaultCalendarOnly() : calendars
        cacheCalendars(resolvedCalendars)
        return resolvedCalendars
    }

    func availableCalendarsIfAuthorized() async throws -> [CalendarInfo]? {
        if let cachedCalendars = cachedCalendarsIfFresh() {
            AppTrace.point(
                "CalendarService.availableCalendars.authorizedCacheHit",
                fields: ["count": "\(cachedCalendars.count)"]
            )
            return cachedCalendars
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            guard status == .fullAccess || status == .writeOnly else { return nil }
        } else {
            guard status == .authorized else { return nil }
        }

        return try await availableCalendars()
    }

    private func defaultCalendarOnly() -> [CalendarInfo] {
        guard let calendar = eventStore.defaultCalendarForNewEvents else { return [] }
        return [
            CalendarInfo(
                identifier: calendar.calendarIdentifier,
                title: calendar.title,
                allowsContentModifications: calendar.allowsContentModifications
            )
        ]
    }

    private func cachedCalendarsIfFresh(now: Date = Date()) -> [CalendarInfo]? {
        guard let cachedCalendars,
              let cachedCalendarsLoadedAt,
              cachedCalendarsAuthorizationStatus == EKEventStore.authorizationStatus(for: .event),
              now.timeIntervalSince(cachedCalendarsLoadedAt) < Self.calendarCacheTTL else {
            return nil
        }

        return cachedCalendars
    }

    private func cacheCalendars(_ calendars: [CalendarInfo]) {
        cachedCalendars = calendars
        cachedCalendarsLoadedAt = Date()
        cachedCalendarsAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        AppTrace.point(
            "CalendarService.availableCalendars.cacheStore",
            fields: ["count": "\(calendars.count)"]
        )
    }

    private func invalidateCalendarCache() {
        cachedCalendars = nil
        cachedCalendarsLoadedAt = nil
        cachedCalendarsAuthorizationStatus = nil
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
        calendar: EKCalendar,
        source: String
    ) throws -> String {
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw CalendarServiceError.saveVerificationFailed("Kalenderen gav ikke et event-id.")
        }

        guard let readBackEvent = eventStore.event(withIdentifier: identifier) else {
            AppTrace.point(
                "CalendarService.saveVerification",
                fields: [
                    "source": source,
                    "read_back": "false",
                    "issues": "skipped",
                    "reason": "read_back_unavailable"
                ]
            )
            return identifier
        }

        let issues = CalendarEventVerification.issues(
            for: readBackEvent,
            draft: draft,
            expectedCalendar: calendar
        )

        AppTrace.point(
            "CalendarService.saveVerification",
            fields: [
                "source": source,
                "read_back": "\(readBackEvent != nil)",
                "issues": CalendarEventVerification.summary(issues)
            ]
        )

        guard issues.isEmpty else {
            throw CalendarServiceError.saveVerificationFailed(CalendarEventVerification.summary(issues))
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

enum CalendarServiceError: LocalizedError {
    case accessDenied
    case noWritableCalendar
    case saveVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Tid har ikke adgang til at skrive i kalenderen."
        case .noWritableCalendar:
            return "Der blev ikke fundet en kalender, som kan ændres."
        case .saveVerificationFailed(let details):
            return "Kalenderen blev gemt, men verificeringen fejlede: \(details)."
        }
    }
}
