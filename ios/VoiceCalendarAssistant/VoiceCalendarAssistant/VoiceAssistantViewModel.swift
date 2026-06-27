import ActivityKit
import CoreGraphics
import Foundation

@MainActor
final class VoiceAssistantViewModel: ObservableObject {
    enum ListeningStartSource: String {
        case manual
        case actionButton
        case clarificationAnswer

        var requiresColdStartHardening: Bool {
            self == .actionButton || self == .clarificationAnswer
        }
    }

    enum Status: String {
        case ready = "Klar"
        case connecting = "Forbinder..."
        case listening = "Lytter..."
        case thinking = "Tænker..."
        case missingInformation = "Mangler oplysninger"
        case readyToSave = "Klar til at gemme"
        case saved = "Gemt i kalenderen"
        case error = "Fejl"
    }

    @Published var status: Status = .ready
    @Published var partialTranscript = ""
    @Published var finalTranscript = ""
    @Published var assistantResponse = ""
    @Published var errorMessage: String?
    @Published var recoveryPresentation: TidRecoveryPresentation?
    @Published var draft: CalendarEventDraft?
    @Published var savedEventIdentifier: String?
    @Published var isConfirmationPresented = false
    @Published var audioLevel: CGFloat = 0
    @Published var isSaving = false
    private(set) var listeningStartedAt: Date?
    private(set) var speechDetectedAt: Date?
    private(set) var lastSpeechDetectedAt: Date?

    private var realtimeClient: RealtimeClient
    private let usesInjectedRealtimeClient: Bool
    private let calendarService: CalendarService
    private let permissionsService: PermissionsService
    private let settings: SettingsStore
    private let liveActivityManager = LiveActivityManager()
    private var realtimeClientSignature: String
    private var eventsTask: Task<Void, Never>?
    private var liveActivityStartedAt: Date?
    private var lastReadyToSaveAlertPayload: String?
    private var lastSavedAlertKey: String?
    private var lastClarificationAlertKey: String?
    private var isAnsweringClarification = false
    private var automaticClarificationAttempts = 0
    private var stopToDraftStartedAt: Date?
    private var stopToDraftFields: [String: String] = [:]
    private var shouldResetRealtimeClientOnNextStart = false
    private var startListeningGeneration = 0
    private var coldStartWarmupTask: Task<Void, Never>?

    init(
        realtimeClient: RealtimeClient? = nil,
        calendarService: CalendarService? = nil,
        permissionsService: PermissionsService = PermissionsService(),
        settings: SettingsStore
    ) {
        if let realtimeClient {
            self.realtimeClient = realtimeClient
            usesInjectedRealtimeClient = true
        } else {
            self.realtimeClient = Self.makeRealtimeClient(settings: settings)
            usesInjectedRealtimeClient = false
        }
        self.calendarService = calendarService ?? CalendarService()
        self.permissionsService = permissionsService
        self.settings = settings
        realtimeClientSignature = Self.clientSignature(settings: settings)
        observeRealtimeEvents()
    }

    deinit {
        eventsTask?.cancel()
        coldStartWarmupTask?.cancel()
    }

    func startListening(source: ListeningStartSource = .manual) async {
        let traceID = AppTrace.makeID()
        startListeningGeneration += 1
        let generation = startListeningGeneration
        AppTrace.point(
            "VoiceAssistantViewModel.startListening.requested",
            fields: ["source": source.rawValue, "trace_id": traceID]
        )

        await AppTrace.measure("VoiceAssistantViewModel.startListening", fields: ["source": source.rawValue, "trace_id": traceID]) {
            finishStopToDraftTraceIfNeeded(result: "superseded_by_start", extra: ["trace_id": traceID])

            guard status != .connecting, status != .listening, status != .thinking else {
                AppTrace.point(
                    "VoiceAssistantViewModel.startListening.ignored",
                    fields: ["status": status.rawValue, "source": source.rawValue, "trace_id": traceID]
                )
                return
            }

            let answersClarification = status == .missingInformation
            let startsFreshConversation = status == .readyToSave || status == .saved
            let retriesAfterError = status == .error
            let clarificationContext = answersClarification ? clarificationConversationContext() : nil
            if answersClarification {
                AppTrace.point("VoiceAssistantViewModel.startClarificationAnswer", fields: ["trace_id": traceID])
                await resetRealtimeClientForClarificationAnswer(traceID: traceID)
            }
            if startsFreshConversation {
                await resetForFreshConversation(traceID: traceID)
            }
            if retriesAfterError || shouldResetRealtimeClientOnNextStart {
                await rebuildRealtimeClientForRecovery(
                    traceID: traceID,
                    reason: retriesAfterError ? "retry_after_error" : "flagged_recovery"
                )
            }

            errorMessage = nil
            recoveryPresentation = nil
            partialTranscript = ""
            finalTranscript = ""
            assistantResponse = ""
            audioLevel = 0
            listeningStartedAt = nil
            speechDetectedAt = nil
            lastSpeechDetectedAt = nil
            isSaving = false
            lastReadyToSaveAlertPayload = nil
            isAnsweringClarification = answersClarification
            automaticClarificationAttempts = 0
            if startsFreshConversation {
                draft = nil
                savedEventIdentifier = nil
                isConfirmationPresented = false
                liveActivityStartedAt = nil
                lastClarificationAlertKey = nil
            }
            status = .connecting
            AppTrace.point(
                "VoiceAssistantViewModel.startListening.phaseSet",
                fields: ["status": status.rawValue, "source": source.rawValue, "trace_id": traceID]
            )
            await syncLiveActivity()

            do {
                await AppTrace.measure("VoiceAssistantViewModel.refreshRealtimeClientIfNeeded", fields: ["trace_id": traceID]) {
                    await refreshRealtimeClientIfNeeded()
                }
                try ensureCurrentStartGeneration(generation)

                if let clarificationContext {
                    realtimeClient.setPendingConversationContext(clarificationContext)
                    AppTrace.point(
                        "VoiceAssistantViewModel.primedClarificationContext",
                        fields: ["characters": "\(clarificationContext.count)", "trace_id": traceID]
                    )
                }
                try await AppTrace.measure("PermissionsService.requestMicrophoneAccess", fields: ["trace_id": traceID]) {
                    try await permissionsService.requestMicrophoneAccess()
                }
                try ensureCurrentStartGeneration(generation)
                try await AppTrace.measure("RealtimeClient.startListening", fields: ["trace_id": traceID]) {
                    try await realtimeClient.startListening()
                }
                try ensureCurrentStartGeneration(generation)
                if source.requiresColdStartHardening {
                    scheduleColdStartWarmups(source: source, traceID: traceID, generation: generation)
                }
            } catch is StartListeningSupersededError {
                AppTrace.point(
                    "VoiceAssistantViewModel.startListening.superseded",
                    fields: ["source": source.rawValue, "trace_id": traceID]
                )
            } catch {
                guard generation == startListeningGeneration else {
                    AppTrace.point(
                        "VoiceAssistantViewModel.startListening.errorAfterSuperseded",
                        fields: [
                            "error": error.localizedDescription,
                            "source": source.rawValue,
                            "trace_id": traceID
                        ]
                    )
                    return
                }

                shouldResetRealtimeClientOnNextStart = shouldResetRealtimeClient(after: error)
                if shouldResetRealtimeClient(after: error) {
                    await resetRealtimeClientAfterStartFailure(traceID: traceID)
                }
                isAnsweringClarification = false
                status = .error
                applyError(error, context: .startListening)
                AppTrace.point(
                    "VoiceAssistantViewModel.startListening.error",
                    fields: errorTraceFields(error.localizedDescription, traceID: traceID)
                )
                preserveFailureBundle(
                    reason: "start_listening_error",
                    diagnosticError: error.localizedDescription,
                    shownError: errorMessage,
                    traceID: traceID
                )
                await syncLiveActivity()
            }
        }
    }

