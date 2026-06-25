import Foundation

enum AssistantUIState {
    case idle
    case connecting
    case listening(transcript: String?)
    case thinking
    case needsClarification(question: String, summary: String?)
    case readyToConfirm(CalendarEventDraft)
    case saving
    case saved(CalendarEventDraft)
    case error(TidRecoveryPresentation)
}

extension VoiceAssistantViewModel {
    var uiState: AssistantUIState {
        switch status {
        case .ready:
            return .idle
        case .connecting:
            return .connecting
        case .listening:
            return .listening(transcript: partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        case .thinking:
            return isSaving ? .saving : .thinking
        case .missingInformation:
            let question = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Hvad tid skal jeg sætte det til?"
            return .needsClarification(question: question, summary: clarificationSummary)
        case .readyToSave:
            if let draft {
                return .readyToConfirm(draft)
            }
            return .idle
        case .saved:
            if let draft {
                return .saved(draft)
            }
            return .idle
        case .error:
            return .error(
                recoveryPresentation ??
                    TidRecoveryPresentation.make(message: errorMessage ?? "Der opstod en fejl.", context: .realtime)
            )
        }
    }

    var clarificationSummary: String? {
        if let draft {
            return [
                draft.title,
                DateFormatting.danishShortDate(draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier),
                DateFormatting.danishAlarmSummary(draft.alarmsMinutesBefore)
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        }

        return finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
