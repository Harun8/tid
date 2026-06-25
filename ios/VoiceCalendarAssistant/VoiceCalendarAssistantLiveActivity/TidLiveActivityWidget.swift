import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TidLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TidStatusWidget()
        TidRecordingLiveActivity()
    }
}

struct TidStatusWidget: Widget {
    private let kind = "TidStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TidStatusProvider()) { entry in
            TidStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Tid")
        .description("Start din kalenderassistent.")
        .supportedFamilies([.systemSmall])
    }
}

private struct TidStatusEntry: TimelineEntry {
    let date: Date
}

private struct TidStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TidStatusEntry {
        TidStatusEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (TidStatusEntry) -> Void) {
        completion(TidStatusEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TidStatusEntry>) -> Void) {
        completion(Timeline(entries: [TidStatusEntry(date: Date())], policy: .never))
    }
}

private struct TidStatusWidgetView: View {
    let entry: TidStatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(red: 0.04, green: 0.42, blue: 0.86))

            Spacer(minLength: 0)

            Text("Tid")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text("Klar til at lytte")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(16)
        .containerBackground(.black, for: .widget)
        .widgetURL(URL(string: "voicecalendar://start-listening"))
    }
}

struct TidRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TidRecordingActivityAttributes.self) { context in
            TidLockScreenActivityView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    TidIslandExpandedBody(state: context.state)
                }
            } compactLeading: {
                TidIslandCompactLeading(state: context.state)
            } compactTrailing: {
                TidIslandCompactTrailing(state: context.state)
            } minimal: {
                Image(systemName: iconName(for: context.state.phase))
                    .foregroundStyle(accentColor(for: context.state.phase))
            }
            .keylineTint(accentColor(for: context.state.phase))
        }
    }

    private func iconName(for phase: TidRecordingActivityAttributes.Phase) -> String {
        switch phase {
        case .idle:
            return "mic.circle.fill"
        case .connecting:
            return "waveform"
        case .listening:
            return "mic.fill"
        case .thinking:
            return "waveform"
        case .needsClarification:
            return "questionmark.circle.fill"
        case .readyToConfirm:
            return "calendar"
        case .saved:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private func accentColor(for phase: TidRecordingActivityAttributes.Phase) -> Color {
        switch phase {
        case .idle:
            return Color(red: 0.22, green: 0.55, blue: 0.95)
        case .connecting:
            return Color(red: 0.22, green: 0.55, blue: 0.95)
        case .saved:
            return Color(red: 0.20, green: 0.88, blue: 0.42)
        case .error:
            return Color(red: 1.0, green: 0.31, blue: 0.31)
        case .needsClarification:
            return TidIslandStyle.neutral
        default:
            return Color(red: 0.22, green: 0.55, blue: 0.95)
        }
    }
}

private struct TidIslandExpandedBody: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .listening, .connecting:
                TidIslandExpandedListeningView(state: state)
            case .thinking:
                TidIslandExpandedThinkingView(state: state)
            case .needsClarification, .error:
                TidIslandExpandedClarificationView(state: state)
            case .readyToConfirm:
                TidIslandExpandedReadyView(state: state)
            case .saved:
                TidIslandExpandedSavedView(state: state)
            case .idle:
                TidIslandExpandedIdleView(state: state)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

private struct TidIslandCompactLeading: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Text("Tid")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(TidIslandStyle.brandColor(for: state.phase))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            switch state.phase {
            case .listening, .connecting:
                TidIslandMiniWaveformView()
            case .thinking:
                TidIslandSpinner(size: 22, lineWidth: 4)
            case .needsClarification:
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TidIslandStyle.neutral)
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TidIslandStyle.red)
            case .readyToConfirm:
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TidIslandStyle.blue)
            case .saved:
                EmptyView()
            case .idle:
                EmptyView()
            }
        }
    }
}

private struct TidIslandCompactTrailing: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .listening, .connecting:
            HStack(spacing: 7) {
                Text(state.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)

                TidStopRecordingButton(isCompact: true, iconOnly: true)
            }
        case .thinking:
            TidCalendarSearchIcon(size: 22)
        case .needsClarification:
            HStack(spacing: 7) {
                TidAnswerClarificationButton(isCompact: true)
                TidDismissLiveActivityButton(isCompact: true)
            }
        case .error:
            TidDismissLiveActivityButton(isCompact: true)
        case .readyToConfirm:
            TidIslandEditButton(isCompact: true)
        case .saved:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(TidIslandStyle.green)
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TidIslandStyle.blue)
        }
    }
}

