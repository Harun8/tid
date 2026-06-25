import Foundation

protocol RealtimeClient {
    var events: AsyncStream<RealtimeClientEvent> { get }
    func connect() async throws
    func setPendingConversationContext(_ text: String?)
    func startListening() async throws
    func stopListening() async throws
    func sendUserText(_ text: String) async throws
    func disconnect() async
}

enum RealtimeClientEvent {
    case connected
    case disconnected
    case listeningStarted
    case inputAudioLevel(Double)
    case partialTranscript(String)
    case finalTranscript(String)
    case assistantText(String)
    case assistantAudioStarted
    case assistantAudioEnded
    case responseCompleted
    case calendarDraft(CalendarEventDraft)
    case clarificationQuestion(String)
    case error(String)
}

enum RealtimeClientError: LocalizedError {
    case backendURLMissing
    case webRTCSetupFailed
    case microphoneCaptureFailed
    case dataChannelUnavailable
    case invalidServerResponse
    case localNetworkUnavailable
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .backendURLMissing:
            return "Backend URL mangler eller er ugyldig."
        case .webRTCSetupFailed:
            return "Kunne ikke starte WebRTC-forbindelsen."
        case .microphoneCaptureFailed:
            return "Kunne ikke starte mikrofonoptagelse."
        case .dataChannelUnavailable:
            return "Realtime-kanalen er ikke klar endnu."
        case .invalidServerResponse:
            return "Backend svarede ikke med et gyldigt Realtime-svar."
        case .localNetworkUnavailable:
            return "Tid kan ikke nå udviklingsserveren. Åbn appen og tillad Lokalnetværk, og tjek at iPhone og Mac er på samme Wi-Fi."
        case .serverError(let message):
            return message
        }
    }
}
