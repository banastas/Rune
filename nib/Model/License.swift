// The 7-day trial and licenses (PRD DS4). From Blit's `Blit/Model/License.swift`
// (`/Volumes/Photography/_GitHub/blit`, `43f1308`), Rune's own since: a trial of seven days from
// the first launch on each Mac, then a Lemon Squeezy key, activated per Mac through Lemon
// Squeezy's public license API (no server of Rune's), 3 Macs a key, checked again weekly, and
// licensed for 30 days more when the API can't be reached. The rules themselves are NibText's
// `Licensing`, tested there.
//
// Where Blit locks starting transfers, Rune locks new text: typing, pasting and what else adds
// text (⌘N, Append to Scratch, `cmd | rune`, `rune -w`), and Clean Clipboard and Clean Text. Never
// what keeps or recovers text: saving and uploading what's typed, the journal, other Macs'
// versions and merges, resolving conflicts, History and Revert To, Reopen Closed File, Save…,
// opening, copying, find, Rename… and Move To…. And never mid-sentence: the lock waits for a
// minute without typing. The text view's `isEditable` is the lock (`Editor.setEditable`), and
// Rune's own changes go through it (`Editor.allowingEdits`).
//
// Off until launch (`LicenseConfig.enforced`): no trial clock, no Keychain, no License tab or
// menu items, nothing locked. `-NibLicensing YES` turns it on in a Debug build, to try it; a test
// run's Nib keeps the trial and license in memory, never the Mac's.

import AppKit
import Foundation
import NibSync
import NibText
import Observation
import Security

enum LicenseConfig {
    /// Off until launch. Turning it on starts each Mac's trial at its next launch.
    static let enforced = false
    /// Lemon Squeezy's store (`banastas.lemonsqueezy.com`, `blit.` until 2026-10-08; Blit's and
    /// Rune's) and Rune's product (2026-10-08, test mode so far):
    /// a key from any other store or product is refused (`Licensing.mismatch`). The product's one
    /// variant is 2_223_174; a live copy of a test-mode product gets IDs of its own.
    static let storeID: Int? = 484_060
    static let productID: Int? = 1_423_364
    /// Test-mode keys (bought with test cards) only unlock Debug builds.
    static var acceptsTestKeys: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    /// Where Buy Rune… goes: the product's Lemon Squeezy checkout.
    static let buyURL = URL(string: "https://banastas.lemonsqueezy.com/checkout/buy/ff20f57a-cce0-455f-85b4-afd7eaa6f89f")!
    static let api = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!
}

/// What's kept about an activated key.
struct StoredLicense: Codable, Equatable {
    var key: String
    var instanceID: String
    var email: String?
    var name: String?
    var lastValidated: Date
}

/// The Keychain in the app; memory in a test run, so it can't touch the Mac's trial or license.
@MainActor
protocol LicenseStorage {
    func read(_ account: String) -> Data?
    func write(_ data: Data?, _ account: String)
}

@MainActor
final class KeychainLicenseStorage: LicenseStorage {
    private let service = "Rune License"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    func write(_ data: Data?, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return }
        var q = query(account)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}

@MainActor
final class MemoryLicenseStorage: LicenseStorage {
    var items: [String: Data] = [:]
    func read(_ account: String) -> Data? { items[account] }
    func write(_ data: Data?, _ account: String) { items[account] = data }
}

@MainActor
@Observable
final class LicenseManager {
    static let shared = LicenseManager(storage: NibPaths.isScenario ? MemoryLicenseStorage() : KeychainLicenseStorage())

    private(set) var state: Licensing.State = .trial(daysLeft: Licensing.trialDays)
    /// New text is refused: the trial over (or the key revoked) and a minute without typing.
    private(set) var typingLocked = false
    private(set) var isWorking = false
    @ObservationIgnored let storage: LicenseStorage
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var lastTyping: Date?
    /// One-shot timers only, while licensing is on: the trial's end and the lock's minute (§6.5:
    /// no timers while nothing happens).
    @ObservationIgnored private var trialEndTimer: Timer?
    @ObservationIgnored private var lockTimer: Timer?

    init(storage: LicenseStorage) {
        self.storage = storage
    }

