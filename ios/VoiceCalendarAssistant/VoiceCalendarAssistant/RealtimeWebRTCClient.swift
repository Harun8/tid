import AVFoundation
import Foundation
import WebRTC

final class RealtimeWebRTCClient: NSObject, RealtimeClient {
    let events: AsyncStream<RealtimeClientEvent>

    private let continuation: AsyncStream<RealtimeClientEvent>.Continuation
    private let backendURL: URL
    private let backendAuthToken: String
    private let modelName: String
    private let voiceName: String
    private let localeIdentifier: String
    private let timeZoneIdentifier: String
    private let safetyIdentifier: String
    private let defaultCalendarIdentifier: String?
    private let urlSession: URLSession
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var connectTask: Task<Void, Error>?
    private var audioEngine: AVAudioEngine?
    private var queuedClientEvents: [(data: Data, isAudioFrame: Bool)] = []
    private var connected = false
    private var suppressConnectionCloseEvents = false
    private var listeningBeganAt: Date?
    private var responseRequestedAt: Date?
    private var currentTraceID = AppTrace.makeID()
    private var emittedCalendarDraftArguments: Set<String> = []
    private var firstAudioFrameQueued = false
    private var firstAudioFrameSent = false
    private var firstRealtimeEventReceived = false
    private var pendingConversationContext: String?
    private let clientEventQueue = DispatchQueue(label: "com.tid.VoiceCalendarAssistant.realtimeClientEvents")
    private let clientEventQueueKey = DispatchSpecificKey<Bool>()

