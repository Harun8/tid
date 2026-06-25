import SwiftUI

struct ConfirmationPreviewView: View {
    let draft: CalendarEventDraft
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                Text("Klar til at gemme")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)
                    .lineLimit(2)

                Text("\(DateFormatting.danishShortDate(draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier)) · \(DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier))")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(TidDesign.textSecondary)
                    .lineLimit(2)

                if let location = draft.location {
                    Text(location)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(TidDesign.textSecondary)
                        .lineLimit(1)
                }

                if let recurrence = DateFormatting.recurrenceLabel(for: draft) {
                    Text("Gentagelse: \(recurrence)")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(TidDesign.textSecondary)
                        .lineLimit(2)
                }

                Text("Påmindelser: \(DateFormatting.danishAlarmSummary(draft.alarmsMinutesBefore))")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(TidDesign.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TidDesign.elevatedCard, in: RoundedRectangle(cornerRadius: TidDesign.compactCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TidDesign.compactCornerRadius, style: .continuous)
                .stroke(TidDesign.outline, lineWidth: 1)
        )
    }
}

extension DateFormatting {
    static func danishAlarmSummary(_ alarmsMinutesBefore: [Int]) -> String {
        guard !alarmsMinutesBefore.isEmpty else { return "Ingen" }
        return alarmsMinutesBefore
            .sorted(by: >)
            .map(alarmLabel(minutesBefore:))
            .joined(separator: ", ")
    }
}
