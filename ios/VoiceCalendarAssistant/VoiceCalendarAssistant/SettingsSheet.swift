import AVFoundation
import EventKit
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore
    @State private var setupStatus = SetupStatusSnapshot.checking
    @State private var isRefreshingSetupStatus = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    ForEach(setupStatus.items) { item in
                        SettingsStatusRow(item: item)
                    }

                    Button {
                        Task { await refreshSetupStatus() }
                    } label: {
                        HStack {
                            Image(systemName: isRefreshingSetupStatus ? "hourglass" : "arrow.clockwise")
                            Text("Opdater status")
                        }
                    }
                    .disabled(isRefreshingSetupStatus)
                }

                Section {
                    Menu {
                        ForEach(settings.availableCalendars) { calendar in
                            Button(calendar.title) {
                                settings.defaultCalendarIdentifier = calendar.identifier
                                settings.defaultCalendarTitle = calendar.title
                            }
                        }
                    } label: {
                        SettingsValueRow(title: "Standardkalender", value: settings.defaultCalendarTitle)
                    }

                    Menu {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                            Button("\(minutes) minutter") {
                                settings.defaultDurationMinutes = minutes
                            }
                        }
                    } label: {
                        SettingsValueRow(title: "Standardvarighed", value: "\(settings.defaultDurationMinutes) minutter")
                    }

                    SettingsValueRow(title: "Automatisk gemning", value: "Sikre aftaler")
                    SettingsValueRow(title: "Privatliv", value: "På enheden og din server")
                }

                Section("Kalenderrouting") {
                    ForEach(CalendarRoutingCategory.allCases, id: \.self) { category in
                        Menu {
                            Button("Brug standardkalender") {
                                settings.setRoutingCalendar(nil, for: category)
                            }

                            if !settings.availableCalendars.isEmpty {
                                Divider()
                            }

                            ForEach(settings.availableCalendars) { calendar in
                                Button(calendar.title) {
                                    settings.setRoutingCalendar(calendar, for: category)
                                }
                            }
                        } label: {
                            SettingsValueRow(
                                title: category.displayTitle,
                                value: settings.routingCalendarTitle(for: category)
                            )
                        }
                    }
                }

                #if DEBUG
                Section("Diagnostik") {
                    NavigationLink {
                        TraceDebugView()
                    } label: {
                        SettingsValueRow(title: "Sporing", value: "Seneste hændelser")
                    }

                    SettingsValueRow(title: "Model", value: settings.modelName)
                    SettingsValueRow(title: "Backend", value: settings.backendURLString)
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(TidDesign.background)
            .navigationTitle("Indstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Færdig") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await refreshSetupStatus()
        }
    }

    private func refreshSetupStatus() async {
        isRefreshingSetupStatus = true
        setupStatus = .checking
        let backendURL = settings.backendURL
        setupStatus = await SetupStatusSnapshot.evaluate(backendURL: backendURL)
        isRefreshingSetupStatus = false
    }
}

#if DEBUG
private struct TraceDebugView: View {
    @State private var lines: [String] = []
    @State private var reloadedAt: Date?

