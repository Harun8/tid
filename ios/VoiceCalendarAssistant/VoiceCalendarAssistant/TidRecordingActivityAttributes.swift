import ActivityKit
import Foundation

struct TidRecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var title: String
        var subtitle: String
        var detail: String?
        var startedAt: Date
        var confirmationPayload: String? = nil
        var stopRequestID: String? = nil
        var answerRequestID: String? = nil
    }

    enum Phase: String, Codable, Hashable {
        case idle
        case connecting
        case listening
        case thinking
        case needsClarification
        case readyToConfirm
        case saved
        case error

        var isRecording: Bool {
            self == .listening
        }
    }

    var sessionID: String
}

enum TidRecoveryContext: String, Codable, Hashable {
    case startListening
    case stopListening
    case realtime
    case calendarSave
    case draftValidation
    case autoClarification
    case loadCalendars
    case liveActivitySave
    case debug
}

struct TidRecoveryPresentation: Codable, Hashable {
    var title: String
    var message: String
    var recovery: String
    var shortTitle: String
    var shortMessage: String
    var category: String
    var actionTitle: String

    static func make(
        for error: Error,
        context: TidRecoveryContext,
        fallbackMessage: String? = nil
    ) -> TidRecoveryPresentation {
        let message = fallbackMessage ?? error.localizedDescription
        return make(
            message: message,
            typeName: String(reflecting: type(of: error)),
            context: context
        )
    }

