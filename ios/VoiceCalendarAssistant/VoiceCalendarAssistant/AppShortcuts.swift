import ActivityKit
import AppIntents
import Foundation

enum AppLaunchIntentKeys {
    static let startListening = "TidStartListeningOnLaunch"
}

@available(iOS 18.0, *)
struct StartCalendarAssistantIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Start kalenderassistent"
    static var description = IntentDescription("Starter eller stopper Tid uden først at åbne appen.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    func perform() async throws -> some IntentResult {
        let preparedStopRequestID = await ActionButtonLiveActivityStopTransition.prepareIfRecording()
        AppTrace.point(
            "ActionButtonIntent.perform.start",
            fields: [
                "bundle": Bundle.main.bundleIdentifier ?? "nil",
                "path": Bundle.main.bundlePath,
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                "prepared_stop": "\(preparedStopRequestID != nil)"
            ]
        )
        await withTaskCancellationHandler {
            if let preparedStopRequestID {
                await VoiceCalendarAssistantSession.shared.handlePreparedActionButtonStop(requestID: preparedStopRequestID)
            } else {
                await VoiceCalendarAssistantSession.shared.handleActionButtonPress()
            }
        } onCancel: {
            Task { @MainActor in
                AppTrace.point("ActionButtonIntent.perform.cancelled")
                await VoiceCalendarAssistantSession.shared.stopActionButtonRecordingIfNeeded(reason: "cancelled")
            }
        }
        AppTrace.point("ActionButtonIntent.perform.end")
        return .result()
    }
}

@available(iOS 17.0, *)
private enum ActionButtonLiveActivityStopTransition {
    private static let staleRecordingAge: TimeInterval = 90

    static func prepareIfRecording() async -> String? {
        let requestID = UUID().uuidString
        var didPrepare = false

        for activity in Activity<TidRecordingActivityAttributes>.activities {
            var state = activity.content.state
            guard state.phase == .listening || state.phase == .connecting else { continue }

            if Date().timeIntervalSince(state.startedAt) > staleRecordingAge {
                await activity.end(
                    ActivityContent(
                        state: TidRecordingActivityAttributes.ContentState(
                            phase: .idle,
                            title: "Tid",
                            subtitle: "Lukket",
                            detail: nil,
                            startedAt: Date()
                        ),
                        staleDate: nil
                    ),
                    dismissalPolicy: .immediate
                )
                AppTrace.point(
                    "ActionButtonIntent.staleRecordingActivityCleared",
                    fields: ["phase": state.phase.rawValue, "request_id": requestID]
                )
                continue
            }

            let isAnsweringClarification = state.title.localizedCaseInsensitiveContains("svaret") ||
                state.subtitle.localizedCaseInsensitiveContains("svar")
            state.phase = .thinking
            state.title = isAnsweringClarification ? "Forstår svaret" : "Forstår aftalen"
            state.subtitle = isAnsweringClarification ? "Behandler dit svar" : "Behandler din kalenderaftale"
            state.detail = isAnsweringClarification ? "Kombinerer med aftalen" : "Finder dato, tid og påmindelser"
            state.confirmationPayload = nil
            state.stopRequestID = requestID

            await activity.update(ActivityContent(state: state, staleDate: nil))
            didPrepare = true
        }

        if didPrepare {
            AppTrace.point("ActionButtonIntent.preparedStopLiveActivity", fields: ["request_id": requestID])
        }

        return didPrepare ? requestID : nil
    }
}

@available(iOS 18.0, *)
struct VoiceCalendarAssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCalendarAssistantIntent(),
            phrases: [
                "Start kalenderassistent med \(.applicationName)",
                "Lyt med \(.applicationName)"
            ],
            shortTitle: "Start assistent",
            systemImageName: "mic.circle.fill"
        )
    }
}
