import Foundation

enum CalendarRoutingCategory: String, Codable, CaseIterable, Equatable {
    case work
    case personal
    case family

    var displayTitle: String {
        switch self {
        case .work:
            return "Arbejde"
        case .personal:
            return "Privat"
        case .family:
            return "Familie"
        }
    }
}

struct CalendarEventDraft: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var timeZoneIdentifier: String
    var alarmsMinutesBefore: [Int]
    var location: String?
    var attendees: [String]
    var recurrenceRule: CalendarRecurrenceRule?
    var notes: String?
    var calendarIdentifier: String?
    var calendarName: String?
    var calendarCategory: CalendarRoutingCategory?
    var confidence: Double?
    var originalUtterance: String?

    init(
        id: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date,
        timeZoneIdentifier: String,
        alarmsMinutesBefore: [Int],
        location: String? = nil,
        attendees: [String] = [],
        recurrenceRule: CalendarRecurrenceRule? = nil,
        notes: String? = nil,
        calendarIdentifier: String? = nil,
        calendarName: String? = nil,
        calendarCategory: CalendarRoutingCategory? = nil,
        confidence: Double? = nil,
        originalUtterance: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.alarmsMinutesBefore = alarmsMinutesBefore
        self.location = location
        self.attendees = attendees
        self.recurrenceRule = recurrenceRule
        self.notes = notes
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.calendarCategory = calendarCategory
        self.confidence = confidence
        self.originalUtterance = originalUtterance
    }
}

struct CalendarRecurrenceRule: Codable, Equatable {
    enum Frequency: String, Codable {
        case daily
        case weekly
        case monthly
        case yearly
    }

    var frequency: Frequency
    var interval: Int
    var endDate: Date?
    var occurrenceCount: Int?

    init(
        frequency: Frequency,
        interval: Int = 1,
        endDate: Date? = nil,
        occurrenceCount: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.endDate = endDate
        self.occurrenceCount = occurrenceCount
    }
}

struct CalendarEventToolPayload: Codable {
    var title: String?
    var startISO8601: String
    var endISO8601: String
    var timeZone: String
    var alarmsMinutesBefore: [Int]
    var location: String?
    var attendees: [String]?
    var recurrenceRule: CalendarEventToolRecurrenceRule?
    var notes: String?
    var calendarName: String?
    var calendarCategory: CalendarRoutingCategory?
    var confidence: Double?
    var originalUtterance: String?
}

struct CalendarEventToolRecurrenceRule: Codable {
    var frequency: CalendarRecurrenceRule.Frequency
    var interval: Int?
    var endISO8601: String?
    var occurrenceCount: Int?

    func makeRecurrenceRule() throws -> CalendarRecurrenceRule {
        let parsedEndDate: Date?
        if let endISO8601, !endISO8601.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let date = DateFormatting.parseISO8601(endISO8601) else {
                throw CalendarEventDraftError.invalidDate("recurrenceRule.endISO8601")
            }
            parsedEndDate = date
        } else {
            parsedEndDate = nil
        }

        return CalendarRecurrenceRule(
            frequency: frequency,
            interval: interval ?? 1,
            endDate: parsedEndDate,
            occurrenceCount: occurrenceCount
        )
    }
}

extension CalendarEventToolPayload {
    func makeDraft(defaultCalendarIdentifier: String?) throws -> CalendarEventDraft {
        guard let startDate = DateFormatting.parseISO8601(startISO8601) else {
            throw CalendarEventDraftError.invalidDate("startISO8601")
        }

        guard let endDate = DateFormatting.parseISO8601(endISO8601) else {
            throw CalendarEventDraftError.invalidDate("endISO8601")
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let draft = CalendarEventDraft(
            title: cleanTitle.isEmpty ? CalendarEventDraft.defaultTitle(originalUtterance: originalUtterance) : cleanTitle,
            startDate: startDate,
            endDate: endDate,
            timeZoneIdentifier: timeZone,
            alarmsMinutesBefore: alarmsMinutesBefore,
            location: location,
            attendees: attendees ?? [],
            recurrenceRule: try recurrenceRule?.makeRecurrenceRule(),
            notes: notes,
            calendarIdentifier: defaultCalendarIdentifier,
            calendarName: calendarName,
            calendarCategory: calendarCategory,
            confidence: confidence,
            originalUtterance: originalUtterance
        )

        return try draft.validatedForCalendar()
    }
}

extension CalendarEventDraft {
    static let automaticSaveConfidenceThreshold = 0.90

