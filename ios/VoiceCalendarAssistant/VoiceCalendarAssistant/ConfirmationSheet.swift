import SwiftUI

struct ConfirmationSheet: View {
    let draft: CalendarEventDraft
    let calendarName: String
    let onSave: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            SoftAuroraBackground()
            VStack(spacing: 24) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 88, height: 8)
                    .padding(.top, 10)

                Text("Klar til at gemme")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)

                eventCard

                if draft.needsCarefulReview {
                    Label("Jeg er ikke helt sikker — tjek detaljerne.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFFD166))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 14) {
                    Button(action: onEdit) {
                        Text("Ret")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SheetSecondaryButtonStyle())

                    Button(action: onSave) {
                        Text("Gem i kalender")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SheetPrimaryButtonStyle())
                }

                Button("Annuller", action: onCancel)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 48, style: .continuous))
            .padding(.top, 16)
            .padding(.horizontal, 8)

            VStack {
                Spacer()
            }
        }
        .presentationDetents([.height(sheetHeight), .large])
        .presentationDragIndicator(.hidden)
    }

    private var sheetHeight: CGFloat {
        let reviewHeight: CGFloat = draft.needsCarefulReview ? 50 : 0
        let recurrenceHeight: CGFloat = draft.recurrenceRule == nil ? 0 : 44
        return 430 + reviewHeight + recurrenceHeight
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                Text(calendarName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }

            Label(DateFormatting.danishShortDate(draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier), systemImage: "calendar")
            Label(DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier), systemImage: "clock")

            if let location = draft.location {
                Label(location, systemImage: "mappin.and.ellipse")
            }

            if !draft.attendees.isEmpty {
                Label(draft.attendees.joined(separator: ", "), systemImage: "person.2")
            }

            if let recurrence = DateFormatting.recurrenceLabel(for: draft) {
                recurrenceReviewRow(recurrence)
            }

            Divider().background(Color.white.opacity(0.2))

            HStack(spacing: 12) {
                Image(systemName: "bell")
                ForEach(draft.alarmsMinutesBefore, id: \.self) { minutes in
                    Text(DateFormatting.alarmLabel(minutesBefore: minutes))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(Color.white.opacity(0.78))
            .font(.system(size: 17, weight: .medium))
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.82))
        .padding(22)
        .background(TidTheme.cardDark, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func recurrenceReviewRow(_ recurrence: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "repeat")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0A84FF))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Gentagelse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.58))

                Text(recurrence)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
            }
        }
    }
}

private struct SheetPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(height: 76)
            .background(Color(hex: 0x0A66CC), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct SheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(height: 76)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
