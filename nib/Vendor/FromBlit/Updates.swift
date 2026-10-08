// From Blit (/Volumes/Photography/_GitHub/blit) at 297871d, Blit/Model/Updates.swift, copied
// 2026-10-07 for PRD DS2; Rune's own now (PRD §7).
//
// Automatic updates (Sparkle): Rune is sold outside the Mac App Store, so it checks
// https://rune.banast.as/appcast.xml once a day and installs signed updates (the EdDSA key in
// Info.plist, Blit's: the user's call). Rune › Check for Updates… checks now; Settings › General
// turns the daily check off. Only release builds run the updater, so Debug builds and a test
// run's copy never offer to replace themselves.

import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        // Sparkle's updater is main-thread only, so its changes come there; the first during this
        // init (`.initial`), hence the Task, not `Updates.shared` now.
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let can = MainActor.assumeIsolated { updater.canCheckForUpdates }
            Task { @MainActor in Updates.shared.canCheck = can }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkNow() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
