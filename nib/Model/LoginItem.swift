// Open Nib when you log in (PRD AP2): the system's login item for the app itself
// (`SMAppService.mainApp`, §6.3). macOS confirms it with a notification and lists Nib in
// System Settings › General › Login Items & Extensions (its name since macOS 15), where it can be turned off too; this follows.
//
// macOS keeps one login item for the bundle ID, at the path of the copy that registered it, and
// says "enabled" to every copy. A Debug build opened outside a scenario registered itself, and
// the Mac opened that build at login beside the installed Rune (the user's report, 2026-10-15);
// a copy run from Downloads before it was moved to Applications would do the same. So a Debug
// build never registers for real (unless asked, -NibRealLoginItem YES), and a copy finding the
// item on but registered by another copy (or by a Rune from before this was kept) registers
// it again, here.

import Foundation
import NibSync
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
    /// The stand-in, in every Debug build (the scenarios' too): the real one would add this
    /// build to the Mac's Login Items. -NibRealLoginItem YES for the real one.
    private var fake: Bool? = NibDefaults.store.bool(forKey: "NibRealLoginItem") ? nil : false
    #endif

    /// The copy that last registered the item, as this Mac's Rune has it (macOS doesn't say).
    private static let pathKey = "loginItemPath"

    private init() {
        refresh()
        moveHereIfElsewhere()
    }

    /// On, but registered by another copy of Rune (or by one from before the path was kept):
    /// registered again from this one, so the Mac opens this copy at login.
    private func moveHereIfElsewhere() {
        #if DEBUG
        if fake != nil { return }
        #endif
        let here = Bundle.main.bundleURL.standardizedFileURL.path
        guard enabled, NibDefaults.store.string(forKey: Self.pathKey) != here else { return }
        try? SMAppService.mainApp.unregister()
        do {
            try SMAppService.mainApp.register()
            NibDefaults.store.set(here, forKey: Self.pathKey)
        } catch {
            failure = "macOS said: \(error.localizedDescription)"
        }
        refresh()
    }

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
            if on {
                try SMAppService.mainApp.register()
                NibDefaults.store.set(Bundle.main.bundleURL.standardizedFileURL.path, forKey: Self.pathKey)
            } else {
                try SMAppService.mainApp.unregister()
                NibDefaults.store.removeObject(forKey: Self.pathKey)
            }
        } catch {
            failure = "macOS said: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
