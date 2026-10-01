// Nib's settings, and the test harness's kept apart from them (2026-10-01). The Nib in daily use
// keeps its settings in the Mac's own defaults for com.banastas.nib; a scenario's Nib (launched
// with -NibScenario by the suite, the two-Mac test or run-perf.sh) keeps its own in
// com.banastas.nib.scenarios, as it keeps its journal, History and lists in a folder of its own
// (`NibPaths.support`). So a test run never leaves the user's Nib changed: uploads held, the
// menu bar extra off, test files in Open Recent. Launch arguments (-NibMarker…) and registered
// defaults are seen through either store.

import Foundation
import NibSync

enum NibDefaults {
    /// (UserDefaults is thread-safe, as Apple documents it, but not marked Sendable.)
    nonisolated(unsafe) static let store: UserDefaults = NibPaths.isScenario ? UserDefaults(suiteName: "com.banastas.nib.scenarios") ?? .standard : .standard

    /// The scenario this launch runs (-NibScenario), if any.
    static var scenario: String? { store.string(forKey: "NibScenario") }
}
