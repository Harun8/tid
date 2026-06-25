import Foundation

final class MockRealtimeClient: RealtimeClient {
    let events: AsyncStream<RealtimeClientEvent>

    private let continuation: AsyncStream<RealtimeClientEvent>.Continuation
    private var isConnected = false
    private var scenarioGeneration = 0

    init() {
        var capturedContinuation: AsyncStream<RealtimeClientEvent>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func connect() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
        isConnected = true
        continuation.yield(.connected)
    }

    func setPendingConversationContext(_ text: String?) {}

    func startListening() async throws {
        if !isConnected {
            try await connect()
        }

        scenarioGeneration += 1
        let generation = scenarioGeneration
        continuation.yield(.listeningStarted)
        try await Task.sleep(nanoseconds: 500_000_000)
        guard generation == scenarioGeneration else { return }
        continuation.yield(.partialTranscript("\"Sæt en tid i kalenderen tirsdag d. 23...\""))
        try await Task.sleep(nanoseconds: 900_000_000)
        guard generation == scenarioGeneration else { return }
        continuation.yield(.finalTranscript("Hej øhh sæt en tid i kalenderen tirsdag d. 23 at jeg skal mødes med min ven og husk mig på det 5 timer og 2 timer før."))
        try await Task.sleep(nanoseconds: 600_000_000)
        guard generation == scenarioGeneration else { return }
        continuation.yield(.clarificationQuestion("Hvad tid skal jeg sætte det til?"))
    }

    func stopListening() async throws {
        scenarioGeneration += 1
        continuation.yield(.assistantText("Lytning stoppet."))
    }

    func sendUserText(_ text: String) async throws {
        scenarioGeneration += 1
        let generation = scenarioGeneration
        continuation.yield(.listeningStarted)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard generation == scenarioGeneration else { return }
        continuation.yield(.finalTranscript(text))
        try await Task.sleep(nanoseconds: 450_000_000)
        guard generation == scenarioGeneration else { return }

        let start = nextTuesdayThe23rd(hour: 18, minute: 0)
        let end = start.addingTimeInterval(60 * 60)
        let draft = CalendarEventDraft(
            title: "Mødes med min ven",
            startDate: start,
            endDate: end,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            alarmsMinutesBefore: [300, 120],
            confidence: 0.91,
            originalUtterance: "Hej øhh sæt en tid i kalenderen tirsdag d. 23..."
        )

        continuation.yield(.assistantText("Klar til at gemme"))
        continuation.yield(.calendarDraft(draft))
    }

    func disconnect() async {
        scenarioGeneration += 1
        continuation.yield(.disconnected)
        continuation.finish()
    }

    private func nextTuesdayThe23rd(hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        for year in currentYear...(currentYear + 8) {
            for month in 1...12 {
                var components = DateComponents()
                components.calendar = calendar
                components.timeZone = calendar.timeZone
                components.year = year
                components.month = month
                components.day = 23
                components.hour = hour
                components.minute = minute

                guard let date = calendar.date(from: components), date > now else { continue }
                if calendar.component(.weekday, from: date) == 3 {
                    return date
                }
            }
        }

        return now.addingTimeInterval(86_400)
    }
}
