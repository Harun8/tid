import Foundation

@MainActor
final class VoiceCalendarAssistantSession {
    static let shared = VoiceCalendarAssistantSession()

    let settingsStore: SettingsStore
    let viewModel: VoiceAssistantViewModel
    private let maxActionButtonRecordingDuration: TimeInterval = 30
    private let maxActionButtonProcessingDuration: TimeInterval = 35
    private let minimumActionButtonListeningDuration: TimeInterval = 6.0
    private let actionButtonSilenceDuration: TimeInterval = 5.0
    private var handledLiveActivityStopRequestID: String?
    private var actionButtonMonitorTask: Task<Void, Never>?
    private var actionButtonMonitorID: UUID?

    private init() {
        let settings = SettingsStore()
        settingsStore = settings
        viewModel = VoiceAssistantViewModel(settings: settings)
    }

    func handleActionButtonPress() async {
        AppTrace.point("ActionButtonIntent.handlePress", fields: ["status": viewModel.status.rawValue])

        switch viewModel.status {
        case .connecting:
            stopActionButtonMonitor()
            await viewModel.stopListening()
        case .listening:
            stopActionButtonMonitor()
            await viewModel.stopListening()
            await keepProcessingAliveForActionButtonSession(source: "action_button_stop")
        case .thinking:
            await keepProcessingAliveForActionButtonSession(source: "action_button_stop")
        case .ready, .missingInformation, .readyToSave, .saved, .error:
            await viewModel.startListening(source: .actionButton)
            startActionButtonMonitor(source: "action_button")
        }
    }

    func handlePreparedActionButtonStop(requestID: String) async {
        handledLiveActivityStopRequestID = requestID
        AppTrace.point(
            "ActionButtonIntent.handlePreparedStop",
            fields: ["request_id": requestID, "status": viewModel.status.rawValue]
        )

        stopActionButtonMonitor()

        switch viewModel.status {
        case .connecting:
            await viewModel.stopListening()
        case .listening:
            await viewModel.stopListening()
        case .thinking:
            break
        case .ready, .missingInformation, .readyToSave, .saved, .error:
            AppTrace.point(
                "ActionButtonIntent.preparedStopNoActiveRecorder",
                fields: ["request_id": requestID, "status": viewModel.status.rawValue]
            )
        }

        await keepProcessingAliveForActionButtonSession(source: "action_button_stop")
    }

    func handleClarificationAnswerIntent(requestID: String) async {
        AppTrace.point(
            "AnswerClarificationIntent.startSecondRecording.direct",
            fields: ["request_id": requestID, "status": viewModel.status.rawValue]
        )

        guard viewModel.status == .missingInformation else {
            AppTrace.point(
                "AnswerClarificationIntent.ignored",
                fields: ["request_id": requestID, "status": viewModel.status.rawValue]
            )
            return
        }

        await viewModel.startListening(source: .clarificationAnswer)
        startActionButtonMonitor(source: "clarification_answer")
    }

    func stopActionButtonRecordingIfNeeded(reason: String) async {
        AppTrace.point(
            "ActionButtonIntent.stopIfNeeded",
            fields: ["reason": reason, "status": viewModel.status.rawValue]
        )

        if viewModel.status == .connecting || viewModel.status == .listening {
            stopActionButtonMonitor()
            await viewModel.stopListening()
            await keepProcessingAliveForActionButtonSession(source: "action_button_cancelled")
        }
    }

    private func startActionButtonMonitor(source: String) {
        stopActionButtonMonitor()
        let monitorID = UUID()
        actionButtonMonitorID = monitorID
        actionButtonMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await keepRecordingAliveForActionButtonSession(source: source)
            await keepProcessingAliveForActionButtonSession(source: source)
            if actionButtonMonitorID == monitorID {
                actionButtonMonitorTask = nil
                actionButtonMonitorID = nil
            }
            AppTrace.point(
                "ActionButtonIntent.monitorEnded",
                fields: ["source": source, "status": viewModel.status.rawValue]
            )
        }
        AppTrace.point(
            "ActionButtonIntent.monitorStarted",
            fields: ["source": source, "status": viewModel.status.rawValue]
        )
    }

    private func stopActionButtonMonitor() {
        actionButtonMonitorTask?.cancel()
        actionButtonMonitorTask = nil
        actionButtonMonitorID = nil
    }

    private func keepRecordingAliveForActionButtonSession(source: String) async {
        let recordingDeadline = Date().addingTimeInterval(maxActionButtonRecordingDuration)

        while viewModel.status == .connecting || viewModel.status == .listening {
            if Date() >= recordingDeadline {
                AppTrace.point("ActionButtonIntent.autoStop", fields: ["source": source, "status": viewModel.status.rawValue])
                await viewModel.stopListening()
                break
            }

            if let stopRequestID = viewModel.liveActivityStopRequestID(),
               stopRequestID != handledLiveActivityStopRequestID {
                handledLiveActivityStopRequestID = stopRequestID
                AppTrace.point(
                    "ActionButtonIntent.liveActivityStop",
                    fields: ["source": source, "status": viewModel.status.rawValue, "request_id": stopRequestID]
                )
                await viewModel.stopListening()
                break
            }

            if viewModel.shouldStopActionButtonRecordingForSilence(
                minimumListeningDuration: minimumActionButtonListeningDuration,
                silenceDuration: actionButtonSilenceDuration
            ) {
                var fields = viewModel.actionButtonRecordingTimingFields()
                fields["source"] = source
                fields["status"] = viewModel.status.rawValue
                AppTrace.point(
                    "ActionButtonIntent.silenceAutoStop",
                    fields: fields
                )
                await viewModel.stopListening()
                break
            }

            guard !Task.isCancelled else {
                AppTrace.point(
                    "ActionButtonIntent.monitorCancelled",
                    fields: ["source": source, "status": viewModel.status.rawValue]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func keepProcessingAliveForActionButtonSession(source: String) async {
        let processingDeadline = Date().addingTimeInterval(maxActionButtonProcessingDuration)

        while viewModel.status == .thinking {
            if Date() >= processingDeadline || Task.isCancelled {
                AppTrace.point(
                    "ActionButtonIntent.processingKeepAliveEnded",
                    fields: [
                        "reason": Task.isCancelled ? "task_cancelled" : "deadline",
                        "source": source,
                        "status": viewModel.status.rawValue
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
