# nib

A small, fast macOS text editor that never loses a keystroke between Macs. The second app in a family with Blit.

**[PRD.md](PRD.md)** is the living product document: what nib is for, the sync design, milestones, measurements and decisions.

**Status:** M1 (weekend MVP) in progress. The scratch window and the sync pipeline work on one Mac, against a test file in `iCloud Drive/nib-spike/` only; the two-Mac checks are next.

## Layout

```
PRD.md                  the product document
nib.xcodeproj/          the Mac app (macOS 27, SwiftUI + AppKit); nib/ is a folder-synced group
nib/                    app sources: NibApp, Model/, Views/, Theme/, Vendor/FromBlit/, Resources/Fonts/
NibKit/                 the engine (Swift package): NibText, NibSync, tests
themes/                 An Old Hope · nib (.tmTheme), the built-in scheme
spike/                  M0 throwaway probes (iCloud sync controls, TextKit) and their results
scripts/                run-m1-scenarios.sh
```

## Build and check

Needs Xcode 27. If `xcode-select -p` shows the Command Line Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (as the scripts do).

```bash
scripts/run-m1-scenarios.sh     # NibKit tests, a Debug build, and every M1 scenario (about a minute)
```

Or open `nib.xcodeproj` and run the **nib** scheme. Until M1 has passed on both Macs, nib opens only `iCloud Drive/nib-spike/scratch-test.md`.

## Fonts

Silkscreen and VT323 (SIL Open Font License 1.1), bundled in `nib/Resources/Fonts/` with their licenses, as in Blit.