private struct TidIslandExpandedListeningView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TidIslandLogo(phase: .listening)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    TidIslandWaveformView(isRecording: true)
                        .frame(width: 150)

                    Text(state.startedAt, style: .timer)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text("Sig hvad der skal i kalenderen")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)

            TidStopRecordingButton(isCompact: false, iconOnly: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TidIslandExpandedThinkingView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 16) {
            TidIslandLogo(phase: .thinking)

            TidIslandSpinner(size: 38, lineWidth: 6)

            Text("Forstår din aftale...")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 0)

            TidCalendarSearchIcon(size: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TidIslandExpandedClarificationView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TidIslandLogo(phase: state.phase)

            VStack(alignment: .leading, spacing: 4) {
                Text(clarificationTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let subtitle = clarificationSubtitle {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 4)

            if state.phase == .error {
                TidDismissLiveActivityButton(isCompact: false)
            } else {
                TidAnswerClarificationButton(isCompact: false)
                TidDismissLiveActivityButton(isCompact: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clarificationTitle: String {
        if state.phase == .error {
            return state.title
        }

        let normalized = state.subtitle
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
            .lowercased()

        if normalized.contains("tid") || normalized.contains("klokken") {
            return "Mangler tidspunkt"
        }

        if normalized.contains("dato") || normalized.contains("dag") {
            return "Mangler dato"
        }

        return "Mangler svar"
    }

    private var clarificationSubtitle: String? {
        let value = state.phase == .error
            ? state.subtitle
            : (state.detail?.components(separatedBy: " · ").first ?? state.subtitle)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TidIslandExpandedReadyView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            TidIslandLogo(phase: .readyToConfirm)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.subtitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)

                if let detail = readyDetail {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .allowsTightening(true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            if let payload = state.confirmationPayload {
                TidSaveCalendarButton(payload: payload, isCompact: false)
            }

            TidIslandEditButton(isCompact: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyDetail: String? {
        guard let detail = state.detail, !detail.isEmpty else { return nil }
        let parts = detail.components(separatedBy: " · ")
        let shortened: String
        if parts.count >= 2 {
            let startTime = parts[1].components(separatedBy: " – ").first ?? parts[1]
            var summary = [parts[0], startTime]
            if parts.count >= 3, Self.isRecurrenceDetail(parts[2]) {
                summary.append(parts[2])
            }
            shortened = summary.joined(separator: " · ")
        } else {
            shortened = parts.prefix(2).joined(separator: " · ")
        }
        return shortened.isEmpty ? detail : shortened
    }

    private static func isRecurrenceDetail(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
            .lowercased()

        return normalized.hasPrefix("hver ")
            || normalized.hasPrefix("dagligt")
            || normalized.hasPrefix("ugentligt")
            || normalized.hasPrefix("manedligt")
            || normalized.hasPrefix("arligt")
    }
}

private struct TidIslandExpandedSavedView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TidIslandLogo(phase: .saved)

            Image(systemName: "checkmark.circle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(TidIslandStyle.green)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("Gemt i Kalender")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let detail = savedDetail {
                    Text(detail)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedDetail: String? {
        guard let detail = state.detail, !detail.isEmpty else { return nil }
        let parts = detail.components(separatedBy: " · ")
        if parts.count >= 2 {
            let startTime = parts[1].components(separatedBy: " – ").first ?? parts[1]
            return [parts[0], startTime].joined(separator: " · ")
        }
        return detail
    }
}

private struct TidIslandExpandedIdleView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TidIslandLogo(phase: .idle)

            Text("Klar til at lytte")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))

            Spacer(minLength: 0)
        }
    }
}

private struct TidIslandLogo: View {
    let phase: TidRecordingActivityAttributes.Phase

    var body: some View {
        Text("Tid")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(TidIslandStyle.brandColor(for: phase))
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .frame(width: 36, alignment: .leading)
    }
}

private struct TidIslandSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0.14, to: 0.86)
            .stroke(
                AngularGradient(
                    colors: [
                        TidIslandStyle.blue.opacity(0.18),
                        TidIslandStyle.blue,
                        TidIslandStyle.blue.opacity(0.70)
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
    }
}

private struct TidCalendarSearchIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "calendar")
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))

            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .offset(x: size * 0.12, y: size * 0.10)
        }
        .frame(width: size, height: size)
    }
}