    func stopListening() async {
        let traceID = AppTrace.makeID()
        AppTrace.point(
            "VoiceAssistantViewModel.stopListening.requested",
            fields: ["status": status.rawValue, "trace_id": traceID]
        )

        await AppTrace.measure("VoiceAssistantViewModel.stopListening", fields: ["trace_id": traceID]) {
            if status == .connecting, listeningStartedAt == nil {
                await cancelConnectingStart(traceID: traceID, reason: "stop_before_recording_started")
                return
            }

            AppTrace.point(
                "VoiceAssistantViewModel.stopListening.transition",
                fields: [
                    "from": status.rawValue,
                    "clarification_answer": "\(isAnsweringClarification)",
                    "trace_id": traceID
                ]
            )
            audioLevel = 0
            status = .thinking
            AppTrace.point(
                "VoiceAssistantViewModel.stopListening.phaseSet",
                fields: ["status": status.rawValue, "trace_id": traceID]
            )
            beginStopToDraftTrace(traceID: traceID)
            listeningStartedAt = nil
            await AppTrace.measure("VoiceAssistantViewModel.syncLiveActivity.stopTransition", fields: ["trace_id": traceID]) {
                await syncLiveActivity()
            }

            do {
                try await AppTrace.measure("RealtimeClient.stopListening", fields: ["trace_id": traceID]) {
                    try await realtimeClient.stopListening()
                }
            } catch {
                shouldResetRealtimeClientOnNextStart = true
                finishStopToDraftTraceIfNeeded(
                    result: "stop_error",
                    extra: ["error": error.localizedDescription, "trace_id": traceID]
                )
                status = .error
                applyError(error, context: .stopListening)
                AppTrace.point(
                    "VoiceAssistantViewModel.stopListening.error",
                    fields: errorTraceFields(error.localizedDescription, traceID: traceID)
                )
                preserveFailureBundle(
                    reason: "stop_listening_error",
                    diagnosticError: error.localizedDescription,
                    shownError: errorMessage,
                    traceID: traceID
                )
                await rebuildRealtimeClientForRecovery(traceID: traceID, reason: "stop_error")
                await syncLiveActivity()
            }
        }
    }

    func saveConfirmed() async {
        guard let draft else { return }

        let traceID = AppTrace.makeID()

        await AppTrace.measure(
            "VoiceAssistantViewModel.saveConfirmed",
            fields: [
                "alarms_count": "\(draft.alarmsMinutesBefore.count)",
                "has_notes": "\(draft.notes?.isEmpty == false)",
                "trace_id": traceID
            ]
        ) {
            isSaving = true
            status = .thinking
            isConfirmationPresented = false
            await syncLiveActivity()

            do {
                savedEventIdentifier = try await AppTrace.measure("CalendarService.createEvent", fields: ["trace_id": traceID]) {
                    try await calendarService.createEvent(from: draft)
                }
                isSaving = false
                recoveryPresentation = nil
                errorMessage = nil
                status = .saved
                assistantResponse = "Gemt i kalenderen"
                await syncLiveActivity()
            } catch {
                isSaving = false
                status = .error
                applyError(error, context: .calendarSave)
                AppTrace.point(
                    "VoiceAssistantViewModel.saveConfirmed.error",
                    fields: errorTraceFields(error.localizedDescription, traceID: traceID)
                )
                preserveFailureBundle(
                    reason: "calendar_save_error",
                    diagnosticError: error.localizedDescription,
                    shownError: errorMessage,
                    traceID: traceID
                )
                await syncLiveActivity()
            }
        }
    }

    func editDraft() {
        isConfirmationPresented = false
        isSaving = false
        recoveryPresentation = nil
        errorMessage = nil
        status = .missingInformation
        assistantResponse = "Hvad vil du rette?"
        Task { await syncLiveActivity() }
    }

    func cancelDraft() {
        isConfirmationPresented = false
        isSaving = false
        draft = nil
        errorMessage = nil
        recoveryPresentation = nil
        status = .ready
        assistantResponse = ""
        Task { await syncLiveActivity() }
    }

    func loadCalendars() async {
        let traceID = AppTrace.makeID()

        do {
            let calendars = try await AppTrace.measure("CalendarService.availableCalendars", fields: ["trace_id": traceID]) {
                try await calendarService.availableCalendars()
            }
            settings.setAvailableCalendars(calendars)
        } catch {
            applyError(error, context: .loadCalendars)
            AppTrace.point(
                "VoiceAssistantViewModel.loadCalendars.error",
                fields: errorTraceFields(error.localizedDescription, traceID: traceID)
            )
        }
    }

    private func ensureCalendarsLoadedIfNeeded(traceID: String) async {
        guard settings.availableCalendars.isEmpty else { return }

        do {
            let calendars = try await AppTrace.measure("CalendarService.availableCalendars.preload", fields: ["trace_id": traceID]) {
                try await calendarService.availableCalendarsIfAuthorized()
            }

            guard let calendars else {
                AppTrace.point(
                    "VoiceAssistantViewModel.calendarPreload.skipped",
                    fields: ["reason": "calendar_permission_not_granted", "trace_id": traceID]
                )
                return
            }
            settings.setAvailableCalendars(calendars)
        } catch {
            AppTrace.point(
                "VoiceAssistantViewModel.calendarPreload.error",
                fields: ["error": error.localizedDescription, "trace_id": traceID]
            )
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "voicecalendar" else { return }

        switch url.host {
        case "start-listening":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "start-listening", "status": status.rawValue])
            Task { await VoiceCalendarAssistantSession.shared.handleActionButtonPress() }
        case "action-button":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "action-button", "status": status.rawValue])
            Task { await VoiceCalendarAssistantSession.shared.handleActionButtonPress() }
#if DEBUG
        case "debug-ready-to-save":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-ready-to-save", "status": status.rawValue])
            Task { await presentDebugReadyToSave() }
        case "debug-listening":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-listening", "status": status.rawValue])
            Task { await presentDebugListening() }
        case "debug-thinking":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-thinking", "status": status.rawValue])
            Task { await presentDebugThinking() }
        case "debug-needs-clarification":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-needs-clarification", "status": status.rawValue])
            Task { await presentDebugNeedsClarification() }
        case "debug-saved":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-saved", "status": status.rawValue])
            Task { await presentDebugSaved() }
        case "debug-error":
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": "debug-error", "status": status.rawValue])
            Task { await presentDebugError() }
#endif
        default:
            AppTrace.point("VoiceAssistantViewModel.deepLink", fields: ["host": url.host ?? "nil", "status": status.rawValue])
            break
        }
    }

