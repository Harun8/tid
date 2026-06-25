import AVFoundation
import Foundation

enum PermissionError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Mikrofonadgang mangler. Giv Tid adgang i Indstillinger."
        }
    }
}

final class PermissionsService {
    func requestMicrophoneAccess() async throws {
        let granted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard granted else { throw PermissionError.microphoneDenied }
    }
}
