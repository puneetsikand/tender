import Foundation
import UserNotifications

/// Posts a "copy finished" notification. Only inside an app bundle: UserNotifications needs one.
@MainActor
enum Notifier {
    static func post(for job: JobProgress, card: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        if let s = job.summary {
            content.title = s.allSucceeded ? "Copied \(card)" : "Copy of \(card) finished with problems"
            content.body = s.allSucceeded
                ? "\(s.results.count) files copied and verified."
                : "\(s.failed.count) of \(s.results.count) files failed. The rest are copied and verified."
        } else {
            content.title = job.cancelled ? "Copy of \(card) cancelled" : "Copy of \(card) interrupted"
            content.body = "\(job.filesDone) of \(job.rows.count) files were copied and verified."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}