#if DEBUG
    func presentDebugReadyToSave() async {
        draft = debugCalendarDraft()
        errorMessage = nil
        recoveryPresentation = nil
        partialTranscript = ""
        finalTranscript = "Kaffe med Jonas i morgen klokken 14"
        assistantResponse = ""
        isSaving = false
        liveActivityStartedAt = Date()
        status = .readyToSave
        await syncLiveActivity()
    }

    func presentDebugListening() async {
        draft = nil
        errorMessage = nil
        recoveryPresentation = nil
        partialTranscript = "Kaffe med Jonas"
        finalTranscript = ""
        assistantResponse = ""
        isSaving = false
        isAnsweringClarification = false
        liveActivityStartedAt = Date().addingTimeInterval(-12)
        listeningStartedAt = liveActivityStartedAt
        status = .listening
        await syncLiveActivity()
    }

    func presentDebugThinking() async {
        draft = nil
        errorMessage = nil
        recoveryPresentation = nil
        partialTranscript = ""
        finalTranscript = "Kaffe med Jonas i morgen klokken 14"
        assistantResponse = ""
        isSaving = false
        isAnsweringClarification = false
        liveActivityStartedAt = Date().addingTimeInterval(-12)
        status = .thinking
        await syncLiveActivity()
    }

    func presentDebugNeedsClarification() async {
        draft = nil
        errorMessage = nil
        recoveryPresentation = nil
        partialTranscript = ""
        finalTranscript = "Kaffe med Jonas"
        assistantResponse = "Hvilket tidspunkt skal jeg sætte det til?"
        isSaving = false
        isAnsweringClarification = false
        liveActivityStartedAt = Date().addingTimeInterval(-12)
        status = .missingInformation
        await syncLiveActivity()
    }

    func presentDebugSaved() async {
        let debugDraft = debugCalendarDraft()
        draft = debugDraft
        errorMessage = nil
        recoveryPresentation = nil
        partialTranscript = ""
        finalTranscript = "Kaffe med Jonas i morgen klokken 14"
        assistantResponse = ""
        isSaving = false
        isAnsweringClarification = false
        liveActivityStartedAt = Date().addingTimeInterval(-12)
        status = .saved

        let state = TidRecordingActivityAttributes.ContentState(
            phase: .saved,
            title: "Gemt i Kalender",
            subtitle: debugDraft.title,
            detail: liveActivityDetail(for: debugDraft),
            startedAt: liveActivityStartedAt ?? Date()
        )
        await liveActivityManager.update(state, startsActivity: true)
    }

    func presentDebugError() async {
        draft = nil
        partialTranscript = ""
        finalTranscript = "Debug fejl"
        assistantResponse = ""
        isSaving = false
        isAnsweringClarification = false
        liveActivityStartedAt = Date().addingTimeInterval(-8)
        let presentation = TidRecoveryPresentation.make(message: "Debug fejl til sporingspakke.", context: .debug)
        recoveryPresentation = presentation
        errorMessage = presentation.message
        status = .error
        AppTrace.point(
            "VoiceAssistantViewModel.debugError",
            fields: ["shown_error": errorMessage ?? "", "category": presentation.category]
        )
        preserveFailureBundle(
            reason: "debug_error",
            diagnosticError: "Debug failure bundle validation",
            shownError: errorMessage
        )
        await syncLiveActivity()
    }

    private func debugCalendarDraft() -> CalendarEventDraft {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let startDate = Calendar.current.date(
            bySettingHour: 14,
            minute: 0,
            second: 0,
            of: tomorrow
        ) ?? tomorrow
        let endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3600)

        return CalendarEventDraft(
            title: "Kaffe med Jonas",
            startDate: startDate,
            endDate: endDate,
            timeZoneIdentifier: TimeZone.current.identifier,
            alarmsMinutesBefore: [5],
            calendarIdentifier: settings.defaultCalendarIdentifier,
            confidence: 0.98,
            originalUtterance: "Kaffe med Jonas i morgen klokken 14"
        )
    }