    static func make(
        message: String,
        typeName: String = "",
        context: TidRecoveryContext
    ) -> TidRecoveryPresentation {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnosticText = [trimmedMessage, typeName, context.rawValue].joined(separator: " ")
        let normalized = normalizedDanish(diagnosticText)

        if normalized.contains("buffer too small") || normalized.contains("ikke nok lyd") {
            return TidRecoveryPresentation(
                title: "For lidt lyd",
                message: "Tid fik ikke nok lyd til at forstå aftalen.",
                recovery: "Hold knappen lidt længere, tal færdigt, og stop igen.",
                shortTitle: "For lidt lyd",
                shortMessage: "Hold knappen lidt længere.",
                category: "audio_too_short",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("permissionerror") ||
            normalized.contains("mikrofonadgang") ||
            normalized.contains("microphone denied") ||
            normalized.contains("record permission") {
            return TidRecoveryPresentation(
                title: "Mikrofonadgang mangler",
                message: "Tid har ikke adgang til mikrofonen.",
                recovery: "Åbn iOS-indstillinger for Tid og slå Mikrofon til.",
                shortTitle: "Mikrofon mangler",
                shortMessage: "Giv Tid mikrofonadgang.",
                category: "microphone_permission",
                actionTitle: "Tjek indstillinger"
            )
        }

        if normalized.contains("microphonecapturefailed") ||
            normalized.contains("kunne ikke starte mikrofon") ||
            normalized.contains("mikrofonen var ikke klar") ||
            normalized.contains("audio session") ||
            normalized.contains("avaudio") {
            return TidRecoveryPresentation(
                title: "Mikrofonen er optaget",
                message: "iOS gav ikke Tid en stabil mikrofonoptagelse.",
                recovery: "Luk andre optagelser, vent et øjeblik, og prøv igen. Tid nulstiller mikrofonen automatisk.",
                shortTitle: "Mikrofon optaget",
                shortMessage: "Vent kort og prøv igen.",
                category: "microphone_unavailable",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("backend url") || normalized.contains("backendurlmissing") {
            return TidRecoveryPresentation(
                title: "Backend mangler",
                message: "Tid har ikke en gyldig backend-adresse.",
                recovery: "Åbn Indstillinger i Tid og tjek backend-URL'en.",
                shortTitle: "Backend mangler",
                shortMessage: "Tjek backend-URL.",
                category: "backend_url_missing",
                actionTitle: "Åbn indstillinger"
            )
        }

        if normalized.contains("lokalnet") ||
            normalized.contains("udviklingsserver") ||
            normalized.contains("localnetworkunavailable") ||
            normalized.contains("cannot connect") ||
            normalized.contains("could not connect") ||
            normalized.contains("cannot find host") ||
            normalized.contains("not connected to internet") ||
            normalized.contains("timed out") ||
            normalized.contains("network connection") ||
            normalized.contains("health-check") {
            return TidRecoveryPresentation(
                title: "Backend kan ikke nås",
                message: "Tid kan ikke nå udviklingsserveren.",
                recovery: "Tjek at backend kører på din Mac, at iPhone og Mac er på samme Wi-Fi, og at Lokalnetværk er tilladt for Tid.",
                shortTitle: "Backend nede",
                shortMessage: "Tjek Wi-Fi og backend.",
                category: "backend_unreachable",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("401") ||
            normalized.contains("unauthorized") ||
            normalized.contains("token") ||
            normalized.contains("adgangstoken") {
            return TidRecoveryPresentation(
                title: "Backend afviser Tid",
                message: "Backend accepterede ikke appens adgang.",
                recovery: "I testsetup skal backend-auth være slået fra, eller adgangstokenet skal matche.",
                shortTitle: "Backend afviser",
                shortMessage: "Tjek adgangstoken.",
                category: "backend_auth",
                actionTitle: "Tjek backend"
            )
        }

        if normalized.contains("openai") ||
            normalized.contains("api key") ||
            normalized.contains("realtime er midlertidigt") ||
            normalized.contains("servererror") {
            return TidRecoveryPresentation(
                title: "OpenAI svarer ikke",
                message: "Backend kunne ikke oprette en Realtime-session.",
                recovery: "Prøv igen om lidt. Hvis det fortsætter, tjek OpenAI API-nøglen og backend-loggen.",
                shortTitle: "OpenAI fejl",
                shortMessage: "Prøv igen om lidt.",
                category: "openai_realtime",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("webrtc") ||
            normalized.contains("datachannel") ||
            normalized.contains("realtime-kanal") ||
            normalized.contains("forbindelsen fejlede") ||
            normalized.contains("connection failed") {
            return TidRecoveryPresentation(
                title: "Realtime-forbindelsen faldt ud",
                message: "Forbindelsen mellem Tid og Realtime blev afbrudt.",
                recovery: "Prøv igen. Tid nulstiller forbindelsen automatisk inden næste optagelse.",
                shortTitle: "Realtime afbrudt",
                shortMessage: "Prøv igen.",
                category: "realtime_connection",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("invalidpayload") ||
            normalized.contains("kunne ikke laese kalenderaftalen") {
            return TidRecoveryPresentation(
                title: "Aftalen kunne ikke læses",
                message: "Tid kunne ikke læse kalenderforslaget fra Dynamic Island.",
                recovery: "Åbn Tid og prøv at oprette aftalen igen.",
                shortTitle: "Aftale ugyldig",
                shortMessage: "Prøv igen i Tid.",
                category: "live_activity_payload",
                actionTitle: "Prøv igen"
            )
        }

        if normalized.contains("saveverificationfailed") ||
            normalized.contains("verificering") ||
            normalized.contains("verification") ||
            normalized.contains("matcher ikke") {
            return TidRecoveryPresentation(
                title: "Kalenderen kunne ikke verificeres",
                message: "Tid gemte aftalen, men kunne ikke bekræfte at Kalender indeholder alle felter korrekt.",
                recovery: "Åbn Kalender og tjek aftalen. Tracepakken viser hvilke felter der ikke matchede.",
                shortTitle: "Tjek Kalender",
                shortMessage: "Aftalen kunne ikke verificeres.",
                category: "calendar_verification",
                actionTitle: "Prøv igen"
            )
        }

        if context == .calendarSave ||
            context == .loadCalendars ||
            context == .liveActivitySave ||
            normalized.contains("calendarserviceerror") ||
            normalized.contains("liveactivitycalendaractionerror") ||
            normalized.contains("kalenderadgang") ||
            normalized.contains("skrive i kalender") ||
            normalized.contains("eventkit") {
            if normalized.contains("ingen skrivbar") ||
                normalized.contains("ikke fundet en kalender") ||
                normalized.contains("no writable") {
                return TidRecoveryPresentation(
                    title: "Ingen skrivbar kalender",
                    message: "Tid fandt ikke en kalender, der kan ændres.",
                    recovery: "Vælg en anden standardkalender i Tid, eller opret en skrivbar kalender på iPhone.",
                    shortTitle: "Ingen kalender",
                    shortMessage: "Vælg en skrivbar kalender.",
                    category: "calendar_unwritable",
                    actionTitle: "Tjek kalender"
                )
            }

            return TidRecoveryPresentation(
                title: "Kalenderadgang mangler",
                message: "Tid kunne ikke gemme i Kalender.",
                recovery: "Åbn iOS-indstillinger for Tid og giv adgang til Kalender.",
                shortTitle: "Kalender mangler",
                shortMessage: "Giv Tid kalenderadgang.",
                category: "calendar_permission",
                actionTitle: "Tjek indstillinger"
            )
        }

        if context == .draftValidation ||
            normalized.contains("calendareventdrafterror") ||
            normalized.contains("kunne ikke laese dato") ||
            normalized.contains("sluttidspunktet") ||
            normalized.contains("tidszonen") ||
            normalized.contains("gentagelsen") ||
            normalized.contains("pamindelser") {
            return TidRecoveryPresentation(
                title: "Aftalen kunne ikke læses",
                message: trimmedMessage.isEmpty ? "Tid kunne ikke lave en gyldig kalenderaftale." : trimmedMessage,
                recovery: "Prøv igen med dato og tidspunkt tydeligt sagt.",
                shortTitle: "Aftale ugyldig",
                shortMessage: "Sig dato og tid tydeligt.",
                category: "draft_validation",
                actionTitle: "Prøv igen"
            )
        }

        if context == .autoClarification {
            return TidRecoveryPresentation(
                title: "Svaret kunne ikke sendes",
                message: "Tid kunne ikke sende den automatiske afklaring til Realtime.",
                recovery: "Prøv igen. Tid nulstiller forbindelsen automatisk.",
                shortTitle: "Svar fejlede",
                shortMessage: "Prøv igen.",
                category: "auto_clarification",
                actionTitle: "Prøv igen"
            )
        }

        return TidRecoveryPresentation(
            title: "Ukendt fejl",
            message: trimmedMessage.isEmpty ? "Tid ramte en ukendt fejl." : trimmedMessage,
            recovery: "Prøv igen. Tid har gemt en tracepakke, så fejlen kan undersøges.",
            shortTitle: "Fejl",
            shortMessage: "Prøv igen.",
            category: "unknown",
            actionTitle: "Prøv igen"
        )
    }

    private static func normalizedDanish(_ text: String) -> String {
        var normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
            .lowercased()
        let replacements = [
            "æ": "ae",
            "ø": "o",
            "å": "a"
        ]
        for (source, replacement) in replacements {
            normalized = normalized.replacingOccurrences(of: source, with: replacement)
        }
        return normalized
    }
}
