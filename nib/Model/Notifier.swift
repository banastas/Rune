// Notifications (PRD SY15, A8, V13): a conflict, or a file Nib can't save or sync, said with the
// default sound while Nib isn't frontmost, once while it lasts (NibText's `AlertLedger`), and
// taken out of Notification Center once it's over. A click brings that file's window forward.
// macOS asks once whether Nib may: at the end of the welcome window, or, on a Mac past it, at
// the first launch that has this. The test harness's Nib never asks or posts (the permission is
// the bundle's, the user's Nib's too): it keeps what it would have said, for the scenarios.

import AppKit
import NibSync
import NibText
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var ledger = AlertLedger()
    #if DEBUG
    /// The scenarios': what this Nib would have posted, and taken back.
    private(set) var posted: [Alerts.Alert] = []
    private(set) var withdrawn: [Alerts.Kind] = []
    #endif

    /// At launch: clicks on Nib's notifications come here; and past the first run, macOS asks
    /// (once: it keeps the answer, which System Settings › Notifications changes).
    func start() {
        guard !NibPaths.isScenario else { return }
        UNUserNotificationCenter.current().delegate = self
        if !FirstRun.needed { askIfNeeded() }
    }

    /// macOS's question, if it hasn't asked it yet: alerts with sound.
    func askIfNeeded() {
        guard !NibPaths.isScenario else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// A problem with the file at `url` began, or went on: said once, if Nib isn't frontmost.
    func began(_ alert: Alerts.Alert, for url: URL) {
        guard ledger.began(alert.kind, file: url.path, frontmost: NSApp.isActive) else { return }
        #if DEBUG
        if NibPaths.isScenario { posted.append(alert); return }
        #endif
        guard !NibPaths.isScenario else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default   // V13: problems play the default sound
        content.threadIdentifier = url.path
        content.userInfo = ["path": url.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.identifier(alert.kind, url), content: content, trigger: nil))
    }

    /// It's over: the next time is news again, and its notification leaves Notification Center.
    func ended(_ kind: Alerts.Kind, for url: URL) {
        guard ledger.ended(kind, file: url.path) else { return }
        withdraw([kind], url)
    }

    /// The file closed: all of it is over.
    func closed(_ url: URL) {
        withdraw(ledger.closed(url.path), url)
    }

    private func withdraw(_ kinds: [Alerts.Kind], _ url: URL) {
        guard !kinds.isEmpty else { return }
        #if DEBUG
        if NibPaths.isScenario { withdrawn += kinds; return }
        #endif
        guard !NibPaths.isScenario else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: kinds.map { Self.identifier($0, url) })
    }

    private static func identifier(_ kind: Alerts.Kind, _ url: URL) -> String { kind.rawValue + ":" + url.path }

    // MARK: UNUserNotificationCenterDelegate

    /// A click: Nib forward, with that file's window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run {
            let url = URL(fileURLWithPath: path)
            NSApp.activate()
            if url.standardizedFileURL == Documents.scratch.url.standardizedFileURL { AppDelegate.showScratch() } else { AppDelegate.openFile(url) }
        }
    }

    /// One arriving while Nib is frontmost (it came forward meanwhile): the strip says it already.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
