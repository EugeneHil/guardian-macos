import Foundation
import os
import UserNotifications

protocol NotificationPosting: Sendable {
    func requestAuthorization() async
    func postBlock(process: String, file: String) async
}

/// Text of a block notification. Only last path components are shown: full paths never leave the app.
struct BlockMessage: Equatable, Sendable {
    let title = "Access blocked"
    let body: String

    init(process: String, file: String) {
        body = "\(Self.name(of: process)) was blocked from opening \(Self.name(of: file))"
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Boundary: posts through `UNUserNotificationCenter` (verified in the VM only). Logs never carry paths.
struct UserNotificationPoster: NotificationPosting {
    private let log = Logger(subsystem: BundleIDs.app, category: "notifications")

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("notification authorization failed")
        }
    }

    func postBlock(process: String, file: String) async {
        let message = BlockMessage(process: process, file: file)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("posting a block notification failed")
        }
    }
}
