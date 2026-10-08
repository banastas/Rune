// The trial and licenses' rules (PRD DS4): seven days, the weekly check and its month of grace,
// the lock only after a minute without typing, keys that aren't Rune's.

import Foundation
import Testing

@testable import NibText

@Suite struct LicensingTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    @Test func sevenDays() {
        #expect(Licensing.trialState(start: start, now: start) == .trial(daysLeft: 7), "the first launch's day")
        #expect(Licensing.trialState(start: start, now: day(6.99)) == .trial(daysLeft: 1), "the seventh day")
        #expect(Licensing.trialState(start: start, now: day(7)) == .trialEnded, "the eighth begins seven days after")
        #expect(Licensing.trialState(start: start, now: day(-3)) == .trial(daysLeft: 7), "a clock set back counts nothing")
        #expect(Licensing.trialEnd(start: start) == day(7))
    }

    @Test func weeklyCheckAndGrace() {
        let checked = start
        #expect(!Licensing.revalidationDue(lastValidated: checked, now: day(6.9)))
        #expect(Licensing.revalidationDue(lastValidated: checked, now: day(7)))
        #expect(Licensing.licensedState(email: "a@b.c", lastValidated: checked, now: day(37)) == .licensed(email: "a@b.c"),
                "a week and the 30 days' grace: still licensed offline")
        if case .revoked = Licensing.licensedState(email: nil, lastValidated: checked, now: day(37.01)) {} else {
            Issue.record("unchecked for over a month: locked until a check gets through")
        }
    }

    @Test func neverMidSentence() {
        let now = day(8)
        #expect(Licensing.lockTime(state: .trial(daysLeft: 2), lastTyping: now, now: now) == nil, "typing allowed: no lock")
        #expect(Licensing.lockTime(state: .licensed(email: nil), lastTyping: nil, now: now) == nil)
        #expect(Licensing.lockTime(state: .trialEnded, lastTyping: nil, now: now) == now, "nothing typed: at once")
        #expect(Licensing.lockTime(state: .trialEnded, lastTyping: now.addingTimeInterval(-20), now: now) == now.addingTimeInterval(40),
                "typed 20 s ago: a minute after it")
        #expect(Licensing.lockTime(state: .revoked("x"), lastTyping: now.addingTimeInterval(-300), now: now) == now, "quiet for long: at once")
        #expect(!Licensing.State.trialEnded.allowsTyping && !Licensing.State.revoked("x").allowsTyping)
    }

    @Test func onlyRunesKeys() {
        func check(store: Int? = 1, product: Int? = 2, test: Bool = false, acceptsTest: Bool = false, wantedProducts: Set<Int> = [2]) -> String? {
            Licensing.mismatch(storeID: 1, productIDs: wantedProducts, store: store, product: product, testMode: test, acceptsTestKeys: acceptsTest)
        }
        #expect(check() == nil, "Rune's store and product")
        #expect(check(product: 3) != nil, "another product (Blit's, say)")
        #expect(check(store: 9) != nil, "another store")
        #expect(check(test: true) != nil, "a test key in a released copy")
        #expect(check(test: true, acceptsTest: true) == nil, "a test key in a Debug build")
        #expect(check(wantedProducts: []) != nil, "no product yet: no key unlocks Rune")
        #expect(check(product: 3, test: true, acceptsTest: true, wantedProducts: [2, 3]) == nil, "the test-mode product's key, in a Debug build")
        #expect(check(product: nil) != nil, "no product in the answer")
    }

    @Test func plainWords() {
        #expect(Licensing.explain("license_key not found.").hasPrefix("That license key wasn't found"))
        #expect(Licensing.explain("This license key has reached the activation limit.").contains("3 Macs"))
        #expect(Licensing.explain("license_key is disabled.") == "This license key is no longer active.")
        #expect(Licensing.explain(nil) == "The key couldn't be activated.")
        #expect(Licensing.explain("Something new.") == "Something new.", "anything else as Lemon Squeezy says it")
    }
}
