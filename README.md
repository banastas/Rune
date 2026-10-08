# Rune

A small, fast macOS text editor that never loses a keystroke between Macs. The second app in a family with Blit. Named Nib until 2026-10-07: the code, its folders and the bundle ID (`com.banastas.nib`) keep that name inside.

**[PRD.md](PRD.md)** is the living product document: what Rune is for, the sync design, milestones, measurements and decisions. **[CLAUDE.md](CLAUDE.md)** says where things stand.

**Status:** M2, the daily driver, is in use on two Macs as a notarized release; M3 (polish, Sparkle, the site, licensing) is under way.

## Layout

```
PRD.md                  the product document
nib.xcodeproj/          the Mac app (macOS 27, SwiftUI + AppKit), scheme nib; nib/ is a folder-synced group
nib/                    app sources: NibApp, Model/, Views/, Theme/, Vendor/FromBlit/, Resources/
NibKit/                 the engine (Swift package): NibText, NibSync, NibSyntax, the rune command (nib-cli), tests
themes/                 An Old Hope · Rune (.tmTheme), the built-in scheme
fidelity/               highlighting compared with Sublime Text's
qa/                     the QA and UX review, and the name's
scripts/                the scenario suite, the two-Mac test, release.sh, install-nib.sh, …
spike/                  M0's probes and their results
```

## Build and check

Needs Xcode 27. If `xcode-select -p` shows the Command Line Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (as the scripts do).

```bash
scripts/run-m1-scenarios.sh     # NibKit tests, a Debug build, and every single-Mac scenario
INSTALL=1 scripts/release.sh    # Developer ID, notarized and stapled, into /Applications/Rune.app
```

Or open `nib.xcodeproj` and run the **nib** scheme. A test run's copy (`-NibScenario`) opens only test files, in `iCloud Drive/Rune/Test/`.

## Fonts

Silkscreen and VT323 (SIL Open Font License 1.1), bundled in `nib/Resources/Fonts/` with their licenses, as in Blit.