private enum TidIslandStyle {
    static let blue = Color(red: 0.04, green: 0.42, blue: 0.94)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.24)
    static let green = Color(red: 0.22, green: 0.84, blue: 0.22)
    static let neutral = Color(red: 0.72, green: 0.75, blue: 0.80)
    static let darkControl = Color.white.opacity(0.12)

    static func brandColor(for phase: TidRecordingActivityAttributes.Phase) -> Color {
        switch phase {
        case .needsClarification:
            return neutral
        case .error:
            return red
        case .saved:
            return green
        default:
            return blue
        }
    }
}

private struct TidLockScreenActivityView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: state.phase.isRecording ? "mic.fill" : "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(red: 0.05, green: 0.39, blue: 0.80), in: Circle())

                Text("TID")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.86))

                Spacer()

                TidIslandStatusPill(state: state)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(state.title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(state.subtitle)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(3)

                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            if state.phase == .readyToConfirm, let payload = state.confirmationPayload {
                TidSaveCalendarButton(payload: payload, isCompact: false, fillsWidth: true)
                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            } else if state.phase == .needsClarification {
                TidAnswerClarificationButton(isCompact: false)
            } else if state.phase.isRecording {
                TidStopRecordingButton(isCompact: false)
                TidIslandWaveformView(isRecording: true)
                    .frame(maxWidth: .infinity)
            } else if state.phase == .thinking {
                TidIslandThinkingView(state: state)
            } else {
                TidIslandWaveformView(isRecording: state.phase.isRecording)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
    }
}

private struct TidSaveCalendarButton: View {
    let payload: String
    let isCompact: Bool
    var fillsWidth = false

    var body: some View {
        Button(intent: SaveCalendarEventFromLiveActivityIntent(payload: payload)) {
            HStack(spacing: 8) {
                Text("Gem i Kalender")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .foregroundStyle(.white)
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, isCompact ? 11 : 10)
            .padding(.vertical, isCompact ? 7 : 9)
            .background(TidIslandStyle.blue, in: Capsule())
        }
        .buttonStyle(.plain)
        .layoutPriority(2)
    }
}

private struct TidStopRecordingButton: View {
    let isCompact: Bool
    var iconOnly = false

