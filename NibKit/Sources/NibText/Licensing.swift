// The trial and licenses' rules (PRD DS4), apart from the Keychain and Lemon Squeezy so they can
// be tested: seven days from the first launch on each Mac, then read-only until a license; a key
// checked again weekly, licensed for 30 days more when Lemon Squeezy can't be reached; the lock
// never mid-sentence, only after a minute without typing. From Blit's `License.swift`
// (`../blit/Blit/Model/License.swift`, `43f1308`), its pure parts; Rune's own since. The app's
// `LicenseManager` keeps the state and asks.

import Foundation

public enum Licensing {
    public static let trialDays = 7
    public static let revalidateEvery: TimeInterval = 7 * 86_400
    public static let offlineGrace: TimeInterval = 30 * 86_400
    /// The lock waits for this long without typing (DS4: never mid-sentence).
    public static let quietBeforeLock: TimeInterval = 60

    public enum State: Equatable, Sendable {
        case trial(daysLeft: Int)
        case trialEnded
        case licensed(email: String?)
        /// A key the store no longer accepts (refunded, disabled, deactivated elsewhere), or one
        /// not checked for over a month: locks as the end of the trial does.
        case revoked(String)

        /// Whether new text may come in.
        public var allowsTyping: Bool {
            switch self {
            case .trial, .licensed: true
            case .trialEnded, .revoked: false
            }
        }
    }

    /// The trial as of `now`: whole days since `start`, so day 1 is the first launch's day and
    /// the eighth begins seven days (to the second) after it. A clock set back counts nothing.
    public static func trialState(start: Date, now: Date, days: Int = trialDays) -> State {
        let elapsed = Int(max(0, now.timeIntervalSince(start)) / 86_400)
        let left = days - elapsed
        return left > 0 ? .trial(daysLeft: left) : .trialEnded
    }

    /// When the trial ends: the moment `trialState` turns `.trialEnded`.
    public static func trialEnd(start: Date, days: Int = trialDays) -> Date {
        start.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// An activated key as of `now`: licensed while it was checked within the week and the grace
    /// after it; past that, revoked until a check gets through (the key itself is kept).
    public static func licensedState(email: String?, lastValidated: Date, now: Date) -> State {
        now.timeIntervalSince(lastValidated) > revalidateEvery + offlineGrace
            ? .revoked("Rune hasn't been able to check your license for over a month. Connect to the internet and it checks again.")
            : .licensed(email: email)
    }

    /// Whether a key is due its weekly check.
    public static func revalidationDue(lastValidated: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastValidated) >= revalidateEvery
    }

    /// When the lock comes for `state`: nil while typing is allowed; otherwise a minute after the
    /// last typing (now, if that's past or there was none).
    public static func lockTime(state: State, lastTyping: Date?, now: Date) -> Date? {
        guard !state.allowsTyping else { return nil }
        guard let lastTyping else { return now }
        return max(now, lastTyping.addingTimeInterval(quietBeforeLock))
    }

    /// Why a key Lemon Squeezy activated isn't Rune's, or nil if it is: from Rune's store and one
    /// of `wantedProducts` (the live product, and in a Debug build the test-mode one, which has IDs
    /// of its own). With no product (before Rune is on sale) no key is: any store's would pass.
    public static func mismatch(storeID wantedStore: Int?, productIDs wantedProducts: Set<Int>,
                                store: Int?, product: Int?, testMode: Bool, acceptsTestKeys: Bool) -> String? {
        if testMode, !acceptsTestKeys { return "This is a test key; it can't unlock Rune." }
        guard !wantedProducts.isEmpty else { return "Rune isn't on sale yet, so no key unlocks it." }
        if let wantedStore, store != wantedStore { return "This key isn't for Rune." }
        guard let product, wantedProducts.contains(product) else { return "This key isn't for Rune." }
        return nil
    }

    /// Lemon Squeezy's messages, said plainly.
    public static func explain(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return "The key couldn't be activated." }
        let e = error.lowercased()
        // This Mac's activation, not the key: removed in the store's dashboard, say ("instance_id
        // not found."). It said the key wasn't found, and to check it against the receipt.
        if e.contains("instance") && e.contains("not found") { return "This Mac's activation isn't on the license any more. Enter the key again in Settings › License." }
        if e.contains("not found") { return "That license key wasn't found. Check it against your receipt email." }
        if e.contains("activation limit") { return "This key is already active on 3 Macs. Deactivate it on one of them first (Settings › License)." }
        if e.contains("disabled") || e.contains("expired") { return "This license key is no longer active." }
        return error
    }
}