#endif

    private func observeRealtimeEvents() {
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in realtimeClient.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: RealtimeClientEvent) {
        if event.shouldTrace {
            AppTrace.point("VoiceAssistantViewModel.handleEvent", fields: ["event": event.traceName])
        }

        switch event {
        case .connected:
            return
        case .disconnected:
            guard status != .connecting, status != .listening, status != .thinking, status != .error else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }

            if draft == nil {
                status = .ready
            } else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
        case .listeningStarted:
            guard status == .connecting else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
            status = .listening
            listeningStartedAt = Date()
            partialTranscript = ""
            audioLevel = 0.48
        case .inputAudioLevel(let level):
            guard status == .listening else {
                return
            }

            let normalizedLevel = min(1, max(0, level))
            audioLevel = CGFloat(normalizedLevel)

            if normalizedLevel >= Self.speechDetectionLevel {
                let now = Date()
                if speechDetectedAt == nil {
                    speechDetectedAt = now
                    AppTrace.point(
                        "VoiceAssistantViewModel.speechDetected",
                        fields: ["level": Self.traceLevel(normalizedLevel)]
                    )
                }
                lastSpeechDetectedAt = now
            }
            return
        case .partialTranscript(let text):
            guard status == .listening else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
            partialTranscript += text
            audioLevel = min(1, max(0.22, CGFloat(text.count) / 16))
            return
        case .finalTranscript(let text):
            let isLateTranscript = status == .missingInformation || status == .readyToSave
            guard status == .listening || status == .thinking || isLateTranscript else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
            finalTranscript = text
            partialTranscript = ""
            audioLevel = 0
            if isAnsweringClarification {
                AppTrace.point(
                    "VoiceAssistantViewModel.clarificationAnswerTranscript",
                    fields: ["characters": "\(text.count)"]
                )
            }
            if isLateTranscript {
                AppTrace.point(
                    "VoiceAssistantViewModel.lateFinalTranscriptStored",
                    fields: ["characters": "\(text.count)", "status": status.rawValue]
                )
            } else {
                status = .thinking
            }
        case .assistantText(let text):
            guard status != .readyToSave, status != .saved else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
            assistantResponse += text
        case .assistantAudioStarted:
            if status != .readyToSave, status != .saved {
                status = .thinking
            } else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
        case .assistantAudioEnded:
            if draft == nil {
                status = .ready
            } else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
        case .responseCompleted:
            if isSaving || status == .readyToSave || status == .saved {
                AppTrace.point(
                    "VoiceAssistantViewModel.responseCompletedIgnored",
                    fields: [
                        "reason": isSaving ? "saving" : "terminal_draft_state",
                        "status": status.rawValue
                    ]
                )
                return
            }

            if status == .thinking {
                let question = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                if question.isEmpty {
                    isAnsweringClarification = false
                    status = .ready
                    finishStopToDraftTraceIfNeeded(result: "no_output")
                } else if let automaticAnswer = automaticAnswerForNonBlockingClarification(question) {
                    assistantResponse = ""
                    AppTrace.point(
                        "VoiceAssistantViewModel.autoResolvedClarification",
                        fields: [
                            "question_chars": "\(question.count)",
                            "answer_chars": "\(automaticAnswer.count)",
                            "attempt": "\(automaticClarificationAttempts)"
                        ]
                    )
                    Task { await sendAutomaticClarificationAnswer(automaticAnswer) }
                    return
                } else {
                    isAnsweringClarification = false
                    status = .missingInformation
                    traceClarificationRequested(question)
                    finishStopToDraftTraceIfNeeded(
                        result: "clarification",
                        extra: ["question_chars": "\(question.count)"]
                    )
                }
            } else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
        case .calendarDraft(let newDraft):
            do {
                var validatedDraft = try AppTrace.measure(
                    "VoiceAssistantViewModel.calendarDraftValidated",
                    fields: ["trace_id": stopToDraftFields["trace_id"] ?? ""]
                ) {
                    try newDraft.validatedForCalendar()
                }
                switch routeCalendar(for: validatedDraft) {
                case .resolved(let routedDraft):
                    validatedDraft = routedDraft
                case .needsClarification(let routedDraft, let question, let reason):
                    draft = routedDraft
                    assistantResponse = question
                    isSaving = false
                    isConfirmationPresented = false
                    isAnsweringClarification = false
                    lastClarificationAlertKey = nil
                    status = .missingInformation
                    traceClarificationRequested(question)
                    finishStopToDraftTraceIfNeeded(
                        result: "calendar_routing_clarification",
                        extra: draftTraceFields(routedDraft).merging(["routing_reason": reason]) { _, new in new }
                    )
                    return
                }
                draft = validatedDraft
                assistantResponse = ""
                isSaving = false
                isConfirmationPresented = false
                isAnsweringClarification = false
                lastClarificationAlertKey = nil

                let reviewReason = draftReviewReason(validatedDraft)
                let shouldSaveAutomatically = reviewReason == nil
                AppTrace.point(
                    "VoiceAssistantViewModel.calendarDraftDecision",
                    fields: [
                        "action": shouldSaveAutomatically ? "auto_save" : "confirm",
                        "confidence": validatedDraft.confidence.map(Self.traceConfidence) ?? "missing",
                        "review_reason": reviewReason ?? "none"
                    ]
                )

                if shouldSaveAutomatically {
                    finishStopToDraftTraceIfNeeded(
                        result: "draft_auto_save",
                        extra: draftTraceFields(validatedDraft)
                    )
                    Task { await saveConfirmed() }
                    return
                }

                status = .readyToSave
                finishStopToDraftTraceIfNeeded(
                    result: "draft_ready_to_save",
                    extra: draftTraceFields(validatedDraft)
                )
            } catch {
                finishStopToDraftTraceIfNeeded(
                    result: "draft_error",
                    extra: ["error": error.localizedDescription]
                )
                status = .error
                applyError(error, context: .draftValidation)
                preserveFailureBundle(
                    reason: "draft_validation_error",
                    diagnosticError: error.localizedDescription,
                    shownError: errorMessage
                )
            }
        case .clarificationQuestion(let question):
            if let automaticAnswer = automaticAnswerForNonBlockingClarification(question) {
                assistantResponse = ""
                AppTrace.point(
                    "VoiceAssistantViewModel.autoResolvedClarification",
                    fields: [
                        "question_chars": "\(question.count)",
                        "answer_chars": "\(automaticAnswer.count)",
                        "attempt": "\(automaticClarificationAttempts)"
                    ]
                )
                Task { await sendAutomaticClarificationAnswer(automaticAnswer) }
                return
            }

            assistantResponse = question
            isAnsweringClarification = false
            status = .missingInformation
            traceClarificationRequested(question)
            finishStopToDraftTraceIfNeeded(
                result: "clarification",
                extra: ["question_chars": "\(question.count)"]
            )
        case .error(let message):
            guard status != .readyToSave, status != .saved else {
                AppTrace.point(
                    "VoiceAssistantViewModel.eventIgnored",
                    fields: ["event": event.traceName, "status": status.rawValue]
                )
                return
            }
            applyError(message: message, context: .realtime)
            isAnsweringClarification = false
            shouldResetRealtimeClientOnNextStart = true
            status = .error
            finishStopToDraftTraceIfNeeded(result: "realtime_error", extra: errorTraceFields(message))
            preserveFailureBundle(
                reason: "realtime_event_error",
                diagnosticError: message,
                shownError: errorMessage
            )
            Task { await rebuildRealtimeClientForRecovery(traceID: AppTrace.makeID(), reason: "realtime_event_error") }
        }

        Task { await syncLiveActivity() }
    }

    func shouldStopActionButtonRecordingForSilence(
        now: Date = Date(),
        minimumListeningDuration: TimeInterval,
        silenceDuration: TimeInterval
    ) -> Bool {
        guard status == .listening,
              let listeningStartedAt,
              let lastSpeechDetectedAt,
              speechDetectedAt != nil else {
            return false
        }

        guard now.timeIntervalSince(listeningStartedAt) >= minimumListeningDuration else {
            return false
        }

        return now.timeIntervalSince(lastSpeechDetectedAt) >= silenceDuration
    }

    func actionButtonRecordingTimingFields(now: Date = Date()) -> [String: String] {
        var fields: [String: String] = [:]

        if let listeningStartedAt {
            fields["listening_age_ms"] = Self.traceMilliseconds(now.timeIntervalSince(listeningStartedAt))
        }

        if let speechDetectedAt {
            fields["first_speech_age_ms"] = Self.traceMilliseconds(now.timeIntervalSince(speechDetectedAt))
        }

        if let lastSpeechDetectedAt {
            fields["last_speech_age_ms"] = Self.traceMilliseconds(now.timeIntervalSince(lastSpeechDetectedAt))
        }

        return fields
    }

    func liveActivityStopRequestID() -> String? {
        liveActivityManager.stopRequestID()
    }

    private enum CalendarRoutingResult {
        case resolved(CalendarEventDraft)
        case needsClarification(CalendarEventDraft, question: String, reason: String)
    }

    private func routeCalendar(for draft: CalendarEventDraft) -> CalendarRoutingResult {
        var routedDraft = draft
        let explicitCalendarName = Self.cleanedCalendarQuery(draft.calendarName)

        if let explicitCalendarName {
            if let calendar = matchingCalendar(named: explicitCalendarName) {
                routedDraft.calendarIdentifier = calendar.identifier
                AppTrace.point(
                    "VoiceAssistantViewModel.calendarRouting",
                    fields: [
                        "strategy": "explicit_name",
                        "query": explicitCalendarName,
                        "calendar": calendar.title
                    ]
                )
                return .resolved(routedDraft)
            }

            if settings.availableCalendars.count > 1 {
                routedDraft.calendarIdentifier = settings.defaultCalendarIdentifier
                let question = "Jeg kan ikke finde kalenderen \(explicitCalendarName). Hvilken kalender skal jeg bruge?"
                AppTrace.point(
                    "VoiceAssistantViewModel.calendarRouting",
                    fields: [
                        "strategy": "explicit_name_unmatched_clarification",
                        "query": explicitCalendarName,
                        "available_count": "\(settings.availableCalendars.count)"
                    ]
                )
                return .needsClarification(routedDraft, question: question, reason: "calendar_name_unmatched")
            }

            routedDraft.calendarIdentifier = settings.defaultCalendarIdentifier
            AppTrace.point(
                "VoiceAssistantViewModel.calendarRouting",
                fields: [
                    "strategy": "explicit_name_unmatched_default",
                    "query": explicitCalendarName,
                    "available_count": "\(settings.availableCalendars.count)"
                ]
            )
            return .resolved(routedDraft)
        }

        if let category = draft.calendarCategory,
           let identifier = settings.calendarIdentifier(for: category) {
            routedDraft.calendarIdentifier = identifier
            AppTrace.point(
                "VoiceAssistantViewModel.calendarRouting",
                fields: [
                    "strategy": "category_mapping",
                    "category": category.rawValue,
                    "calendar": settings.routingCalendarTitle(for: category)
                ]
            )
            return .resolved(routedDraft)
        }

        if routedDraft.calendarIdentifier == nil {
            routedDraft.calendarIdentifier = settings.defaultCalendarIdentifier
        }

        AppTrace.point(
            "VoiceAssistantViewModel.calendarRouting",
            fields: [
                "strategy": draft.calendarCategory == nil ? "default" : "category_default",
                "category": draft.calendarCategory?.rawValue ?? "none",
                "calendar": settings.defaultCalendarTitle
            ]
        )
        return .resolved(routedDraft)
    }

    private func matchingCalendar(named query: String) -> CalendarInfo? {
        let normalizedQuery = Self.normalizedCalendarName(query)
        guard !normalizedQuery.isEmpty else { return nil }

        if let exact = settings.availableCalendars.first(where: { Self.normalizedCalendarName($0.title) == normalizedQuery }) {
            return exact
        }

        return settings.availableCalendars.first { calendar in
            let title = Self.normalizedCalendarName(calendar.title)
            guard !title.isEmpty else { return false }
            return title.contains(normalizedQuery) || normalizedQuery.contains(title)
        }
    }

    private static func cleanedCalendarQuery(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedCalendarName(_ value: String) -> String {
        var normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da_DK"))
            .lowercased()

        for removable in ["kalenderen", "kalender"] {
            normalized = normalized.replacingOccurrences(of: removable, with: " ")
        }

        for removable in ["calendar", "min", "mit", "pa", "i", "den", "det"] {
            normalized = normalized.replacingOccurrences(
                of: #"\b\#(removable)\b"#,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized
            .replacingOccurrences(of: "arbejds", with: "arbejde")
            .replacingOccurrences(of: "job", with: "arbejde")
            .replacingOccurrences(of: "work", with: "arbejde")
            .replacingOccurrences(of: "private", with: "privat")
            .replacingOccurrences(of: "personal", with: "privat")
            .replacingOccurrences(of: "familie", with: "familie")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        return normalized
    }

    private func draftReviewReason(_ draft: CalendarEventDraft) -> String? {
        guard let confidence = draft.confidence else {
            return "missing_confidence"
        }

        guard confidence >= CalendarEventDraft.automaticSaveConfidenceThreshold else {
            return "low_confidence"
        }

        if draft.recurrenceRule != nil {
            return "recurrence"
        }

        if isDateRiskyForAutoSave(draft) {
            return "date_risk"
        }

        return nil
    }

    private func isDateRiskyForAutoSave(_ draft: CalendarEventDraft) -> Bool {
        let utterance = Self.normalizedDanish(draft.originalUtterance ?? "")
        guard !utterance.isEmpty else { return false }

        let riskyPatterns = [
            "forste",
            "sidste",
            "naeste maned",
            "naste maned",
            "naeste aar",
            "naste aar",
            "om to uger",
            "om 2 uger",
            "om tre uger",
            "om 3 uger",
            "anden tirsdag",
            "anden mandag",
            "anden onsdag",
            "anden torsdag",
            "anden fredag",
            "anden lordag",
            "anden sondag"
        ]

        return riskyPatterns.contains { utterance.contains($0) }
    }

    private func syncLiveActivity() async {
        let startedAt = liveActivityStartedAt ?? Date()

        switch status {
        case .ready:
            lastClarificationAlertKey = nil
            lastSavedAlertKey = nil
            let state = TidRecordingActivityAttributes.ContentState(
                phase: .idle,
                title: "Tid",
                subtitle: "Klar til at lytte",
                detail: nil,
                startedAt: startedAt
            )
            await liveActivityManager.end(state, after: 1)
            liveActivityStartedAt = nil

        case .connecting:
            if liveActivityStartedAt == nil {
                liveActivityStartedAt = Date()
            }

            let state = TidRecordingActivityAttributes.ContentState(
                phase: .connecting,
                title: "Starter Tid",
                subtitle: "Gør mikrofonen klar",
                detail: nil,
                startedAt: liveActivityStartedAt ?? Date()
            )
            await liveActivityManager.update(state, startsActivity: true)

        case .listening:
            if liveActivityStartedAt == nil {
                liveActivityStartedAt = Date()
            }

            let state = TidRecordingActivityAttributes.ContentState(
                phase: .listening,
                title: isAnsweringClarification ? "Tid lytter til svaret" : "Tid lytter...",
                subtitle: isAnsweringClarification ? "Svar nu..." : "Tal nu...",
                detail: isAnsweringClarification ? "Tryk Stop når du er færdig" : "Hold Dynamic Island nede og tryk Stop",
                startedAt: liveActivityStartedAt ?? Date()
            )
            await liveActivityManager.update(state, startsActivity: true)

        case .thinking:
            let transcript = nonEmpty(finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
            let state = TidRecordingActivityAttributes.ContentState(
                phase: isSaving ? .readyToConfirm : .thinking,
                title: isSaving ? "Gemmer i Kalender" : (isAnsweringClarification ? "Forstår svaret" : "Forstår aftalen"),
                subtitle: transcript ?? (isAnsweringClarification ? "Behandler dit svar" : "Behandler din kalenderaftale"),
                detail: transcript == nil
                    ? (isAnsweringClarification ? "Kombinerer med aftalen" : "Finder dato, tid og påmindelser")
                    : (isAnsweringClarification ? "Kombinerer med aftalen" : "Gør kalenderforslaget klar"),
                startedAt: startedAt
            )
            await liveActivityManager.update(state)

        case .missingInformation:
            lastSavedAlertKey = nil
            let question = nonEmpty(assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "Mangler oplysninger"
            let state = TidRecordingActivityAttributes.ContentState(
                phase: .needsClarification,
                title: "Tid mangler svar",
                subtitle: question,
                detail: clarificationLiveActivitySummary,
                startedAt: startedAt
            )
            await liveActivityManager.update(
                state,
                startsActivity: true,
                alertConfiguration: clarificationAlertConfiguration(for: question, detail: state.detail)
            )

        case .readyToSave:
            guard let draft else { return }
            lastSavedAlertKey = nil
            lastClarificationAlertKey = nil
            let payload = LiveActivityCalendarPayload.encode(draft)
            let state = TidRecordingActivityAttributes.ContentState(
                phase: .readyToConfirm,
                title: "Klar til at gemme",
                subtitle: draft.title,
                detail: liveActivityDetail(for: draft),
                startedAt: startedAt,
                confirmationPayload: payload
            )
            await liveActivityManager.update(
                state,
                startsActivity: true,
                alertConfiguration: readyToSaveAlertConfiguration(for: payload)
            )

        case .saved:
            guard let draft else { return }
            lastReadyToSaveAlertPayload = nil
            lastClarificationAlertKey = nil
            let savedKey = [
                draft.title,
                DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier)
            ].joined(separator: "\u{1F}")
            let state = TidRecordingActivityAttributes.ContentState(
                phase: .saved,
                title: "Gemt i Kalender",
                subtitle: draft.title,
                detail: liveActivityDetail(for: draft),
                startedAt: startedAt
            )
            await liveActivityManager.update(
                state,
                startsActivity: true,
                alertConfiguration: savedAlertConfiguration(for: savedKey, draft: draft)
            )

        case .error:
            lastReadyToSaveAlertPayload = nil
            lastSavedAlertKey = nil
            lastClarificationAlertKey = nil
            let presentation = recoveryPresentation ??
                TidRecoveryPresentation.make(message: errorMessage ?? "Der opstod en fejl.", context: .realtime)
            let state = TidRecordingActivityAttributes.ContentState(
                phase: .error,
                title: presentation.shortTitle,
                subtitle: presentation.shortMessage,
                detail: presentation.recovery,
                startedAt: startedAt
            )
            await liveActivityManager.update(state, startsActivity: true)
        }
    }

    private func readyToSaveAlertConfiguration(for payload: String?) -> AlertConfiguration? {
        guard let payload, lastReadyToSaveAlertPayload != payload else { return nil }

        lastReadyToSaveAlertPayload = payload
        return AlertConfiguration(
            title: "Klar til at gemme",
            body: "Tryk på Tid for at gemme i Kalender",
            sound: .default
        )
    }

    private func savedAlertConfiguration(for key: String, draft: CalendarEventDraft) -> AlertConfiguration? {
        guard lastSavedAlertKey != key else { return nil }

        lastSavedAlertKey = key
        return AlertConfiguration(
            title: "Gemt i Kalender",
            body: "\(draft.title) er gemt",
            sound: .default
        )
    }

    private func clarificationAlertConfiguration(for question: String, detail: String?) -> AlertConfiguration? {
        let key = [question, detail ?? ""].joined(separator: "\u{1F}")
        guard lastClarificationAlertKey != key else { return nil }

        lastClarificationAlertKey = key
        return AlertConfiguration(
            title: "Tid mangler svar",
            body: "Tryk Svar for at give den manglende oplysning",
            sound: .default
        )
    }

    private var clarificationLiveActivitySummary: String? {
        if let draft {
            return liveActivityDetail(for: draft)
        }

        return nonEmpty(finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func liveActivityDetail(for draft: CalendarEventDraft) -> String {
        [
            DateFormatting.danishShortDate(draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier),
            DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier),
            DateFormatting.recurrenceLabel(for: draft),
            draft.location,
            DateFormatting.danishAlarmSummary(draft.alarmsMinutesBefore)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private func refreshRealtimeClientIfNeeded() async {
        guard !usesInjectedRealtimeClient else { return }

        let currentSignature = Self.clientSignature(settings: settings)
        guard currentSignature != realtimeClientSignature else { return }

        eventsTask?.cancel()
        await realtimeClient.disconnect()
        realtimeClient = Self.makeRealtimeClient(settings: settings)
        realtimeClientSignature = currentSignature
        observeRealtimeEvents()
    }

    private func resetForFreshConversation(traceID: String) async {
        AppTrace.point(
            "VoiceAssistantViewModel.resetForFreshConversation",
            fields: ["status": status.rawValue, "trace_id": traceID]
        )

        await rebuildRealtimeClientForRecovery(traceID: traceID, reason: "fresh_conversation")
    }

    private func resetRealtimeClientForClarificationAnswer(traceID: String) async {
        AppTrace.point(
            "VoiceAssistantViewModel.resetRealtimeClientForClarificationAnswer",
            fields: ["strategy": "keep_realtime_connection", "trace_id": traceID]
        )
    }

    private func scheduleColdStartWarmups(
        source: ListeningStartSource,
        traceID: String,
        generation: Int
    ) {
        coldStartWarmupTask?.cancel()
        coldStartWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runColdStartWarmups(source: source, traceID: traceID, generation: generation)
        }
    }

    private func runColdStartWarmups(
        source: ListeningStartSource,
        traceID: String,
        generation: Int
    ) async {
        await AppTrace.measure(
            "VoiceAssistantViewModel.coldStartWarmups",
            fields: ["source": source.rawValue, "trace_id": traceID]
        ) {
            guard generation == startListeningGeneration, !Task.isCancelled else {
                AppTrace.point(
                    "VoiceAssistantViewModel.coldStartWarmups.skipped",
                    fields: ["reason": "superseded", "source": source.rawValue, "trace_id": traceID]
                )
                return
            }

            await ensureCalendarsLoadedIfNeeded(traceID: traceID)

            guard generation == startListeningGeneration, !Task.isCancelled else { return }
            do {
                try await AppTrace.measure("BackendPreflightService.warmBackend", fields: ["source": source.rawValue, "trace_id": traceID]) {
                    try await BackendPreflightService.warmBackend(backendURL: settings.backendURL, traceID: traceID)
                }
            } catch {
                AppTrace.point(
                    "VoiceAssistantViewModel.coldStartWarmups.backend.error",
                    fields: ["error": error.localizedDescription, "source": source.rawValue, "trace_id": traceID]
                )
            }

            guard generation == startListeningGeneration,
                  !Task.isCancelled,
                  status == .connecting || status == .listening else {
                return
            }

            do {
                try await AppTrace.measure("RealtimeClient.connect.coldStartWarmup", fields: ["source": source.rawValue, "trace_id": traceID]) {
                    try await realtimeClient.connect()
                }
            } catch {
                AppTrace.point(
                    "VoiceAssistantViewModel.coldStartWarmups.realtime.error",
                    fields: ["error": error.localizedDescription, "source": source.rawValue, "trace_id": traceID]
                )
            }
        }
    }

    private func clarificationConversationContext() -> String? {
        let previousTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSummary = draft.map(liveActivityDetail(for:))

        guard !previousTranscript.isEmpty || !question.isEmpty || draftSummary != nil else {
            return nil
        }

        var parts = [
            "Kontekst til næste lydsvar: Brugeren er ved at oprette en kalenderaftale.",
            "Vent på næste lydsvar, og kombiner svaret med denne kontekst. Opret kalenderkladden, hvis dato og starttidspunkt er kendt."
        ]

        if !previousTranscript.isEmpty {
            parts.append("Første brugerudsagn: \(previousTranscript)")
        }

        if let draftSummary {
            parts.append("Foreløbig aftale: \(draftSummary)")
        }

        if !question.isEmpty {
            parts.append("Opklarende spørgsmål: \(question)")
        }

        return parts.joined(separator: "\n")
    }

    private func automaticAnswerForNonBlockingClarification(_ question: String) -> String? {
        guard automaticClarificationAttempts < 1 else {
            return nil
        }

        let normalizedQuestion = Self.normalizedDanish(question)
        let userUtterance = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !userUtterance.isEmpty else {
            return nil
        }

        guard !Self.isRequiredClarificationQuestion(normalizedQuestion) else {
            return nil
        }

        let shouldUseDefault = Self.isOptionalFieldQuestion(normalizedQuestion)
        let shouldTrustRelativeDate = Self.isDateConfirmationQuestion(normalizedQuestion)

        guard shouldUseDefault || shouldTrustRelativeDate else {
            return nil
        }

        automaticClarificationAttempts += 1

        return [
            "Svar ikke med tekst til brugeren.",
            "Brug produktstandarderne og kald stage_calendar_event nu, hvis dato og starttid er kendt.",
            "Spørg ikke om valgfrie felter.",
            "Hvis brugeren ikke udtrykkeligt bad om påmindelse, brug alarmsMinutesBefore: [].",
            "Hvis varighed eller sluttid mangler, brug 60 minutter.",
            "Hvis titel mangler, brug standardtitel efter reglerne.",
            "Hvis sted, deltagere eller gentagelse ikke blev nævnt, skal de udelades.",
            "Relative datoer skal beregnes direkte i brugerens tidszone og ikke bekræftes.",
            "Brugerens oprindelige udsagn: \(userUtterance)"
        ].joined(separator: "\n")
    }

    private func sendAutomaticClarificationAnswer(_ text: String) async {
        do {
            status = .thinking
            try await realtimeClient.sendUserText(text)
        } catch {
            AppTrace.point(
                "VoiceAssistantViewModel.autoResolvedClarification.error",
                fields: ["error": error.localizedDescription]
            )
            status = .error
            applyError(error, context: .autoClarification)
            finishStopToDraftTraceIfNeeded(result: "auto_clarification_error", extra: ["error": error.localizedDescription])
            preserveFailureBundle(
                reason: "auto_clarification_error",
                diagnosticError: error.localizedDescription,
                shownError: errorMessage
            )
            await syncLiveActivity()
        }
    }

    private func ensureCurrentStartGeneration(_ generation: Int) throws {
        guard generation == startListeningGeneration else {
            throw StartListeningSupersededError()
        }
    }

    private func cancelConnectingStart(traceID: String, reason: String) async {
        startListeningGeneration += 1
        coldStartWarmupTask?.cancel()
        coldStartWarmupTask = nil
        isAnsweringClarification = false
        listeningStartedAt = nil
        speechDetectedAt = nil
        lastSpeechDetectedAt = nil
        audioLevel = 0

        AppTrace.point(
            "VoiceAssistantViewModel.cancelConnectingStart",
            fields: ["reason": reason, "trace_id": traceID]
        )

        await rebuildRealtimeClientForRecovery(traceID: traceID, reason: reason)
        status = .ready
        await syncLiveActivity()
    }

    private func applyError(_ error: Error, context: TidRecoveryContext) {
        let presentation = TidRecoveryPresentation.make(for: error, context: context)
        recoveryPresentation = presentation
        errorMessage = presentation.message
    }

    private func applyError(message: String, context: TidRecoveryContext) {
        let presentation = TidRecoveryPresentation.make(message: message, context: context)
        recoveryPresentation = presentation
        errorMessage = presentation.message
    }

    private func errorTraceFields(_ diagnosticError: String, traceID: String? = nil) -> [String: String] {
        var fields = [
            "error": diagnosticError,
            "shown_error": errorMessage ?? "",
            "recovery_category": recoveryPresentation?.category ?? "unknown"
        ]
        if let traceID {
            fields["trace_id"] = traceID
        }
        return fields
    }

    private func shouldResetRealtimeClient(after error: Error) -> Bool {
        if error is PermissionError {
            return false
        }

        return true
    }

    private func traceClarificationRequested(_ question: String) {
        AppTrace.point(
            "VoiceAssistantViewModel.clarificationRequested",
            fields: [
                "question_chars": "\(question.count)",
                "has_transcript": "\(finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)"
            ]
        )
    }

    private func beginStopToDraftTrace(traceID: String) {
        finishStopToDraftTraceIfNeeded(result: "restarted", extra: ["trace_id": traceID])
        stopToDraftFields = [
            "clarification_answer": "\(isAnsweringClarification)",
            "trace_id": traceID
        ]
        stopToDraftStartedAt = AppTrace.beginSpan(
            "VoiceAssistantViewModel.stopToDraft",
            fields: stopToDraftFields
        )
    }

    private func finishStopToDraftTraceIfNeeded(result: String, extra: [String: String] = [:]) {
        guard stopToDraftStartedAt != nil else { return }

        var fields = stopToDraftFields
        fields["result"] = result
        extra.forEach { fields[$0.key] = $0.value }
        AppTrace.endSpan(
            "VoiceAssistantViewModel.stopToDraft",
            startedAt: stopToDraftStartedAt,
            fields: fields
        )
        stopToDraftStartedAt = nil
        stopToDraftFields = [:]
    }

    private func draftTraceFields(_ draft: CalendarEventDraft) -> [String: String] {
        [
            "alarms_count": "\(draft.alarmsMinutesBefore.count)",
            "confidence": draft.confidence.map(Self.traceConfidence) ?? "missing",
            "title_chars": "\(draft.title.count)"
        ]
    }

    private func preserveFailureBundle(
        reason: String,
        diagnosticError: String,
        shownError: String?,
        traceID: String? = nil,
        extra: [String: String] = [:]
    ) {
        var fields = extra
        fields["status"] = status.rawValue
        fields["diagnostic_error"] = diagnosticError
        fields["shown_error"] = shownError ?? ""
        fields["recovery_category"] = recoveryPresentation?.category ?? "unknown"
        fields["recovery_title"] = recoveryPresentation?.title ?? ""
        fields["trace_id"] = traceID ?? ""
        fields["is_saving"] = "\(isSaving)"
        fields["is_answering_clarification"] = "\(isAnsweringClarification)"
        fields["backend_url"] = settings.backendURLString
        fields["model"] = settings.modelName
        fields["voice"] = settings.voiceName
        fields["final_transcript_chars"] = "\(finalTranscript.count)"
        fields["partial_transcript_chars"] = "\(partialTranscript.count)"
        fields["assistant_response_chars"] = "\(assistantResponse.count)"
        fields["has_draft"] = "\(draft != nil)"

        if let draft {
            fields["draft_title"] = draft.title
            fields["draft_start"] = ISO8601DateFormatter.tidInternetDateTimeWithoutFractions.string(from: draft.startDate)
            fields["draft_confidence"] = draft.confidence.map(Self.traceConfidence) ?? "missing"
            fields["draft_has_recurrence"] = "\(draft.recurrenceRule != nil)"
            fields["draft_alarms_count"] = "\(draft.alarmsMinutesBefore.count)"
        }

        AppTrace.preserveFailureBundle(reason: reason, fields: fields)
    }

    private func resetRealtimeClientAfterStartFailure(traceID: String) async {
        AppTrace.point(
            "VoiceAssistantViewModel.resetRealtimeClientAfterStartFailure",
            fields: ["injected": "\(usesInjectedRealtimeClient)", "trace_id": traceID]
        )

        await rebuildRealtimeClientForRecovery(traceID: traceID, reason: "start_failure")
    }

    private func rebuildRealtimeClientForRecovery(traceID: String, reason: String) async {
        AppTrace.point(
            "VoiceAssistantViewModel.rebuildRealtimeClientForRecovery",
            fields: [
                "injected": "\(usesInjectedRealtimeClient)",
                "reason": reason,
                "trace_id": traceID
            ]
        )

        coldStartWarmupTask?.cancel()
        coldStartWarmupTask = nil
        eventsTask?.cancel()
        await realtimeClient.disconnect()

        guard !usesInjectedRealtimeClient else {
            observeRealtimeEvents()
            shouldResetRealtimeClientOnNextStart = false
            return
        }

        realtimeClient = Self.makeRealtimeClient(settings: settings)
        realtimeClientSignature = Self.clientSignature(settings: settings)
        observeRealtimeEvents()
        shouldResetRealtimeClientOnNextStart = false
    }

    private static func makeRealtimeClient(settings: SettingsStore) -> RealtimeClient {
        return (try? RealtimeWebRTCClient(settings: settings)) ?? MockRealtimeClient()
    }

    private static func clientSignature(settings: SettingsStore) -> String {
        let token = settings.backendAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            settings.backendURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            token,
            settings.modelName,
            settings.voiceName,
            settings.safetyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1F}")
    }

    private static let speechDetectionLevel = 0.025

    private static func traceLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }

    private static func traceConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", confidence)
    }

    private static func traceMilliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.0f", seconds * 1000)
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

    private static func isRequiredClarificationQuestion(_ normalizedQuestion: String) -> Bool {
        let requiredPatterns = [
            "hvad tid",
            "hvilket tidspunkt",
            "hvilken tid",
            "hvornar",
            "hvilken dato",
            "hvilken dag",
            "hvad dato",
            "dato mangler",
            "tidspunkt mangler",
            "starttidspunkt mangler"
        ]

        return requiredPatterns.contains { normalizedQuestion.contains($0) }
    }

    private static func isOptionalFieldQuestion(_ normalizedQuestion: String) -> Bool {
        let optionalPatterns = [
            "pamind",
            "paamind",
            "reminder",
            "alarm",
            "titel",
            "kalde",
            "hedde",
            "hvad skal den hedde",
            "varighed",
            "sluttid",
            "slutte",
            "hvor lang",
            "sted",
            "hvor er",
            "hvor skal",
            "lokation",
            "adresse",
            "deltager",
            "deltagere",
            "hvem",
            "person",
            "personer",
            "med hvem",
            "gentag",
            "gentage",
            "gentagelse",
            "tilbagevend",
            "hver uge",
            "hver maned",
            "hver maaned",
            "hvilken kalender",
            "standardkalender"
        ]

        return optionalPatterns.contains { normalizedQuestion.contains($0) }
    }

    private static func isDateConfirmationQuestion(_ normalizedQuestion: String) -> Bool {
        let confirmationPatterns = [
            "mener du",
            "mente du",
            "skal jeg bruge",
            "er det korrekt",
            "er det rigtigt",
            "vil du have",
            "bekraeft",
            "bekraefte",
            "sikker"
        ]

        let datePatterns = [
            "dato",
            "dagen",
            "mandag",
            "tirsdag",
            "onsdag",
            "torsdag",
            "fredag",
            "lordag",
            "sondag",
            "i morgen",
            "imorgen",
            "om to uger",
            "naeste uge",
            "naste uge",
            "august",
            "september",
            "oktober",
            "november",
            "december",
            "januar",
            "februar",
            "marts",
            "april",
            "maj",
            "juni",
            "juli"
        ]

        return confirmationPatterns.contains { normalizedQuestion.contains($0) } &&
            datePatterns.contains { normalizedQuestion.contains($0) }
    }
}

private extension RealtimeClientEvent {
    var shouldTrace: Bool {
        switch self {
        case .inputAudioLevel, .partialTranscript, .assistantText:
            return false
        default:
            return true
        }
    }

    var traceName: String {
        switch self {
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .listeningStarted:
            return "listeningStarted"
        case .inputAudioLevel:
            return "inputAudioLevel"
        case .partialTranscript:
            return "partialTranscript"
        case .finalTranscript:
            return "finalTranscript"
        case .assistantText:
            return "assistantText"
        case .assistantAudioStarted:
            return "assistantAudioStarted"
        case .assistantAudioEnded:
            return "assistantAudioEnded"
        case .responseCompleted:
            return "responseCompleted"
        case .calendarDraft:
            return "calendarDraft"
        case .clarificationQuestion:
            return "clarificationQuestion"
        case .error:
            return "error"
        }
    }
}

private struct StartListeningSupersededError: Error {}

private actor BackendPreflightService {
    private static let shared = BackendPreflightService()
    private static let maxAttempts = 3
    private static let timeoutSeconds: TimeInterval = 1.6
    private static let retryDelayNanoseconds: UInt64 = 300_000_000
    private static let successfulWarmupTTL: TimeInterval = 45
    private var successfulWarmups: [String: Date] = [:]
    private var inFlightWarmups: [String: Task<Void, Error>] = [:]

    static func warmBackend(backendURL: URL?, traceID: String) async throws {
        try await shared.warmBackend(backendURL: backendURL, traceID: traceID)
    }

    private func warmBackend(backendURL: URL?, traceID: String) async throws {
        guard let backendURL else {
            throw RealtimeClientError.backendURLMissing
        }

        let cacheKey = backendURL.absoluteString
        if let lastSuccess = successfulWarmups[cacheKey],
           Date().timeIntervalSince(lastSuccess) < Self.successfulWarmupTTL {
            AppTrace.point(
                "BackendPreflightService.warmBackend.cacheHit",
                fields: ["backend": backendURL.host ?? "unknown", "trace_id": traceID]
            )
            return
        }

        if let inFlightWarmup = inFlightWarmups[cacheKey] {
            AppTrace.point(
                "BackendPreflightService.warmBackend.coalesced",
                fields: ["backend": backendURL.host ?? "unknown", "trace_id": traceID]
            )
            try await inFlightWarmup.value
            return
        }

        let task = Task<Void, Error> {
            try await Self.performHealthCheck(backendURL: backendURL, traceID: traceID)
        }
        inFlightWarmups[cacheKey] = task

        do {
            try await task.value
            successfulWarmups[cacheKey] = Date()
            inFlightWarmups[cacheKey] = nil
        } catch {
            inFlightWarmups[cacheKey] = nil
            throw error
        }
    }

    private static func performHealthCheck(backendURL: URL, traceID: String) async throws {
        let healthURL = backendURL.appending(path: "health")
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = timeoutSeconds
                request.setValue(traceID, forHTTPHeaderField: "X-Tid-Trace-Id")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw RealtimeClientError.invalidServerResponse
                }

                AppTrace.point(
                    "BackendPreflightService.health.response",
                    fields: [
                        "attempt": "\(attempt)",
                        "status": "\(httpResponse.statusCode)",
                        "trace_id": traceID
                    ]
                )

                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw RealtimeClientError.serverError(healthErrorMessage(from: data, statusCode: httpResponse.statusCode))
                }

                return
            } catch let error as URLError {
                lastError = error
                AppTrace.point(
                    "BackendPreflightService.health.error",
                    fields: [
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                        "code": "\(error.code.rawValue)",
                        "trace_id": traceID
                    ]
                )

                if attempt == maxAttempts {
                    throw RealtimeClientError.localNetworkUnavailable
                }
            } catch {
                lastError = error
                AppTrace.point(
                    "BackendPreflightService.health.error",
                    fields: [
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                        "trace_id": traceID
                    ]
                )

                if attempt == maxAttempts {
                    throw error
                }
            }

            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }

        if let lastError {
            throw lastError
        }

        throw RealtimeClientError.localNetworkUnavailable
    }

    private static func healthErrorMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "Backend health-check fejlede med status \(statusCode)."
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checks = object["checks"] as? [String: Any] else {
            return fallback
        }

        if checks["openAIAPIKey"] as? Bool == false {
            return "Backend mangler OpenAI API-nøgle."
        }

        if checks["backendAuth"] as? Bool == false {
            return "Backend mangler adgangstoken-konfiguration."
        }

        return fallback
    }
}