    private static var didInitializeWebRTC = false
    private static let realtimeSDPRequestTimeoutSeconds: TimeInterval = 12
    private static let dataChannelOpenTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let minimumRecordingDurationNanoseconds: UInt64 = 900_000_000
    private static let audioCaptureRetryDelayNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        850_000_000
    ]
    private static let realtimeInputSampleRate = 24_000.0

    @MainActor
    init(settings: SettingsStore, urlSession: URLSession = .shared) throws {
        guard let backendURL = settings.backendURL else {
            throw RealtimeClientError.backendURLMissing
        }

        self.backendURL = backendURL
        backendAuthToken = settings.backendAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = settings.modelName
        voiceName = settings.voiceName
        localeIdentifier = settings.localeDisplay
        timeZoneIdentifier = settings.timeZoneDisplay
        safetyIdentifier = settings.safetyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultCalendarIdentifier = settings.defaultCalendarIdentifier
        self.urlSession = urlSession
        Self.initializeWebRTCIfNeeded()
        peerConnectionFactory = RTCPeerConnectionFactory()
        clientEventQueue.setSpecific(key: clientEventQueueKey, value: true)

        var capturedContinuation: AsyncStream<RealtimeClientEvent>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func connect() async throws {
        if connected {
            AppTrace.point("RealtimeWebRTCClient.connect.reused", fields: ["trace_id": currentTraceID])
            continuation.yield(.connected)
            return
        }

        let traceID = currentTraceID
        let task = connectTaskIfNeeded(traceID: traceID)
        try await task.value
    }

    private func connectTaskIfNeeded(traceID: String) -> Task<Void, Error> {
        if connected {
            return Task<Void, Error> {
                self.continuation.yield(.connected)
            }
        }

        if let connectTask {
            return connectTask
        }

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.performConnect(traceID: traceID)
            } catch {
                if !Task.isCancelled {
                    AppTrace.point(
                        "RealtimeWebRTCClient.connect.failed",
                        fields: Self.errorFields(error, traceID: traceID)
                    )

                    let isRecording = self.audioEngine != nil
                    self.closeRealtimeConnection(suppressEvents: true, traceID: traceID)

                    if isRecording {
                        AppTrace.point(
                            "RealtimeWebRTCClient.connectFailureDeferredUntilStop",
                            fields: ["trace_id": traceID]
                        )
                        self.connectTask = nil
                        return
                    }

                    self.stopAudioCapture(traceID: traceID)
                    self.listeningBeganAt = nil
                    self.continuation.yield(.error(error.localizedDescription))
                }
                self.connectTask = nil
                throw error
            }

            self.connectTask = nil
        }

        connectTask = task
        return task
    }

    private func performConnect(traceID: String) async throws {

        try await AppTrace.measure(
            "RealtimeWebRTCClient.connect",
            fields: ["already_connected": "\(connected)", "trace_id": traceID]
        ) {
            if connected {
                continuation.yield(.connected)
                return
            }

            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.continualGatheringPolicy = .gatherContinually

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
            )

            let peerConnection = try AppTrace.measure("RealtimeWebRTCClient.makePeerConnection", fields: ["trace_id": traceID]) {
                guard let peerConnection = peerConnectionFactory.peerConnection(
                    with: configuration,
                    constraints: constraints,
                    delegate: self
                ) else {
                    throw RealtimeClientError.webRTCSetupFailed
                }

                return peerConnection
            }

            self.peerConnection = peerConnection

            let audioTransceiverInit = RTCRtpTransceiverInit()
            audioTransceiverInit.direction = .inactive
            peerConnection.addTransceiver(of: .audio, init: audioTransceiverInit)

            let dataChannelConfiguration = RTCDataChannelConfiguration()
            dataChannelConfiguration.isOrdered = true
            let dataChannel = try AppTrace.measure("RealtimeWebRTCClient.makeDataChannel", fields: ["trace_id": traceID]) {
                guard let dataChannel = peerConnection.dataChannel(forLabel: "oai-events", configuration: dataChannelConfiguration) else {
                    throw RealtimeClientError.dataChannelUnavailable
                }

                return dataChannel
            }
            dataChannel.delegate = self
            self.dataChannel = dataChannel

            let offerConstraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "false",
                    "OfferToReceiveVideo": "false"
                ],
                optionalConstraints: nil
            )

            let offer = try await AppTrace.measure("RTCPeerConnection.offer", fields: ["trace_id": traceID]) {
                try await peerConnection.tidOffer(for: offerConstraints)
            }
            try await AppTrace.measure("RTCPeerConnection.setLocalDescription", fields: ["trace_id": traceID]) {
                try await peerConnection.tidSetLocalDescription(offer)
            }
            let answerSDP = try await createRealtimeCallAnswer(forSDPOffer: offer.sdp, traceID: traceID)
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await AppTrace.measure("RTCPeerConnection.setRemoteDescription", fields: ["trace_id": traceID]) {
                try await peerConnection.tidSetRemoteDescription(answer)
            }

            connected = true
            AppTrace.point("RealtimeWebRTCClient.peerConnectionReady", fields: ["trace_id": traceID])
            continuation.yield(.connected)
        }
    }

    func setPendingConversationContext(_ text: String?) {
        let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingConversationContext = cleanText?.isEmpty == false ? cleanText : nil
    }

    func startListening() async throws {
        currentTraceID = AppTrace.makeID()
        let traceID = currentTraceID
        AppTrace.point("RealtimeWebRTCClient.startRequested", fields: ["trace_id": traceID])

        try await AppTrace.measure("RealtimeWebRTCClient.startListening", fields: ["trace_id": traceID]) {
            emittedCalendarDraftArguments.removeAll()
            resetPerTurnTraceState()
            dropQueuedClientEvents(traceID: traceID)
            var didStartAudioCapture = false

            do {
                if !connected {
                    _ = connectTaskIfNeeded(traceID: traceID)
                    AppTrace.point("RealtimeWebRTCClient.connectStartedBeforeCapture", fields: ["trace_id": traceID])
                }
                try AppTrace.measure("RealtimeWebRTCClient.send.inputAudioBufferClear", fields: ["trace_id": traceID]) {
                    try sendClientEvent(["type": "input_audio_buffer.clear"])
                }
                try sendPendingConversationContextIfNeeded(traceID: traceID)
                try await AppTrace.measure("RealtimeWebRTCClient.startAudioCapture", fields: ["trace_id": traceID]) {
                    try await startAudioCapture(traceID: traceID)
                }
                didStartAudioCapture = true
                listeningBeganAt = Date()
                AppTrace.point("RealtimeWebRTCClient.audioCaptureReady", fields: ["trace_id": traceID])
                continuation.yield(.listeningStarted)

                if connected {
                    try await AppTrace.measure("RealtimeWebRTCClient.waitForOpenDataChannel", fields: ["trace_id": traceID]) {
                        try await waitForOpenDataChannel()
                    }
                } else {
                    AppTrace.point("RealtimeWebRTCClient.connectWarmingDuringCapture", fields: ["trace_id": traceID])
                }
            } catch {
                if didStartAudioCapture {
                    stopAudioCapture(traceID: traceID)
                    listeningBeganAt = nil
                }
                throw error
            }
        }
    }

    private func dropQueuedClientEvents(traceID: String) {
        clientEventQueue.sync {
            let droppedCount = queuedClientEvents.count
            queuedClientEvents.removeAll()
            if droppedCount > 0 {
                AppTrace.point(
                    "RealtimeWebRTCClient.queuedClientEventsDropped",
                    fields: ["count": "\(droppedCount)", "trace_id": traceID]
                )
            }
        }
    }

    func stopListening() async throws {
        let traceID = currentTraceID
        AppTrace.point("RealtimeWebRTCClient.stopRequested", fields: ["trace_id": traceID])

        try await AppTrace.measure("RealtimeWebRTCClient.stopListening", fields: ["trace_id": traceID]) {
            try await AppTrace.measure("RealtimeWebRTCClient.waitForMinimumRecordingDuration", fields: ["trace_id": traceID]) {
                try await waitForMinimumRecordingDuration()
            }
            AppTrace.measure("RealtimeWebRTCClient.stopAudioCapture", fields: ["trace_id": traceID]) {
                stopAudioCapture(traceID: traceID)
            }
            if !connected {
                try await AppTrace.measure("RealtimeWebRTCClient.waitForConnectBeforeStop", fields: ["trace_id": traceID]) {
                    if let connectTask {
                        try await connectTask.value
                    } else {
                        try await connect()
                    }
                }
            }
            try await AppTrace.measure("RealtimeWebRTCClient.waitForOpenDataChannel", fields: ["trace_id": traceID]) {
                try await waitForOpenDataChannel()
            }
            try AppTrace.measure("RealtimeWebRTCClient.send.inputAudioBufferCommit", fields: ["trace_id": traceID]) {
                try sendClientEvent(["type": "input_audio_buffer.commit"])
            }
            AppTrace.point("RealtimeWebRTCClient.audioBufferCommitted", fields: ["trace_id": traceID])
            responseRequestedAt = Date()
            try AppTrace.measure("RealtimeWebRTCClient.send.responseCreate", fields: ["trace_id": traceID]) {
                try sendClientEvent(["type": "response.create"])
            }
            AppTrace.point("RealtimeWebRTCClient.responseCreateSent", fields: ["trace_id": traceID])
            listeningBeganAt = nil
        }
    }

    func sendUserText(_ text: String) async throws {
        currentTraceID = AppTrace.makeID()
        let traceID = currentTraceID

        try await AppTrace.measure("RealtimeWebRTCClient.sendUserText", fields: ["trace_id": traceID]) {
            emittedCalendarDraftArguments.removeAll()
            if !connected {
                try await connect()
            }

            try AppTrace.measure("RealtimeWebRTCClient.send.userText", fields: ["trace_id": traceID]) {
                try sendClientEvent([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": text
                            ]
                        ]
                    ]
                ])
            }
            responseRequestedAt = Date()
            try AppTrace.measure("RealtimeWebRTCClient.send.responseCreate", fields: ["trace_id": traceID]) {
                try sendClientEvent(["type": "response.create"])
            }
        }
    }

    func disconnect() async {
        AppTrace.measure("RealtimeWebRTCClient.disconnect", fields: ["trace_id": currentTraceID]) {
            connectTask?.cancel()
            connectTask = nil
            stopAudioCapture(traceID: currentTraceID)
            closeRealtimeConnection(suppressEvents: false, traceID: currentTraceID)
            clientEventQueue.sync {
                queuedClientEvents.removeAll()
            }
            connected = false
            responseRequestedAt = nil
            emittedCalendarDraftArguments.removeAll()
            continuation.yield(.disconnected)
            continuation.finish()
        }
    }

    private func sendPendingConversationContextIfNeeded(traceID: String) throws {
        guard let context = pendingConversationContext else { return }
        pendingConversationContext = nil

        try AppTrace.measure(
            "RealtimeWebRTCClient.send.pendingConversationContext",
            fields: ["characters": "\(context.count)", "trace_id": traceID]
        ) {
            try sendClientEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": context
                        ]
                    ]
                ]
            ])
        }
    }

    private func resetPerTurnTraceState() {
        firstRealtimeEventReceived = false
        responseRequestedAt = nil
        clientEventQueue.sync {
            firstAudioFrameQueued = false
            firstAudioFrameSent = false
        }
    }

    func createRealtimeCallAnswer(forSDPOffer sdpOffer: String, traceID: String? = nil) async throws -> String {
        let traceID = traceID ?? currentTraceID

        return try await AppTrace.measure("RealtimeWebRTCClient.createRealtimeCallAnswer", fields: ["trace_id": traceID]) {
            let endpoint = backendURL.appending(path: "realtime/sdp")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
            request.setValue(traceID, forHTTPHeaderField: "X-Tid-Trace-Id")
            if !backendAuthToken.isEmpty {
                request.setValue("Bearer \(backendAuthToken)", forHTTPHeaderField: "Authorization")
            }
            if !safetyIdentifier.isEmpty {
                request.setValue(safetyIdentifier, forHTTPHeaderField: "X-Tid-User-Hash")
            }
            request.setValue(modelName, forHTTPHeaderField: "X-Tid-Model")
            request.setValue(voiceName, forHTTPHeaderField: "X-Tid-Voice")
            request.setValue(localeIdentifier, forHTTPHeaderField: "X-Tid-Locale")
            request.setValue(timeZoneIdentifier, forHTTPHeaderField: "X-Tid-Time-Zone")
            request.timeoutInterval = Self.realtimeSDPRequestTimeoutSeconds
            request.httpBody = Data(sdpOffer.utf8)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await AppTrace.measure("URLSession.realtimeSDP", fields: ["trace_id": traceID]) {
                    try await urlSession.data(for: request)
                }
            } catch let error as URLError {
                AppTrace.point(
                    "RealtimeWebRTCClient.createRealtimeCallAnswer.error",
                    fields: Self.errorFields(error, traceID: traceID)
                )
                if Self.isLocalDevelopmentNetworkError(error, backendURL: backendURL) {
                    throw RealtimeClientError.localNetworkUnavailable
                }
                throw error
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RealtimeClientError.invalidServerResponse
            }

            AppTrace.point(
                "RealtimeWebRTCClient.createRealtimeCallAnswer.response",
                fields: [
                    "bytes": "\(data.count)",
                    "status": "\(httpResponse.statusCode)",
                    "trace_id": traceID
                ]
            )

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = Self.serverErrorMessage(from: data, statusCode: httpResponse.statusCode)
                throw RealtimeClientError.serverError(message)
            }

            guard let answer = String(data: data, encoding: .utf8), answer.contains("v=0") else {
                throw RealtimeClientError.invalidServerResponse
            }

            return answer
        }
    }

    func handleServerEvent(_ rawEvent: String) {
        guard let object = RealtimeEventParser.jsonObject(from: rawEvent),
              let type = object["type"] as? String else {
            return
        }

        traceFirstRealtimeEventIfNeeded(type)
        traceServerEvent(type)

        switch type {
        case "response.output_text.delta", "response.text.delta":
            if let delta = object["delta"] as? String {
                continuation.yield(.assistantText(delta))
            }
        case "response.output_audio_transcript.delta", "conversation.item.input_audio_transcription.delta":
            if let delta = object["delta"] as? String {
                continuation.yield(.partialTranscript(delta))
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = object["transcript"] as? String {
                continuation.yield(.finalTranscript(transcript))
            }
        case "response.audio.started", "response.output_audio.started":
            continuation.yield(.assistantAudioStarted)
        case "response.audio.done", "response.output_audio.done":
            continuation.yield(.assistantAudioEnded)
        case "response.function_call_arguments.done":
            parseFunctionCallArguments(object)
        case "error":
            if let data = rawEvent.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(RealtimeErrorEnvelope.self, from: data) {
                continuation.yield(.error(Self.userFacingErrorMessage(envelope)))
            }
        case "response.done":
            parseCompletedResponse(rawEvent)
            continuation.yield(.responseCompleted)
            responseRequestedAt = nil
        default:
            break
        }
    }

    private func traceServerEvent(_ type: String) {
        guard Self.shouldTraceServerEvent(type) else { return }

        var fields = [
            "event": type,
            "trace_id": currentTraceID
        ]
        if let elapsed = AppTrace.elapsedMilliseconds(since: responseRequestedAt) {
            fields["since_response_create_ms"] = elapsed
        }

        AppTrace.point("RealtimeWebRTCClient.serverEvent", fields: fields)
    }

    private func traceFirstRealtimeEventIfNeeded(_ type: String) {
        guard !firstRealtimeEventReceived else { return }

        firstRealtimeEventReceived = true
        var fields = [
            "event": type,
            "trace_id": currentTraceID
        ]
        if let elapsed = AppTrace.elapsedMilliseconds(since: responseRequestedAt) {
            fields["since_response_create_ms"] = elapsed
        }

        AppTrace.point("RealtimeWebRTCClient.firstRealtimeEventReceived", fields: fields)
    }

    private static func shouldTraceServerEvent(_ type: String) -> Bool {
        switch type {
        case "response.output_text.delta",
             "response.text.delta",
             "response.output_audio_transcript.delta",
             "conversation.item.input_audio_transcription.delta":
            return false
        default:
            return true
        }
    }

    private func parseCompletedResponse(_ rawEvent: String) {
        guard let data = rawEvent.data(using: .utf8),
              let done = try? JSONDecoder().decode(RealtimeResponseDone.self, from: data),
              let output = done.response.output else {
            return
        }

        for item in output where item.type == "function_call" && Self.isCalendarDraftTool(item.name) {
            emitCalendarDraft(arguments: item.arguments, source: "response.done")
        }
    }

    private static func isCalendarDraftTool(_ name: String) -> Bool {
        name == "stage_calendar_event" || name == "create_calendar_event_draft"
    }

    private static func userFacingErrorMessage(_ envelope: RealtimeErrorEnvelope) -> String {
        let message = envelope.error.message ?? envelope.error.type ?? "Realtime-fejl."
        if message.localizedCaseInsensitiveContains("buffer too small") {
            return "Jeg hørte ikke nok lyd. Hold knappen lidt længere og prøv igen."
        }
        return message
    }

    private static func serverErrorMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "Backend-fejl \(statusCode). Prøv igen om lidt."
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return fallback
        }

        if statusCode >= 500 ||
            text.localizedCaseInsensitiveContains("upstream connect error") ||
            text.localizedCaseInsensitiveContains("connection refused") ||
            text.localizedCaseInsensitiveContains("realtime call setup failed") {
            return "OpenAI Realtime er midlertidigt utilgængelig. Prøv igen om lidt."
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return text
        }

        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }

        return fallback
    }

    private static func isLocalDevelopmentNetworkError(_ error: URLError, backendURL: URL) -> Bool {
        guard isLocalDevelopmentHost(backendURL.host) else { return false }

        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .timedOut,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func isLocalDevelopmentHost(_ host: String?) -> Bool {
        guard let host else { return false }
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }

        let private172Prefix = #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#
        return host.range(of: private172Prefix, options: .regularExpression) != nil
    }

    private static func errorFields(
        _ error: Error,
        traceID: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let nsError = error as NSError
        var fields = extra
        fields["error"] = error.localizedDescription
        fields["domain"] = nsError.domain
        fields["code"] = "\(nsError.code)"
        fields["trace_id"] = traceID

        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            fields["reason"] = reason
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying_domain"] = underlyingError.domain
            fields["underlying_code"] = "\(underlyingError.code)"
            fields["underlying_error"] = underlyingError.localizedDescription
        }

        return fields
    }

    private static func initializeWebRTCIfNeeded() {
        guard !didInitializeWebRTC else { return }
        RTCInitializeSSL()
        didInitializeWebRTC = true
    }

    private func configureAudioSession(traceID: String) throws {
        let session = AVAudioSession.sharedInstance()
        let configurations: [(name: String, apply: () throws -> Void)] = [
            (
                name: "record.measurement.mix",
                apply: {
                    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
                }
            ),
            (
                name: "playAndRecord.measurement.mix",
                apply: {
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
                }
            ),
            (
                name: "record.measurement",
                apply: {
                    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                }
            )
        ]
        var lastError: Error?

        for configuration in configurations {
            do {
                try configuration.apply()
                try session.setPreferredSampleRate(48_000)
                try session.setPreferredIOBufferDuration(0.04)
                try session.setActive(true)

                let inputNames = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
                AppTrace.point(
                    "RealtimeWebRTCClient.configureAudioSession.active",
                    fields: [
                        "category": configuration.name,
                        "inputs": inputNames.isEmpty ? "none" : inputNames,
                        "input_channels": "\(session.inputNumberOfChannels)",
                        "sample_rate": "\(session.sampleRate)",
                        "trace_id": traceID
                    ]
                )
                return
            } catch {
                lastError = error
                AppTrace.point(
                    "RealtimeWebRTCClient.configureAudioSession.error",
                    fields: Self.errorFields(
                        error,
                        traceID: traceID,
                        extra: ["category": configuration.name]
                    )
                )
                deactivateAudioSession(traceID: traceID, reason: "configure_failed")
            }
        }

        if let lastError {
            throw lastError
        } else {
            AppTrace.point(
                "RealtimeWebRTCClient.configureAudioSession.error",
                fields: ["error": "No audio session configuration attempted", "trace_id": traceID]
            )
            throw RealtimeClientError.microphoneCaptureFailed
        }
    }

    private func startAudioCapture(traceID: String) async throws {
        stopAudioCapture(traceID: traceID)

        var lastError: Error?
        let maxAttempts = Self.audioCaptureRetryDelayNanoseconds.count + 1

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                AppTrace.point(
                    "RealtimeWebRTCClient.startAudioCapture.retry",
                    fields: [
                        "attempt": "\(attempt)",
                        "error": lastError?.localizedDescription ?? "Unknown microphone startup error",
                        "trace_id": traceID
                    ]
                )
            }

            do {
                try configureAudioSession(traceID: traceID)
                try startAudioCaptureAttempt(traceID: traceID, attempt: attempt)
                return
            } catch {
                lastError = error
            }

            stopAudioCapture(traceID: traceID)
            resetAudioSessionAfterCaptureFailure(traceID: traceID)

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: Self.audioCaptureRetryDelayNanoseconds[attempt - 1])
            }
        }

        if let lastError {
            AppTrace.point(
                "RealtimeWebRTCClient.startAudioCapture.failed",
                fields: Self.errorFields(
                    lastError,
                    traceID: traceID,
                    extra: ["attempts": "\(maxAttempts)"]
                )
            )
        } else {
            AppTrace.point(
                "RealtimeWebRTCClient.startAudioCapture.failed",
                fields: ["attempts": "\(maxAttempts)", "trace_id": traceID]
            )
        }

        throw RealtimeClientError.microphoneCaptureFailed
    }

    private func startAudioCaptureAttempt(traceID: String, attempt: Int) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        AppTrace.point(
            "RealtimeWebRTCClient.startAudioCapture.format",
            fields: [
                "attempt": "\(attempt)",
                "channels": "\(inputFormat.channelCount)",
                "sample_rate": "\(inputFormat.sampleRate)",
                "trace_id": traceID
            ]
        )

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RealtimeClientError.microphoneCaptureFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let audio = Self.base64PCM16Audio(from: buffer, targetSampleRate: Self.realtimeInputSampleRate),
                  !audio.isEmpty else {
                return
            }

            self.enqueueAudioFrame(
                audio,
                level: Self.normalizedAudioLevel(from: buffer),
                traceID: traceID
            )
        }

        engine.prepare()

        do {
            try engine.start()
            audioEngine = engine
            AppTrace.point(
                "RealtimeWebRTCClient.startAudioCapture.started",
                fields: ["attempt": "\(attempt)", "trace_id": traceID]
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private func stopAudioCapture(traceID: String? = nil) {
        guard let audioEngine else {
            if let traceID {
                deactivateAudioSession(traceID: traceID, reason: "no_engine")
            }
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
        if let traceID {
            deactivateAudioSession(traceID: traceID, reason: "stop_capture")
        }
    }

    private func resetAudioSessionAfterCaptureFailure(traceID: String) {
        deactivateAudioSession(traceID: traceID, reason: "capture_failed")
    }

    private func deactivateAudioSession(traceID: String, reason: String) {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            AppTrace.point(
                "RealtimeWebRTCClient.audioSessionDeactivated",
                fields: ["reason": reason, "trace_id": traceID]
            )
        } catch {
            AppTrace.point(
                "RealtimeWebRTCClient.audioSessionDeactivation.error",
                fields: Self.errorFields(error, traceID: traceID, extra: ["reason": reason])
            )
        }
    }

    private static func base64PCM16Audio(from buffer: AVAudioPCMBuffer, targetSampleRate: Double) -> String? {
        guard let channels = buffer.floatChannelData else { return nil }

        let inputFrameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard inputFrameCount > 0, channelCount > 0, buffer.format.sampleRate > 0 else { return nil }

        let outputFrameCount = max(1, Int((Double(inputFrameCount) * targetSampleRate / buffer.format.sampleRate).rounded(.down)))
        var data = Data(capacity: outputFrameCount * MemoryLayout<Int16>.size)

        for outputIndex in 0..<outputFrameCount {
            let sourcePosition = Double(outputIndex) * buffer.format.sampleRate / targetSampleRate
            let sourceIndex = min(max(Int(sourcePosition), 0), inputFrameCount - 1)
            let nextIndex = min(sourceIndex + 1, inputFrameCount - 1)
            let fraction = Float(sourcePosition - Double(sourceIndex))
            var sample: Float = 0

            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                let current = channel[sourceIndex]
                let next = channel[nextIndex]
                sample += current + ((next - current) * fraction)
            }

            sample /= Float(channelCount)
            let clamped = min(max(sample, -1), 1)
            let scaled = max(-32_767, min(32_767, Int((clamped * 32_767).rounded())))
            var pcmSample = Int16(scaled).littleEndian
            withUnsafeBytes(of: &pcmSample) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data.base64EncodedString()
    }

    private static func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumSquares = 0.0
        let sampleCount = frameCount * channelCount

        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]

            for frameIndex in 0..<frameCount {
                let sample = Double(channel[frameIndex])
                sumSquares += sample * sample
            }
        }

        return min(1, sqrt(sumSquares / Double(sampleCount)) * 8)
    }

    private func sendClientEvent(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)

        try performOnClientEventQueue {
            try sendClientEventDataOnQueue(data, isAudioFrame: false)
        }
    }

    private func enqueueClientEvent(_ object: [String: Any]) {
        clientEventQueue.async { [weak self] in
            guard let self else { return }

            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                try self.sendClientEventDataOnQueue(data, isAudioFrame: false)
            } catch {
                self.continuation.yield(.error(error.localizedDescription))
            }
        }
    }

    private func enqueueAudioFrame(_ audio: String, level: Double, traceID: String) {
        continuation.yield(.inputAudioLevel(level))
        clientEventQueue.async { [weak self] in
            guard let self else { return }

            if !self.firstAudioFrameQueued {
                self.firstAudioFrameQueued = true
                AppTrace.point("RealtimeWebRTCClient.firstAudioFrameQueued", fields: ["trace_id": traceID])
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "input_audio_buffer.append",
                    "audio": audio
                ])
                try self.sendClientEventDataOnQueue(data, isAudioFrame: true)
            } catch {
                self.continuation.yield(.error(error.localizedDescription))
            }
        }
    }

    private func performOnClientEventQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: clientEventQueueKey) == true {
            return try operation()
        }

        return try clientEventQueue.sync(execute: operation)
    }

    private func sendClientEventDataOnQueue(_ data: Data, isAudioFrame: Bool) throws {
        guard let dataChannel else {
            queuedClientEvents.append((data: data, isAudioFrame: isAudioFrame))
            return
        }

        guard dataChannel.readyState == .open else {
            queuedClientEvents.append((data: data, isAudioFrame: isAudioFrame))
            return
        }

        let buffer = RTCDataBuffer(data: data, isBinary: false)
        if !dataChannel.sendData(buffer) {
            throw RealtimeClientError.dataChannelUnavailable
        }
        if isAudioFrame {
            traceFirstAudioFrameSentOnQueue()
        }
    }

    private func waitForOpenDataChannel() async throws {
        if dataChannel?.readyState == .open {
            flushQueuedClientEvents()
            return
        }

        let deadline = Date().addingTimeInterval(Double(Self.dataChannelOpenTimeoutNanoseconds) / 1_000_000_000)
        while dataChannel?.readyState != .open {
            if Date() >= deadline {
                throw RealtimeClientError.dataChannelUnavailable
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        flushQueuedClientEvents()
    }

    private func waitForMinimumRecordingDuration() async throws {
        guard let listeningBeganAt else { return }

        let elapsed = Date().timeIntervalSince(listeningBeganAt)
        let elapsedNanoseconds = UInt64(max(0, elapsed) * 1_000_000_000)
        guard elapsedNanoseconds < Self.minimumRecordingDurationNanoseconds else { return }

        try await Task.sleep(nanoseconds: Self.minimumRecordingDurationNanoseconds - elapsedNanoseconds)
    }

    private func flushQueuedClientEvents() {
        clientEventQueue.async { [weak self] in
            self?.flushQueuedClientEventsOnQueue()
        }
    }

    private func flushQueuedClientEventsOnQueue() {
        guard let dataChannel, dataChannel.readyState == .open else { return }

        let queuedEvents = queuedClientEvents
        queuedClientEvents.removeAll()

        for event in queuedEvents {
            if dataChannel.sendData(RTCDataBuffer(data: event.data, isBinary: false)),
               event.isAudioFrame {
                traceFirstAudioFrameSentOnQueue()
            }
        }
    }

    private func traceFirstAudioFrameSentOnQueue() {
        guard !firstAudioFrameSent else { return }

        firstAudioFrameSent = true
        AppTrace.point("RealtimeWebRTCClient.firstAudioFrameSent", fields: ["trace_id": currentTraceID])
    }

    private func closeRealtimeConnection(suppressEvents: Bool, traceID: String) {
        if suppressEvents {
            suppressConnectionCloseEvents = true
        }

        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        connected = false

        if suppressEvents {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.suppressConnectionCloseEvents = false
                AppTrace.point("RealtimeWebRTCClient.connectionCloseSuppressionEnded", fields: ["trace_id": traceID])
            }
        }
    }

    private func parseFunctionCallArguments(_ object: [String: Any]) {
        guard let name = object["name"] as? String,
              Self.isCalendarDraftTool(name),
              let arguments = object["arguments"] as? String else {
            return
        }

        emitCalendarDraft(arguments: arguments, source: "function_call_arguments.done")
    }

    private func emitCalendarDraft(arguments: String, source: String) {
        guard !emittedCalendarDraftArguments.contains(arguments) else {
            AppTrace.point(
                "RealtimeWebRTCClient.calendarDraftDuplicateIgnored",
                fields: ["source": source, "trace_id": currentTraceID]
            )
            return
        }

        emittedCalendarDraftArguments.insert(arguments)
        AppTrace.point(
            "RealtimeWebRTCClient.toolCallReceived",
            fields: [
                "arguments_chars": "\(arguments.count)",
                "source": source,
                "trace_id": currentTraceID
            ]
        )

        guard let argumentsData = arguments.data(using: .utf8) else {
            return
        }

        do {
            let payload = try AppTrace.measure(
                "RealtimeWebRTCClient.calendarDraftDecode",
                fields: ["source": source, "trace_id": currentTraceID]
            ) {
                try JSONDecoder().decode(CalendarEventToolPayload.self, from: argumentsData)
            }
            let draft = try AppTrace.measure(
                "RealtimeWebRTCClient.calendarDraftValidated",
                fields: ["source": source, "trace_id": currentTraceID]
            ) {
                try payload.makeDraft(defaultCalendarIdentifier: defaultCalendarIdentifier)
            }
            continuation.yield(.calendarDraft(draft))
        } catch {
            continuation.yield(.error(error.localizedDescription))
        }
    }
}

