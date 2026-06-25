import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var viewModel: VoiceAssistantViewModel
    @State private var isSettingsPresented = false
    @State private var consumedDebugStartArgument = false

    init() {
        let session = VoiceCalendarAssistantSession.shared
        _settingsStore = StateObject(wrappedValue: session.settingsStore)
        _viewModel = StateObject(wrappedValue: session.viewModel)
    }

    var body: some View {
        AssistantView(
            viewModel: viewModel,
            settings: settingsStore,
            onOpenSettings: { isSettingsPresented = true }
        )
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(settings: settingsStore)
        }
        .onOpenURL { url in
            viewModel.handleDeepLink(url)
        }
        .task {
            await viewModel.loadCalendars()
            await consumePendingStartListeningIntent()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await consumePendingStartListeningIntent() }
        }
    }

    private func consumePendingStartListeningIntent() async {
        let hasIntentFlag = UserDefaults.standard.bool(forKey: AppLaunchIntentKeys.startListening)
        let hasDebugLaunchArgument = !consumedDebugStartArgument && ProcessInfo.processInfo.arguments.contains("-TidStartListening")
        guard hasIntentFlag || hasDebugLaunchArgument else { return }

        consumedDebugStartArgument = consumedDebugStartArgument || hasDebugLaunchArgument
        UserDefaults.standard.removeObject(forKey: AppLaunchIntentKeys.startListening)
        await viewModel.startListening()
    }
}

#Preview {
    ContentView()
}
