// The HUD's words for VoiceOver (PRD V4, AX1, AX2): no glyphs, commas for middle dots, keys
// named, capitals only where they belong.

import Testing

@testable import NibText

@Suite struct SpokenTests {
    @Test func notices() {
        #expect(Spoken.sentence("✓ MERGED 2 CHANGES FROM AIR · ⌘Z UNDOES") == "Merged 2 changes from air, Command-Z undoes")
        #expect(Spoken.sentence("✕ CONFLICT WITH AIR · 1 PLACE · BOTH VERSIONS ARE IN THE TEXT") == "Conflict with air, 1 place, both versions are in the text")
        #expect(Spoken.sentence("▼ UPDATED FROM AIR · 10:42:01") == "Updated from air, 10:42:01")
        #expect(Spoken.sentence("‖ A NEWER VERSION FROM ANOTHER MAC · CHECKING WHAT IT WAS MADE FROM, TO MERGE IT") == "A newer version from another Mac, checking what it was made from, to merge it")
        #expect(Spoken.sentence("NIB OPENS ONLY TEST FILES (ICLOUD DRIVE › NIB › TEST) UNTIL M1 HAS PASSED (PRD §8)")
                == "Nib opens only test files (iCloud Drive, Nib, test) until M1 has passed (PRD section 8)")
        #expect(Spoken.sentence("PASTE CLEAN ⌥⇧⌘V · ESCAPE ⎋") == "Paste clean Option-Shift-Command-V, escape ⎋")
        #expect(Spoken.sentence("") == "")
    }
}