extension RealtimeWebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        AppTrace.point(
            "RealtimeWebRTCClient.dataChannelState",
            fields: ["state": String(describing: dataChannel.readyState), "trace_id": currentTraceID]
        )

        if dataChannel.readyState == .open {
            flushQueuedClientEvents()
        } else if dataChannel.readyState == .closed {
            guard !suppressConnectionCloseEvents else {
                AppTrace.point(
                    "RealtimeWebRTCClient.dataChannelCloseIgnored",
                    fields: ["trace_id": currentTraceID]
                )
                return
            }
            continuation.yield(.disconnected)
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let rawEvent = String(data: buffer.data, encoding: .utf8) else {
            return
        }

        handleServerEvent(rawEvent)
    }
}

extension RealtimeWebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        AppTrace.point(
            "RealtimeWebRTCClient.iceConnectionState",
            fields: ["state": String(describing: newState), "trace_id": currentTraceID]
        )

        if suppressConnectionCloseEvents,
           newState == .failed || newState == .disconnected || newState == .closed {
            AppTrace.point(
                "RealtimeWebRTCClient.iceConnectionStateIgnored",
                fields: ["state": String(describing: newState), "trace_id": currentTraceID]
            )
            return
        }

        if newState == .failed {
            continuation.yield(.error("WebRTC-forbindelsen fejlede."))
        } else if newState == .disconnected || newState == .closed {
            continuation.yield(.disconnected)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        AppTrace.point("RealtimeWebRTCClient.didOpenDataChannel", fields: ["trace_id": currentTraceID])
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        flushQueuedClientEvents()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        AppTrace.point(
            "RealtimeWebRTCClient.peerConnectionState",
            fields: ["state": String(describing: newState), "trace_id": currentTraceID]
        )

        if suppressConnectionCloseEvents,
           newState == .failed || newState == .disconnected || newState == .closed {
            AppTrace.point(
                "RealtimeWebRTCClient.peerConnectionStateIgnored",
                fields: ["state": String(describing: newState), "trace_id": currentTraceID]
            )
            return
        }

        if newState == .failed {
            continuation.yield(.error("WebRTC-forbindelsen fejlede."))
        } else if newState == .disconnected || newState == .closed {
            continuation.yield(.disconnected)
        }
    }
}

private extension RTCPeerConnection {
    func tidOffer(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            offer(for: constraints) { sessionDescription, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sessionDescription {
                    continuation.resume(returning: sessionDescription)
                } else {
                    continuation.resume(throwing: RealtimeClientError.webRTCSetupFailed)
                }
            }
        }
    }

    func tidSetLocalDescription(_ sessionDescription: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setLocalDescription(sessionDescription) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func tidSetRemoteDescription(_ sessionDescription: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setRemoteDescription(sessionDescription) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