    var notesForCalendar: String? {
        var sections: [String] = []

        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !attendees.isEmpty {
            sections.append("Deltagere: \(attendees.joined(separator: ", "))")
        }

        if let originalUtterance, !originalUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Oprindelig stemmekommando: \(originalUtterance.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    var canSkipConfirmation: Bool {
        guard let confidence else { return false }
        return confidence >= Self.automaticSaveConfidenceThreshold
    }

    var needsCarefulReview: Bool {
        !canSkipConfirmation
    }

    func validatedForCalendar() throws -> CalendarEventDraft {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw CalendarEventDraftError.invalidTimeZone(timeZoneIdentifier)
        }

        guard endDate > startDate else {
            throw CalendarEventDraftError.invalidDateRange
        }

        guard alarmsMinutesBefore.allSatisfy({ $0 >= 0 }) else {
            throw CalendarEventDraftError.invalidAlarm
        }

        var copy = self
        copy.title = cleanTitle.isEmpty ? Self.defaultTitle(originalUtterance: originalUtterance) : cleanTitle
        copy.alarmsMinutesBefore = Array(Set(alarmsMinutesBefore)).sorted(by: >)
        copy.location = Self.cleanedOptional(location)
        copy.attendees = Self.cleanedUniqueValues(attendees)
        copy.recurrenceRule = try recurrenceRule?.validated()
        copy.notes = Self.cleanedOptional(notes)
        copy.calendarName = Self.cleanedOptional(calendarName)
        return copy
    }

    private static func cleanedOptional(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanedUniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()

        return values.compactMap { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }

            let key = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return cleaned
        }
    }

    static func defaultTitle(originalUtterance: String?) -> String {
        let rawUtterance = originalUtterance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let utterance = rawUtterance.lowercased()
        if utterance.contains("møde") || utterance.contains("mødes") || utterance.contains("meeting") {
            if let participant = participantTitleSuffix(from: rawUtterance) {
                return "Møde med \(participant)"
            }
            return "Møde"
        }

        return "Aftale"
    }

    private static func participantTitleSuffix(from utterance: String) -> String? {
        let pattern = #"(?i)\b(?:møde|mødes|meeting|kaffemøde|frokost|aftale)\b.*?\b(?:sammen med|med|hos)\s+(.+?)(?=\s+(?:i morgen|imorgen|i dag|idag|på|klokken|kl\.|fra|til|og jeg|med påmindelse|hver|den|d\.|om)\b|[,.]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: utterance,
                range: NSRange(utterance.startIndex..<utterance.endIndex, in: utterance)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: utterance) else {
            return nil
        }

        let cleaned = utterance[range]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        let lowercased = cleaned.lowercased()
        guard !cleaned.isEmpty,
              !lowercased.contains("påmind"),
              !lowercased.contains("reminder") else {
            return nil
        }

        return cleaned
    }
}

extension CalendarRecurrenceRule {
    func validated() throws -> CalendarRecurrenceRule {
        guard interval >= 1 else {
            throw CalendarEventDraftError.invalidRecurrence
        }

        if let occurrenceCount, occurrenceCount < 1 {
            throw CalendarEventDraftError.invalidRecurrence
        }

        return self
    }
}

enum CalendarEventDraftError: LocalizedError {
    case invalidDate(String)
    case invalidTimeZone(String)
    case invalidDateRange
    case invalidAlarm
    case invalidRecurrence

    var errorDescription: String? {
        switch self {
        case .invalidDate(let field):
            return "Kunne ikke læse datoen i \(field)."
        case .invalidTimeZone(let value):
            return "Tidszonen er ugyldig: \(value)."
        case .invalidDateRange:
            return "Sluttidspunktet skal være efter starttidspunktet."
        case .invalidAlarm:
            return "Påmindelser skal være 0 minutter eller mere før aftalen."
        case .invalidRecurrence:
            return "Gentagelsen er ugyldig."
        }
    }
}
