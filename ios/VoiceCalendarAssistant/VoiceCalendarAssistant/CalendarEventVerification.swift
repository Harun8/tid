import EventKit
import Foundation

enum CalendarEventVerification {
    static func issues(
        for event: EKEvent,
        draft: CalendarEventDraft,
        expectedCalendar: EKCalendar
    ) -> [String] {
        var issues: [String] = []

        if event.title != draft.title {
            issues.append("titel")
        }

        if abs(event.startDate.timeIntervalSince(draft.startDate)) > 1 {
            issues.append("starttid")
        }

        if abs(event.endDate.timeIntervalSince(draft.endDate)) > 1 {
            issues.append("sluttid")
        }

        if event.calendar?.calendarIdentifier != expectedCalendar.calendarIdentifier {
            issues.append("kalender")
        }

        if normalizedOptional(event.location) != normalizedOptional(draft.location) {
            issues.append("sted")
        }

        if normalizedOptional(event.notes) != normalizedOptional(draft.notesForCalendar) {
            issues.append("noter")
        }

        if alarmMinutesBefore(for: event) != draft.alarmsMinutesBefore.sorted(by: >) {
            issues.append("påmindelser")
        }

        if let recurrenceIssue = recurrenceIssue(for: event, draft: draft) {
            issues.append(recurrenceIssue)
        }

        return issues
    }

    static func summary(_ issues: [String]) -> String {
        issues.isEmpty ? "OK" : issues.joined(separator: ", ")
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func alarmMinutesBefore(for event: EKEvent) -> [Int] {
        guard let alarms = event.alarms else { return [] }

        return Array(Set(alarms.compactMap { alarm -> Int? in
            guard alarm.relativeOffset <= 0 else { return nil }
            return Int(round(-alarm.relativeOffset / 60))
        }))
        .sorted(by: >)
    }

    private static func recurrenceIssue(for event: EKEvent, draft: CalendarEventDraft) -> String? {
        guard let draftRule = draft.recurrenceRule else {
            return event.recurrenceRules?.isEmpty == false ? "gentagelse" : nil
        }

        guard let eventRule = event.recurrenceRules?.first else {
            return "gentagelse"
        }

        guard eventRule.frequency == eventKitFrequency(for: draftRule.frequency),
              eventRule.interval == draftRule.interval else {
            return "gentagelse"
        }

        let eventEnd = eventRule.recurrenceEnd
        if let occurrenceCount = draftRule.occurrenceCount {
            guard eventEnd?.occurrenceCount == occurrenceCount else {
                return "gentagelse"
            }
        } else if let endDate = draftRule.endDate {
            guard let savedEndDate = eventEnd?.endDate,
                  abs(savedEndDate.timeIntervalSince(endDate)) <= 1 else {
                return "gentagelse"
            }
        } else if eventEnd != nil {
            return "gentagelse"
        }

        return nil
    }

    private static func eventKitFrequency(for frequency: CalendarRecurrenceRule.Frequency) -> EKRecurrenceFrequency {
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