    /// Whether licensing is in effect: at launch, or with `-NibLicensing YES` in a Debug build
    /// (a test run's `license` scenario passes it).
    var isEnforced: Bool {
        #if DEBUG
        LicenseConfig.enforced || UserDefaults.standard.bool(forKey: "NibLicensing")
        #else
        LicenseConfig.enforced
        #endif
    }

    var license: StoredLicense? {
        storage.read("license").flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) }
    }

    /// When the trial began: the first launch that looked (kept in the Keychain, so reinstalling
    /// doesn't restart it).
    var trialStart: Date {
        if let data = storage.read("trial-start"), let seconds = Double(String(decoding: data, as: UTF8.self)) {
            return Date(timeIntervalSince1970: seconds)
        }
        let start = now()
        storage.write(Data(String(start.timeIntervalSince1970).utf8), "trial-start")
        return start
    }

    /// At launch, coming forward, and after anything that changes the license.
    func refresh() {
        guard isEnforced else { return }
        if let license {
            state = Licensing.licensedState(email: license.email, lastValidated: license.lastValidated, now: now())
        } else if case .revoked = state {
            // Revoked by the store this session: it stays so until a key is entered.
        } else {
            state = Licensing.trialState(start: trialStart, now: now())
        }
        trialEndTimer?.invalidate()
        trialEndTimer = nil
        if case .trial = state, license == nil {
            let end = Licensing.trialEnd(start: trialStart)
            trialEndTimer = oneShot(at: end) { $0.refresh() }
        }
        scheduleLock()
    }

    /// Typing (any change to an editor's text): the lock waits for a minute after it.
    func noteTyping() {
        guard isEnforced else { return }
        lastTyping = now()
        if !state.allowsTyping, !typingLocked { scheduleLock() }
    }

    private func scheduleLock() {
        lockTimer?.invalidate()
        lockTimer = nil
        guard let when = Licensing.lockTime(state: state, lastTyping: lastTyping, now: now()) else {
            setLocked(false)
            return
        }
        if when <= now() {
            setLocked(true)
        } else {
            lockTimer = oneShot(at: when) { $0.scheduleLock() }
        }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != typingLocked else { return }
        typingLocked = locked
        for document in Documents.all { document.editor.applyEditable() }
    }

    private func oneShot(at date: Date, _ action: @escaping @MainActor (LicenseManager) -> Void) -> Timer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Lemon Squeezy

    struct APIResponse: Decodable {
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var license_key: Key?
        var instance: Instance?
        var meta: Meta?
        struct Key: Decodable { var status: String?; var key: String?; var test_mode: Bool? }
        struct Instance: Decodable { var id: String }
        struct Meta: Decodable {
            var store_id: Int?
            var product_id: Int?
            var customer_name: String?
            var customer_email: String?
        }
    }

    /// Why a response isn't a usable Rune license, or nil if it is.
    static func mismatch(_ response: APIResponse) -> String? {
        Licensing.mismatch(storeID: LicenseConfig.storeID, productID: LicenseConfig.productID,
                           store: response.meta?.store_id, product: response.meta?.product_id,
                           testMode: response.license_key?.test_mode == true, acceptsTestKeys: LicenseConfig.acceptsTestKeys)
    }

    private func call(_ endpoint: String, _ fields: [String: String]) async throws -> APIResponse {
        var request = URLRequest(url: LicenseConfig.api.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(APIResponse.self, from: data)
    }

    private static func unreachable(_ error: Error) -> String {
        "Couldn't reach Lemon Squeezy (\(Spoken.sentence(ErrorWords.hud(error)).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()))."
    }

    /// Activates `key` on this Mac. A problem to show, or nil once it's activated.
    func activate(_ rawKey: String, instanceName: String? = nil) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter your license key." }
        isWorking = true
        defer { isWorking = false }
        let name = instanceName ?? Host.current().localizedName ?? "Mac"
        do {
            let response = try await call("activate", ["license_key": key, "instance_name": name])
            guard response.activated == true, let instance = response.instance else {
                return Licensing.explain(response.error)
            }
            if let problem = Self.mismatch(response) {
                _ = try? await call("deactivate", ["license_key": key, "instance_id": instance.id])
                return problem
            }
            let stored = StoredLicense(key: key, instanceID: instance.id, email: response.meta?.customer_email,
                                       name: response.meta?.customer_name, lastValidated: now())
            storage.write(try? JSONEncoder().encode(stored), "license")
            state = .licensed(email: stored.email)
            refresh()
            return nil
        } catch {
            return Self.unreachable(error) + " Check your connection and try again."
        }
    }

    /// Frees this Mac's activation, to use the key on another Mac. This Mac goes back to its
    /// trial as it stands (over, most likely).
    func deactivate() async -> String? {
        guard let license else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await call("deactivate", ["license_key": license.key, "instance_id": license.instanceID])
            if response.deactivated != true, let error = response.error { return Licensing.explain(error) }
        } catch {
            return Self.unreachable(error) + " Try again when you're online."
        }
        storage.write(nil, "license")
        state = Licensing.trialState(start: trialStart, now: now())
        refresh()
        return nil
    }

    /// The weekly check of an activated key. Offline is fine within the grace (`refresh`); only
    /// Lemon Squeezy saying the key is no longer valid revokes it.
    func revalidateIfDue() async {
        guard isEnforced, var license, Licensing.revalidationDue(lastValidated: license.lastValidated, now: now()) else { return }
        guard let response = try? await call("validate", ["license_key": license.key, "instance_id": license.instanceID]) else {
            refresh()   // offline or the API down: licensed within the grace
            return
        }
        if response.valid == true, Self.mismatch(response) == nil {
            license.lastValidated = now()
            storage.write(try? JSONEncoder().encode(license), "license")
            state = .licensed(email: license.email)
        } else {
            storage.write(nil, "license")
            state = .revoked(Licensing.explain(response.error ?? "The license is no longer active."))
        }
        refresh()
    }

    // MARK: Words

    /// For the strip while locked.
    var stripLine: String {
        switch state {
        case .revoked: "READ-ONLY · THE LICENSE ISN'T ACTIVE · SETTINGS › LICENSE"
        default: "READ-ONLY · THE TRIAL HAS ENDED · BUY RUNE OR ENTER A LICENSE"
        }
    }

    /// Why something that adds text was refused, in the HUD's words (a toast, the strip).
    var refusedHUD: String { "✕ RUNE IS READ-ONLY · " + (state == .trialEnded ? "THE TRIAL HAS ENDED" : "THE LICENSE ISN'T ACTIVE") }

    /// The same as a sentence, for the `rune` command, Services and Shortcuts.
    var refusedSentence: String {
        (state == .trialEnded ? "Rune's \(Licensing.trialDays)-day trial has ended" : "Rune's license isn't active")
            + ", so it's read-only: buy Rune or enter a license in Settings › License. Saving, sync and History go on."
    }

    var summary: String {
        switch state {
        case .trial(let days): "Trial: \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded: "The trial has ended"
        case .licensed(let email): email.map { "Licensed to \($0)" } ?? "Licensed"
        case .revoked(let why): why
        }
    }

    func openBuyPage() { NSWorkspace.shared.open(LicenseConfig.buyURL) }

    /// Settings › License.
    func openLicenseSettings() {
        NibDefaults.store.set("license", forKey: "settingsTab")
        AppDelegate.openSettings()
    }

    #if DEBUG
    /// For the `license` scenario: the trial's start moved, the license set or cleared, the
    /// lock's minute passed, without waiting days or a minute.
    func testSet(trialStartedDaysAgo days: Double? = nil, license stored: StoredLicense?? = nil, quietFor seconds: Double? = nil) {
        if let days { storage.write(Data(String(now().addingTimeInterval(-days * 86_400).timeIntervalSince1970).utf8), "trial-start") }
        if let stored { storage.write(stored.flatMap { try? JSONEncoder().encode($0) }, "license") }
        if let seconds { lastTyping = now().addingTimeInterval(-seconds) }
        if stored != nil, case .revoked = state { state = .trialEnded }   // a key entered or cleared ends a revocation
        refresh()
    }
    #endif
}