    var body: some View {
        Button(intent: StopRecordingFromLiveActivityIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: isCompact ? 10 : 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 30 : 44, height: isCompact ? 30 : 44)
                .background(
                    RadialGradient(
                        colors: [
                            TidIslandStyle.red.opacity(0.92),
                            TidIslandStyle.red
                        ],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: isCompact ? 24 : 38
                    ),
                    in: Circle()
                )
                .shadow(color: TidIslandStyle.red.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct TidAnswerClarificationButton: View {
    let isCompact: Bool

    var body: some View {
        if #available(iOS 18.0, *) {
            Button(intent: AnswerClarificationFromLiveActivityIntent()) {
                HStack(spacing: 8) {
                    Text("Svar")
                        .font(.system(size: isCompact ? 13 : 16, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, isCompact ? 12 : 21)
                .padding(.vertical, isCompact ? 7 : 11)
                .background(TidIslandStyle.blue, in: Capsule())
                .shadow(color: TidIslandStyle.blue.opacity(0.28), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TidDismissLiveActivityButton: View {
    let isCompact: Bool

    var body: some View {
        Button(intent: DismissTidLiveActivityIntent()) {
            Image(systemName: "xmark")
                .font(.system(size: isCompact ? 11 : 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: isCompact ? 28 : 40, height: isCompact ? 28 : 40)
                .background(TidIslandStyle.darkControl, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct TidIslandEditButton: View {
    let isCompact: Bool

    var body: some View {
        Button(intent: EditDraftFromLiveActivityIntent()) {
            Image(systemName: "pencil")
                .font(.system(size: isCompact ? 12 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 30 : 36, height: isCompact ? 30 : 36)
                .background(TidIslandStyle.blue, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct TidCompactSaveCalendarButton: View {
    let payload: String

    var body: some View {
        Button(intent: SaveCalendarEventFromLiveActivityIntent(payload: payload)) {
            Text("Gem")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(red: 0.04, green: 0.42, blue: 0.86), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TidCompactStopRecordingButton: View {
    var body: some View {
        Button(intent: StopRecordingFromLiveActivityIntent()) {
            Image(systemName: "stop.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color(red: 1.0, green: 0.26, blue: 0.26))
                .frame(width: 25, height: 18)
                .background(Color(red: 0.32, green: 0.02, blue: 0.02).opacity(0.92), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TidCompactAnswerClarificationButton: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            Button(intent: AnswerClarificationFromLiveActivityIntent()) {
                Text("Svar")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.04, green: 0.42, blue: 0.86), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TidIslandConfirmationSummaryView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.28, green: 0.86, blue: 0.44))

            Text("Klar til at gemme")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct TidIslandThinkingSummaryView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(red: 0.62, green: 0.78, blue: 1.0))

            Text(state.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct TidIslandClarificationSummaryView: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(TidIslandStyle.neutral)

            Text("Mangler svar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct TidIslandThinkingView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TidIslandProgressDotsView()

                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }

            Text(state.subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }
}

private struct TidIslandProgressDotsView: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == 1 ? Color(red: 0.62, green: 0.78, blue: 1.0) : .white.opacity(0.62))
                    .frame(width: index == 1 ? 7 : 5, height: index == 1 ? 7 : 5)
            }
        }
        .frame(width: 28, height: 16, alignment: .leading)
    }
}

private struct TidIslandClarificationView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TidAnswerClarificationButton(isCompact: true)

            Text(state.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.84)

            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }
}

private struct TidIslandRecordingControlView: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TidStopRecordingButton(isCompact: true)

            Text(state.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.84)

            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }
}

private struct TidIslandConfirmationView: View {
    let state: TidRecordingActivityAttributes.ContentState
    let payload: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TidSaveCalendarButton(payload: payload, isCompact: true)

            Text(state.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.84)

            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }
}

private struct TidIslandBrandView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(Color(red: 0.62, green: 0.78, blue: 1.0))

            Text("Tid")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct TidIslandStatusPill: View {
    let state: TidRecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    private var dotColor: Color {
        switch state.phase {
        case .idle:
            return Color(red: 0.33, green: 0.62, blue: 1.0)
        case .connecting:
            return Color(red: 0.33, green: 0.62, blue: 1.0)
        case .saved:
            return Color(red: 0.20, green: 0.88, blue: 0.42)
        case .error:
            return Color(red: 1.0, green: 0.31, blue: 0.31)
        case .listening:
            return Color(red: 1.0, green: 0.23, blue: 0.23)
        default:
            return Color(red: 0.33, green: 0.62, blue: 1.0)
        }
    }

    private var statusText: String {
        switch state.phase {
        case .idle:
            return "Tid klar"
        case .connecting:
            return "Starter..."
        case .listening:
            return "Tid lytter..."
        case .thinking:
            return "Forstår..."
        case .needsClarification:
            return "Mangler svar"
        case .readyToConfirm:
            return "Klar til gem"
        case .saved:
            return "Gemt"
        case .error:
            return "Fejl"
        }
    }
}

private struct TidIslandWaveformView: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<13, id: \.self) { index in
                Capsule()
                    .fill(barColor(index: index))
                    .frame(width: 4, height: barHeight(index: index))
            }
        }
        .frame(height: 34)
        .opacity(isRecording ? 1 : 0.72)
    }

    private func barHeight(index: Int) -> CGFloat {
        let pattern: [CGFloat] = [10, 18, 26, 15, 30, 20, 34, 18, 29, 15, 25, 17, 10]
        return isRecording ? pattern[index] : max(8, pattern[index] * 0.45)
    }

    private func barColor(index: Int) -> Color {
        if !isRecording {
            return .white.opacity(0.46)
        }

        if index.isMultiple(of: 4) {
            return TidIslandStyle.blue.opacity(0.72)
        }

        return TidIslandStyle.blue
    }
}

private struct TidIslandMiniWaveformView: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(TidIslandStyle.blue)
                    .frame(width: 3, height: barHeight(index: index))
            }
        }
        .frame(width: 34, height: 22)
        .clipped()
    }

    private func barHeight(index: Int) -> CGFloat {
        let pattern: [CGFloat] = [10, 16, 22, 14, 20, 12]
        return pattern[index]
    }
}
