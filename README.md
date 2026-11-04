# Rune

A small, fast macOS text editor that never loses a keystroke between Macs. The second app in a family with Blit. Named Nib until 2026-10-07: the code, its folders and the bundle ID (`com.banastas.nib`) keep that name inside.

**[PRD.md](PRD.md)** is the living product document: what Rune is for, the sync design, milestones, measurements and decisions. **[CLAUDE.md](CLAUDE.md)** says where things stand.

Rune is free and open source, under the [MIT License](LICENSE). The signed, notarized build, with updates, is at **[rune.banast.as](https://rune.banast.as)**: pay what you want for it. Everything works either way, with no trial and no key.

**Status:** released (1.2.3, 2026-11-01), in daily use on two Macs.

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

### Building it without our Apple team

The project is signed with our team (`F87BNUZAVJ`) and Rune's iCloud container, `iCloud.com.banastas.nib`, which only our team can use. Without them, build ad hoc:

```bash
scripts/build-nib.sh adhoc                  # build/DerivedData/Build/Products/Debug/Rune.app
SIGN=adhoc scripts/run-m1-scenarios.sh      # the tests and scenarios, without an Apple account
```

An ad-hoc build can't carry the iCloud entitlement, so it has no `iCloud Drive/Rune/` folder: its scratch file starts in `iCloud Drive/nib-spike/` (choose another in Settings › Sync). For a container of your own, change `iCloud.com.banastas.nib` in `Support/nib.entitlements` and `ScratchLocation.containerID`, the team in `nib.xcodeproj`, and the bundle ID (`com.banastas.nib`), so your copy and ours don't share settings. Sparkle checks `rune.banast.as` for updates only in Release builds; point `SUFeedURL` in `Support/Info.plist` elsewhere, or leave it off, in a copy of your own.

[PRD.md](PRD.md) explains how sync works and why (§4), and §8 records what iCloud did along the way: the rules in [CLAUDE.md](CLAUDE.md) under "Sync" were all found the hard way.

## Removing Rune

Rune pauses iCloud's syncing of a file while it has it open, and only Rune can resume it. Quit Rune before removing it: quitting hands every file back to iCloud. If it was removed while running, or after a crash, a file can stay paused on that Mac (iCloud neither uploads nor downloads it there): install Rune again, open it once, and quit (PRD §4.9, rows 14a and 14b).

## Fonts

Silkscreen and VT323 (SIL Open Font License 1.1), bundled in `nib/Resources/Fonts/` with their licenses, as in Blit.

## License

Rune is © 2026 Bill Anastas, under the [MIT License](LICENSE). It's built with tree-sitter and its grammars, swift-tree-sitter and Sparkle, and ships the An Old Hope color scheme and the Silkscreen and VT323 fonts, each under its own license: [NibKit/Vendor/README.md](NibKit/Vendor/README.md), and About › Acknowledgements in the app.
