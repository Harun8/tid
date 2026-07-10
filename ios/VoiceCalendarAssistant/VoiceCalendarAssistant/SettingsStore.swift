import Foundation

struct CalendarInfo: Codable, Equatable, Identifiable {
    var id: String { identifier }
    var identifier: String
    var title: String
    var allowsContentModifications: Bool
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var defaultCalendarIdentifier: String? {
        didSet { defaults.set(defaultCalendarIdentifier, forKey: Keys.defaultCalendarIdentifier) }
    }

    @Published var defaultCalendarTitle: String {
        didSet { defaults.set(defaultCalendarTitle, forKey: Keys.defaultCalendarTitle) }
    }

    @Published var workCalendarIdentifier: String? {
        didSet { defaults.set(workCalendarIdentifier, forKey: Keys.workCalendarIdentifier) }
    }

    @Published var workCalendarTitle: String {
        didSet { defaults.set(workCalendarTitle, forKey: Keys.workCalendarTitle) }
    }

    @Published var personalCalendarIdentifier: String? {
        didSet { defaults.set(personalCalendarIdentifier, forKey: Keys.personalCalendarIdentifier) }
    }

    @Published var personalCalendarTitle: String {
        didSet { defaults.set(personalCalendarTitle, forKey: Keys.personalCalendarTitle) }
    }

    @Published var familyCalendarIdentifier: String? {
        didSet { defaults.set(familyCalendarIdentifier, forKey: Keys.familyCalendarIdentifier) }
    }

    @Published var familyCalendarTitle: String {
        didSet { defaults.set(familyCalendarTitle, forKey: Keys.familyCalendarTitle) }
    }

    @Published var defaultDurationMinutes: Int {
        didSet { defaults.set(defaultDurationMinutes, forKey: Keys.defaultDurationMinutes) }
    }

    @Published var requiresConfirmation: Bool {
        didSet { defaults.set(requiresConfirmation, forKey: Keys.requiresConfirmation) }
    }

    @Published var backendURLString: String {
        didSet { defaults.set(backendURLString, forKey: Keys.backendURLString) }
    }

