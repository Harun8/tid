import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {
    private var activity: Activity<TidRecordingActivityAttributes>?
    private var lastDeliveredState: TidRecordingActivityAttributes.ContentState?
    private static let staleTransientActivityAge: TimeInterval = 90

    func update(
        _ state: TidRecordingActivityAttributes.ContentState,
        startsActivity: Bool = false,
        alertConfiguration: AlertConfiguration? = nil
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppTrace.point("live_activity_skipped", fields: ["reason": "disabled", "phase": state.phase.rawValue])
            return
        }

        await cleanupStaleTransientActivities()

        if let currentActivity {
            if lastDeliveredState == state, alertConfiguration == nil {
                AppTrace.point(
                    "live_activity_update_skipped",
                    fields: [
                        "reason": "duplicate_state",
                        "phase": state.phase.rawValue,
                        "activity_state": Self.activityStateDescription(currentActivity)
                    ]
                )
                return
            }

            await currentActivity.update(
                ActivityContent(state: state, staleDate: nil),
                alertConfiguration: alertConfiguration
            )
            activity = currentActivity
            lastDeliveredState = state
            AppTrace.point(
                "live_activity_updated",
                fields: [
                    "phase": state.phase.rawValue,
                    "has_payload": "\(state.confirmationPayload != nil)",
                    "has_alert": "\(alertConfiguration != nil)",
                    "activity_state": Self.activityStateDescription(currentActivity)
                ]
            )
            return
        }

        guard startsActivity else {
            AppTrace.point("live_activity_skipped", fields: ["reason": "no_current_activity", "phase": state.phase.rawValue])
            return
        }

        for attempt in 1...2 {
            do {
                activity = try Activity.request(
                    attributes: TidRecordingActivityAttributes(sessionID: UUID().uuidString),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastDeliveredState = state
                AppTrace.point(
                    "live_activity_started",
                    fields: [
                        "id": activity?.id ?? "unknown",
                        "phase": state.phase.rawValue,
                        "attempt": "\(attempt)",
                        "has_payload": "\(state.confirmationPayload != nil)",
                        "has_alert": "\(alertConfiguration != nil)"
                    ]
                )

                if let alertConfiguration, let activity {
                    await activity.update(
                        ActivityContent(state: state, staleDate: nil),
                        alertConfiguration: alertConfiguration
                    )
                    AppTrace.point(
                        "live_activity_start_alert_sent",
                        fields: [
                            "id": activity.id,
                            "phase": state.phase.rawValue
                        ]
                    )
                }
                return
            } catch {
                AppTrace.point(
                    "live_activity_start_failed",
                    fields: [
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription
                    ]
                )
                activity = nil
                await cleanupStaleTransientActivities(force: true)
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    func end(_ state: TidRecordingActivityAttributes.ContentState, after seconds: TimeInterval) async {
        let activities = activeActivities
        guard !activities.isEmpty else {
            AppTrace.point("live_activity_end_skipped", fields: ["reason": "no_current_activity", "phase": state.phase.rawValue])
            return
        }

        for currentActivity in activities {
            await currentActivity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(seconds))
            )
        }
        AppTrace.point("live_activity_ended", fields: ["count": "\(activities.count)", "phase": state.phase.rawValue])
        activity = nil
        lastDeliveredState = nil
    }

    func stopRequestID() -> String? {
        activeActivities.compactMap { $0.content.state.stopRequestID }.first
    }

    func waitForState(_ phase: TidRecordingActivityAttributes.Phase, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if activeActivities.contains(where: { $0.content.state.phase == phase }) {
                AppTrace.point("live_activity_wait_ready", fields: ["phase": phase.rawValue, "result": "ready"])
                return true
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        AppTrace.point("live_activity_wait_ready", fields: ["phase": phase.rawValue, "result": "timeout"])
        return false
    }

    private var currentActivity: Activity<TidRecordingActivityAttributes>? {
        if let activity, Self.isReusable(activity) {
            return activity
        }

        activity = nil
        return Activity<TidRecordingActivityAttributes>.activities.first(where: Self.isReusable)
    }

    private var activeActivities: [Activity<TidRecordingActivityAttributes>] {
        var activities = Activity<TidRecordingActivityAttributes>.activities.filter(Self.isReusable)

        if let activity, Self.isReusable(activity), !activities.contains(where: { $0.id == activity.id }) {
            activities.append(activity)
        }

        return activities
    }

    private static func isReusable(_ activity: Activity<TidRecordingActivityAttributes>) -> Bool {
        guard !isStaleTransient(activity) else { return false }

        switch activity.activityState {
        case .active, .stale, .pending:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }

    private func cleanupStaleTransientActivities(force: Bool = false) async {
        let staleActivities = Activity<TidRecordingActivityAttributes>.activities.filter { activity in
            force || Self.isStaleTransient(activity)
        }

        guard !staleActivities.isEmpty else { return }

        let state = TidRecordingActivityAttributes.ContentState(
            phase: .idle,
            title: "Tid",
            subtitle: "Lukket",
            detail: nil,
            startedAt: Date()
        )

        for staleActivity in staleActivities {
            await staleActivity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }

        AppTrace.point(
            "live_activity_stale_cleanup",
            fields: ["count": "\(staleActivities.count)", "force": "\(force)"]
        )
    }

    private static func isStaleTransient(_ activity: Activity<TidRecordingActivityAttributes>) -> Bool {
        let state = activity.content.state
        let isTransient: Bool
        switch state.phase {
        case .connecting, .listening, .thinking:
            isTransient = true
        case .idle, .needsClarification, .readyToConfirm, .saved, .error:
            isTransient = false
        }

        return isTransient && Date().timeIntervalSince(state.startedAt) > staleTransientActivityAge
    }

    private static func activityStateDescription(_ activity: Activity<TidRecordingActivityAttributes>) -> String {
        switch activity.activityState {
        case .active:
            return "active"
        case .stale:
            return "stale"
        case .pending:
            return "pending"
        case .ended:
            return "ended"
        case .dismissed:
            return "dismissed"
        @unknown default:
            return "unknown"
        }
    }
}