    var body: some View {
        List {
            Section {
                if let path = AppTrace.traceLogURL?.path {
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(TidDesign.textSecondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Logfil")
            }

            Section {
                if lines.isEmpty {
                    Text("Ingen spor endnu.")
                        .foregroundStyle(TidDesign.textSecondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(TidDesign.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Seneste \(lines.count)")
                    if let reloadedAt {
                        Spacer()
                        Text(reloadedAt.formatted(date: .omitted, time: .standard))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TidDesign.background)
        .navigationTitle("Sporing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Opdater")

                Button("Ryd") {
                    AppTrace.clear()
                    reload()
                }
            }
        }
        .task {
            reload()
        }
    }

    private func reload() {
        lines = AppTrace.recentLines()
        reloadedAt = Date()
    }
}
#endif

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(TidDesign.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(TidDesign.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

private struct SettingsStatusRow: View {
    let item: SetupStatusItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.level.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.level.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .foregroundStyle(TidDesign.textPrimary)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(TidDesign.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Text(item.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.level.color)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 3)
    }
}

private struct SetupStatusSnapshot {
    var items: [SetupStatusItem]

    static let checking = SetupStatusSnapshot(
        items: [
            SetupStatusItem(title: "Backend", value: "Tjekker", detail: nil, level: .checking),
            SetupStatusItem(title: "Mikrofon", value: "Tjekker", detail: nil, level: .checking),
            SetupStatusItem(title: "Kalender", value: "Tjekker", detail: nil, level: .checking),
            SetupStatusItem(title: "Lokalnetværk", value: "Tjekker", detail: nil, level: .checking),
            SetupStatusItem(title: "Action Button", value: "Tjekker", detail: nil, level: .checking)
        ]
    )

    static func evaluate(backendURL: URL?) async -> SetupStatusSnapshot {
        async let backend = backendStatus(backendURL: backendURL)
        let backendItem = await backend

        return SetupStatusSnapshot(
            items: [
                backendItem,
                microphoneStatus(),
                calendarStatus(),
                localNetworkStatus(backendURL: backendURL, backendItem: backendItem),
                actionButtonStatus()
            ]
        )
    }

    private static func backendStatus(backendURL: URL?) async -> SetupStatusItem {
        guard let backendURL else {
            return SetupStatusItem(
                title: "Backend",
                value: "Mangler",
                detail: "URL mangler",
                level: .blocked
            )
        }

        let configURL = backendURL.appending(path: "config")
        var request = URLRequest(url: configURL)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return SetupStatusItem(title: "Backend", value: "Ugyldig", detail: backendURL.host(), level: .blocked)
            }

            if (200..<300).contains(httpResponse.statusCode) {
                return SetupStatusItem(title: "Backend", value: "OK", detail: backendURL.host(), level: .ready)
            }

            return SetupStatusItem(
                title: "Backend",
                value: "\(httpResponse.statusCode)",
                detail: backendURL.host(),
                level: .blocked
            )
        } catch {
            return SetupStatusItem(
                title: "Backend",
                value: "Nede",
                detail: backendURL.host(),
                level: .blocked
            )
        }
    }

    private static func microphoneStatus() -> SetupStatusItem {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return SetupStatusItem(title: "Mikrofon", value: "OK", detail: nil, level: .ready)
        case .denied:
            return SetupStatusItem(title: "Mikrofon", value: "Mangler", detail: "iOS-indstillinger", level: .blocked)
        case .undetermined:
            return SetupStatusItem(title: "Mikrofon", value: "Ikke spurgt", detail: nil, level: .warning)
        @unknown default:
            return SetupStatusItem(title: "Mikrofon", value: "Ukendt", detail: nil, level: .unknown)
        }
    }

    private static func calendarStatus() -> SetupStatusItem {
        let status = EKEventStore.authorizationStatus(for: .event)

        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess, .writeOnly:
                return SetupStatusItem(title: "Kalender", value: "OK", detail: nil, level: .ready)
            case .denied, .restricted:
                return SetupStatusItem(title: "Kalender", value: "Mangler", detail: "iOS-indstillinger", level: .blocked)
            case .notDetermined:
                return SetupStatusItem(title: "Kalender", value: "Ikke spurgt", detail: nil, level: .warning)
            @unknown default:
                return SetupStatusItem(title: "Kalender", value: "Ukendt", detail: nil, level: .unknown)
            }
        } else {
            switch status {
            case .authorized:
                return SetupStatusItem(title: "Kalender", value: "OK", detail: nil, level: .ready)
            case .denied, .restricted:
                return SetupStatusItem(title: "Kalender", value: "Mangler", detail: "iOS-indstillinger", level: .blocked)
            case .notDetermined:
                return SetupStatusItem(title: "Kalender", value: "Ikke spurgt", detail: nil, level: .warning)
            @unknown default:
                return SetupStatusItem(title: "Kalender", value: "Ukendt", detail: nil, level: .unknown)
            }
        }
    }

    private static func localNetworkStatus(backendURL: URL?, backendItem: SetupStatusItem) -> SetupStatusItem {
        guard let host = backendURL?.host(), isLocalNetworkHost(host) else {
            return SetupStatusItem(title: "Lokalnetværk", value: "Ikke brugt", detail: nil, level: .unknown)
        }

        if backendItem.level == .ready {
            return SetupStatusItem(title: "Lokalnetværk", value: "OK", detail: host, level: .ready)
        }

        return SetupStatusItem(title: "Lokalnetværk", value: "Tjek", detail: host, level: .warning)
    }

    private static func actionButtonStatus() -> SetupStatusItem {
        SetupStatusItem(
            title: "Action Button",
            value: "Klar",
            detail: "Start assistent",
            level: .ready
        )
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        host == "localhost"
            || host.hasPrefix("127.")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
    }
}

private struct SetupStatusItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String?
    let level: SetupStatusLevel
}

private enum SetupStatusLevel {
    case checking
    case ready
    case warning
    case blocked
    case unknown

    var systemImage: String {
        switch self {
        case .checking:
            return "hourglass"
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.circle.fill"
        case .unknown:
            return "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking:
            return TidDesign.textSecondary
        case .ready:
            return TidDesign.success
        case .warning:
            return Color(hex: 0xF5A524)
        case .blocked:
            return TidDesign.error
        case .unknown:
            return TidDesign.textSecondary
        }
    }
}
