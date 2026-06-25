import Foundation

extension ISO8601DateFormatter {
    static let tidInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let tidInternetDateTimeWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum DateFormatting {
    static func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter.tidInternetDateTime.date(from: value)
            ?? ISO8601DateFormatter.tidInternetDateTimeWithoutFractions.date(from: value)
    }

    static func danishDate(_ date: Date, timeZoneIdentifier: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    static func danishShortDate(_ date: Date, timeZoneIdentifier: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.setLocalizedDateFormatFromTemplate("EEEE d. MMMM")
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    static func danishTime(_ date: Date, timeZoneIdentifier: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateFormat = "HH:mm"
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    static func danishTimeInterval(start: Date, end: Date, timeZoneIdentifier: String? = nil) -> String {
        "\(danishTime(start, timeZoneIdentifier: timeZoneIdentifier)) – \(danishTime(end, timeZoneIdentifier: timeZoneIdentifier))"
    }

    static func alarmLabel(minutesBefore: Int) -> String {
        if minutesBefore % 60 == 0 {
            let hours = minutesBefore / 60
            return hours == 1 ? "1 time før" : "\(hours) timer før"
        }

        return minutesBefore == 1 ? "1 minut før" : "\(minutesBefore) minutter før"
    }

    static func recurrenceLabel(for draft: CalendarEventDraft) -> String? {
        recurrenceLabel(
            draft.recurrenceRule,
            startDate: draft.startDate,
            timeZoneIdentifier: draft.timeZoneIdentifier
        )
    }

    static func recurrenceLabel(
        _ recurrenceRule: CalendarRecurrenceRule?,
        startDate: Date? = nil,
        timeZoneIdentifier: String? = nil
    ) -> String? {
        guard let recurrenceRule else { return nil }

        let base: String
        switch recurrenceRule.frequency {
        case .daily:
            base = recurrenceRule.interval == 1 ? "Dagligt" : "Hver \(recurrenceRule.interval). dag"
        case .weekly:
            if let weekday = startDate.map({ danishWeekday($0, timeZoneIdentifier: timeZoneIdentifier) }) {
                if recurrenceRule.interval == 1 {
                    base = "Hver \(weekday)"
                } else if recurrenceRule.interval == 2 {
                    base = "Hver anden \(weekday)"
                } else {
                    base = "Hver \(recurrenceRule.interval). uge på \(weekday)"
                }
            } else {
                base = recurrenceRule.interval == 1 ? "Ugentligt" : "Hver \(recurrenceRule.interval). uge"
            }
        case .monthly:
            if let startDate {
                let day = calendar(timeZoneIdentifier: timeZoneIdentifier).component(.day, from: startDate)
                base = recurrenceRule.interval == 1 ? "Månedligt den \(day)." : "Hver \(recurrenceRule.interval). måned den \(day)."
            } else {
                base = recurrenceRule.interval == 1 ? "Månedligt" : "Hver \(recurrenceRule.interval). måned"
            }
        case .yearly:
            if let startDate {
                base = recurrenceRule.interval == 1
                    ? "Årligt \(danishMonthDay(startDate, timeZoneIdentifier: timeZoneIdentifier))"
                    : "Hvert \(recurrenceRule.interval). år \(danishMonthDay(startDate, timeZoneIdentifier: timeZoneIdentifier))"
            } else {
                base = recurrenceRule.interval == 1 ? "Årligt" : "Hvert \(recurrenceRule.interval). år"
            }
        }

        if let occurrenceCount = recurrenceRule.occurrenceCount {
            return "\(base) · \(occurrenceCount) gange"
        }

        if let endDate = recurrenceRule.endDate {
            return "\(base) · indtil \(danishShortDate(endDate, timeZoneIdentifier: timeZoneIdentifier))"
        }

        return base
    }

    private static func danishWeekday(_ date: Date, timeZoneIdentifier: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateFormat = "EEEE"
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date).lowercased()
    }

    private static func danishMonthDay(_ date: Date, timeZoneIdentifier: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    private static func calendar(timeZoneIdentifier: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        calendar.locale = Locale(identifier: "da_DK")
        return calendar
    }
}
