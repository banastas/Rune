// Open Nib when you log in (PRD AP2): the system's login item for the app itself
// (`SMAppService.mainApp`, §6.3). macOS confirms it with a notification and lists Nib in
// System Settings › General › Login Items, where it can be turned off too; this follows.

import Foundation
import ServiceManagement

@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var enabled = false
    /// Registered, but macOS waits for the user's OK in System Settings.
    private(set) var needsApproval = false
    private(set) var failure: String?

    #if DEBUG
    /// The scenarios' stand-in (-NibFakeLoginItem YES): the real one would add this build to
    /// the Mac's Login Items.
    private var fake: Bool? = UserDefaults.standard.bool(forKey: "NibFakeLoginItem") ? false : nil
    #endif

    private init() { refresh() }

    /// As System Settings has it now (it can be changed there while Nib runs).
    func refresh() {
        #if DEBUG
        if let fake { enabled = fake; needsApproval = false; return }
        #endif
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        failure = nil
        #if DEBUG
        if fake != nil { fake = on; refresh(); return }
        #endif
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = "macOS said: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