    @Published var backendAuthToken: String {
        didSet { defaults.set(backendAuthToken, forKey: Keys.backendAuthToken) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var voiceName: String {
        didSet { defaults.set(voiceName, forKey: Keys.voiceName) }
    }

    @Published var safetyIdentifier: String {
        didSet { defaults.set(safetyIdentifier, forKey: Keys.safetyIdentifier) }
    }

    @Published var availableCalendars: [CalendarInfo] = []

    var localeDisplay: String {
        Locale.autoupdatingCurrent.identifier
    }

    var timeZoneDisplay: String {
        TimeZone.autoupdatingCurrent.identifier
    }

    private let defaults: UserDefaults
    private static let developmentBackendURLString = "http://Harun.local:3000"
    private static let defaultRealtimeModel = "gpt-realtime-mini"
    private static let previousRealtimeModelDefault = "gpt-realtime-2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultCalendarIdentifier = defaults.string(forKey: Keys.defaultCalendarIdentifier)
        defaultCalendarTitle = defaults.string(forKey: Keys.defaultCalendarTitle) ?? "Privat"
        workCalendarIdentifier = defaults.string(forKey: Keys.workCalendarIdentifier)
        workCalendarTitle = defaults.string(forKey: Keys.workCalendarTitle) ?? Self.useDefaultCalendarTitle
        personalCalendarIdentifier = defaults.string(forKey: Keys.personalCalendarIdentifier)
        personalCalendarTitle = defaults.string(forKey: Keys.personalCalendarTitle) ?? Self.useDefaultCalendarTitle
        familyCalendarIdentifier = defaults.string(forKey: Keys.familyCalendarIdentifier)
        familyCalendarTitle = defaults.string(forKey: Keys.familyCalendarTitle) ?? Self.useDefaultCalendarTitle
        let storedDuration = defaults.integer(forKey: Keys.defaultDurationMinutes)
        defaultDurationMinutes = storedDuration == 0 ? 60 : storedDuration
        requiresConfirmation = defaults.object(forKey: Keys.requiresConfirmation) as? Bool ?? true
        backendURLString = Self.developmentBackendURLString
        backendAuthToken = ""
        defaults.set(Self.developmentBackendURLString, forKey: Keys.backendURLString)
        defaults.set("", forKey: Keys.backendAuthToken)
        let storedModelName = defaults.string(forKey: Keys.modelName)
        let selectedModelName: String
        if storedModelName == nil || storedModelName == Self.previousRealtimeModelDefault {
            selectedModelName = Self.defaultRealtimeModel
        } else {
            selectedModelName = storedModelName ?? Self.defaultRealtimeModel
        }
        modelName = selectedModelName
        defaults.set(selectedModelName, forKey: Keys.modelName)
        voiceName = defaults.string(forKey: Keys.voiceName) ?? "marin"
        safetyIdentifier = Self.installationSafetyIdentifier(defaults: defaults)
    }

    func setAvailableCalendars(_ calendars: [CalendarInfo]) {
        availableCalendars = calendars

        if defaultCalendarIdentifier == nil, let first = calendars.first {
            defaultCalendarIdentifier = first.identifier
            defaultCalendarTitle = first.title
        } else if let selected = calendars.first(where: { $0.identifier == defaultCalendarIdentifier }) {
            defaultCalendarTitle = selected.title
        }

        refreshRoutingTitle(for: .work, calendars: calendars)
        refreshRoutingTitle(for: .personal, calendars: calendars)
        refreshRoutingTitle(for: .family, calendars: calendars)
    }

    func calendarIdentifier(for category: CalendarRoutingCategory) -> String? {
        switch category {
        case .work:
            return workCalendarIdentifier
        case .personal:
            return personalCalendarIdentifier
        case .family:
            return familyCalendarIdentifier
        }
    }

    func routingCalendarTitle(for category: CalendarRoutingCategory) -> String {
        switch category {
        case .work:
            return workCalendarTitle
        case .personal:
            return personalCalendarTitle
        case .family:
            return familyCalendarTitle
        }
    }

    func setRoutingCalendar(_ calendar: CalendarInfo?, for category: CalendarRoutingCategory) {
        let identifier = calendar?.identifier
        let title = calendar?.title ?? Self.useDefaultCalendarTitle

        switch category {
        case .work:
            workCalendarIdentifier = identifier
            workCalendarTitle = title
        case .personal:
            personalCalendarIdentifier = identifier
            personalCalendarTitle = title
        case .family:
            familyCalendarIdentifier = identifier
            familyCalendarTitle = title
        }
    }

    var backendURL: URL? {
        URL(string: backendURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func refreshRoutingTitle(for category: CalendarRoutingCategory, calendars: [CalendarInfo]) {
        guard let identifier = calendarIdentifier(for: category) else {
            setRoutingCalendar(nil, for: category)
            return
        }

        guard let selected = calendars.first(where: { $0.identifier == identifier }) else { return }
        setRoutingCalendar(selected, for: category)
    }

    private enum Keys {
        static let defaultCalendarIdentifier = "defaultCalendarIdentifier"
        static let defaultCalendarTitle = "defaultCalendarTitle"
        static let workCalendarIdentifier = "workCalendarIdentifier"
        static let workCalendarTitle = "workCalendarTitle"
        static let personalCalendarIdentifier = "personalCalendarIdentifier"
        static let personalCalendarTitle = "personalCalendarTitle"
        static let familyCalendarIdentifier = "familyCalendarIdentifier"
        static let familyCalendarTitle = "familyCalendarTitle"
        static let defaultDurationMinutes = "defaultDurationMinutes"
        static let requiresConfirmation = "requiresConfirmation"
        static let backendURLString = "backendURLString"
        static let backendAuthToken = "backendAuthToken"
        static let modelName = "modelName"
        static let voiceName = "voiceName"
        static let safetyIdentifier = "safetyIdentifier"
    }

    private static let useDefaultCalendarTitle = "Standard"

    private static func installationSafetyIdentifier(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: Keys.safetyIdentifier), !existing.isEmpty {
            return existing
        }

        let generated = "tid-\(UUID().uuidString)"
        defaults.set(generated, forKey: Keys.safetyIdentifier)
        return generated
    }
}
