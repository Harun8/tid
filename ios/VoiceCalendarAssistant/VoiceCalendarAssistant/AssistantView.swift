import SwiftUI

struct AssistantView: View {
    @ObservedObject var viewModel: VoiceAssistantViewModel
    @ObservedObject var settings: SettingsStore
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            TidDesign.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 10)

                Spacer(minLength: 20)

                mainContent
                    .padding(.horizontal, 26)
                    .frame(maxWidth: 520)

                Spacer(minLength: 24)
            }
            .padding(.bottom, 118)

            bottomButton
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
    }

    private var header: some View {
        ZStack {
            Text("Tid")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TidDesign.textPrimary)

            HStack {
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Indstillinger")
                }
                .buttonStyle(TidIconButtonStyle())
            }
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.uiState {
        case .idle:
            recorderContent(
                title: "Klar",
                subtitle: "Sig din kalenderaftale",
                mode: .microphone
            )
        case .connecting:
            recorderContent(
                title: "Forbinder…",
                subtitle: "Gør mikrofonen klar",
                mode: .progress
            )
        case .listening(let transcript):
            recorderContent(
                title: "Lytter…",
                subtitle: transcript ?? "Tal nu…",
                mode: .bars(recording: true)
            )
        case .thinking:
            recorderContent(
                title: "Forstår…",
                subtitle: viewModel.finalTranscript.isEmpty ? "Læser aftalen" : viewModel.finalTranscript,
                mode: .bars(recording: false)
            )
        case .needsClarification(let question, let summary):
            clarificationContent(question: question, summary: summary)
        case .readyToConfirm(let draft):
            readyContent(draft: draft)
        case .saving:
            recorderContent(
                title: "Gemmer…",
                subtitle: "Lægger aftalen i Kalender",
                mode: .progress
            )
        case .saved(let draft):
            savedContent(draft: draft)
        case .error(let presentation):
            errorContent(presentation)
        }
    }

    private func recorderContent(title: String, subtitle: String, mode: RecorderMode) -> some View {
        VStack(spacing: 26) {
            recorderVisual(mode: mode)

            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(TidDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: 330)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func recorderVisual(mode: RecorderMode) -> some View {
        switch mode {
        case .microphone:
            Button {
                Task { await viewModel.startListening() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(TidDesign.accent)
                    .frame(width: 132, height: 132)
                    .background(TidDesign.softAccent, in: Circle())
                    .overlay(Circle().stroke(TidDesign.accent.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(PressableScaleStyle())
        case .bars(let recording):
            VoiceBarsView(isRecording: recording, level: viewModel.audioLevel)
                .frame(maxWidth: 310)
                .padding(.vertical, 22)
        case .progress:
            ProgressView()
                .controlSize(.large)
                .tint(TidDesign.accent)
                .frame(width: 132, height: 132)
                .background(TidDesign.softAccent, in: Circle())
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(TidDesign.error)
                .frame(width: 132, height: 132)
                .background(TidDesign.error.opacity(0.09), in: Circle())
        }
    }

    private func clarificationContent(question: String, summary: String?) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 43, weight: .semibold))
                .foregroundStyle(TidDesign.accent)

            VStack(spacing: 10) {
                Text(question)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.84)

                if let summary {
                    Text(summary)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(TidDesign.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(TidDesign.elevatedCard, in: Capsule())
                        .overlay(Capsule().stroke(TidDesign.outline, lineWidth: 1))
                }
            }
        }
    }

    private func readyContent(draft: CalendarEventDraft) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "calendar")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TidDesign.accent)
                .frame(width: 76, height: 76)
                .background(TidDesign.softAccent, in: Circle())

            ConfirmationPreviewView(draft: draft)

            Button("Ret") {
                viewModel.editDraft()
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(TidDesign.textSecondary)
        }
    }

    private func savedContent(draft: CalendarEventDraft) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 66, weight: .semibold))
                .foregroundStyle(TidDesign.success)

            VStack(spacing: 8) {
                Text("Gemt i Kalender")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)

                Text("\(draft.title) · \(DateFormatting.danishTimeInterval(start: draft.startDate, end: draft.endDate, timeZoneIdentifier: draft.timeZoneIdentifier))")
                    .font(.title3)
                    .foregroundStyle(TidDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    private func errorContent(_ presentation: TidRecoveryPresentation) -> some View {
        VStack(spacing: 24) {
            recorderVisual(mode: .error)

            VStack(spacing: 10) {
                Text(presentation.title)
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(TidDesign.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.84)

                Text(presentation.message)
                    .font(.title3)
                    .foregroundStyle(TidDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: 340)
            }

            Text(presentation.recovery)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TidDesign.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.84)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .frame(maxWidth: 360)
                .background(TidDesign.elevatedCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TidDesign.outline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomButton: some View {
        Button {
            Task { await performPrimaryAction() }
        } label: {
            Text(primaryButtonTitle)
        }
        .buttonStyle(TidPrimaryButtonStyle(isDestructive: isStopButton))
        .disabled(isPrimaryButtonDisabled)
        .opacity(isPrimaryButtonDisabled ? 0.55 : 1)
    }

    private var primaryButtonTitle: String {
        switch viewModel.uiState {
        case .idle, .saved:
            return "Start"
        case .connecting:
            return "Forbinder…"
        case .listening:
            return "Stop"
        case .thinking:
            return "Arbejder…"
        case .needsClarification:
            return "Svar"
        case .readyToConfirm:
            return "Gem i kalender"
        case .saving:
            return "Gemmer…"
        case .error(let presentation):
            return presentation.actionTitle
        }
    }

    private var isStopButton: Bool {
        if case .listening = viewModel.uiState {
            return true
        }
        return false
    }

    private var isPrimaryButtonDisabled: Bool {
        switch viewModel.uiState {
        case .connecting, .thinking, .saving:
            return true
        default:
            return false
        }
    }

    private func performPrimaryAction() async {
        switch viewModel.uiState {
        case .idle, .saved, .error:
            await viewModel.startListening()
        case .listening:
            await viewModel.stopListening()
        case .needsClarification:
            await viewModel.startListening()
        case .readyToConfirm:
            await viewModel.saveConfirmed()
        case .connecting, .thinking, .saving:
            break
        }
    }
}

private enum RecorderMode {
    case microphone
    case bars(recording: Bool)
    case progress
    case error
}
