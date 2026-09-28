# nib: notes for Claude Code sessions

Read **PRD.md** first. It's the living product document, as Blit's README is for Blit: Family DNA (§0), the sync design (§4), measurements and decisions (§8 "M0 results" and "M1 progress"). Code comments cite its IDs (SC1, SY3, A17, §4.3…).

## Where things stand (2026-09-28)

M1, the weekend MVP, works on one Mac and between two (MacBook Air `Bill's MacBook Air` and Mac mini `m2pr0m4cm1n1`, both macOS 27), team-signed, in nib's own iCloud folder: `iCloud Drive/nib/`, container `iCloud.com.banastas.nib` (§4.2; `Support/nib.entitlements`, `Support/Info.plist`). Both Macs are registered to the team, each with its own Apple Development certificate. The single-Mac suite passes on both; the seventh two-Mac run (13:35) passed on both, with the same SHA-256, after a fix for a version merged twice in the sixth (PRD §8). Open, in order:

1. By hand: lid closed right after a save; both Macs offline; ⌥Space, the strip, ⌘W. The window subtitle shows the container's raw path, not "iCloud Drive › nib › Test" (`ScratchView.subtitle` knows only iCloud Drive's own folder).
2. A day on both Macs with the test file; then move `iCloud Drive/_scratch2.md` to `iCloud Drive/nib/scratch.md` and set `allowLiveScratch`.
3. M2 (§8): three-way merge, files and tabs, tree-sitter highlighting, the S3 fidelity harness (a small Sublime plugin in `Packages/User`; the user has OK'd it), the shared package (§7).

## Rules that are settled (don't relitigate)

- **Safety rule (§8):** until M1 has passed, nib opens only test files (`iCloud Drive/nib/Test/`, or `iCloud Drive/nib-spike/` in ad-hoc builds). Never read the contents of the user's real scratch files (`_scratch*.md` in iCloud Drive); spikes use generated text.
- **Sync (§4.3, §4.4, found the hard way, see M0/M1 results):** hold the file (pause sync) while open; save **in place**, never by renaming a temp file (that drops the pause); upload now with fail-on-conflict; **never resume with `.preserveLocalChanges`**; a buffer may be replaced only when nothing is unsent (`Document.unsent`); iCloud's "current" and `fetchLatestRemoteVersion` can't be trusted for a held file, so the unpaused note (`Announcement`) plus a forced refresh (evict and download) decide; every iCloud call has a time limit (`CloudControl.within`).
- **Editor:** TextKit 2; nothing may touch `layoutManager` (it silently switches to TextKit 1).
- **Look and voice:** dark only (A17); Blit's HUD language for the strip (uppercase, middle dots, glyph and word, one muted red for problems); plain, literal copy (W1-W8). Blit's HUD pieces are copied into `nib/Vendor/FromBlit/` until the shared package exists.
- **Name:** `nib`, lowercase; bundle ID `com.banastas.nib`.

## Working with the user

- The user commits and pushes; don't commit unless asked. Other Macs get changes by `git pull` on branch `m0-spikes`.
- Two-Mac runs are coordinated by a shared start time: this session runs one role in the background, the user runs the other on the other Mac and pastes its summary.
- Anything that changes the user's Apple developer account, certificates or other accounts is the user's step; explain it and hand them the command.
- Use they/them for the user.

## Build and check

Xcode 27. `xcode-select` may point at the Command Line Tools, so prefix builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the scripts do).

```bash
scripts/run-m1-scenarios.sh                 # NibKit tests + every single-Mac scenario (about a minute)
SIGN=adhoc scripts/run-m1-scenarios.sh      # without the Apple account: no iCloud folder, tests in nib-spike/
scripts/run-m1-two-mac.sh a|b HH:MM         # the two-Mac test; same start time on both Macs
spike/run-s1b.sh a|b HH:MM [part2]          # M0 iCloud probes on two Macs
cd NibKit && swift test                     # the engine alone
```

A Mac new to the team has to be registered as a device once, or team-signed builds stop at "Device … isn't registered in your developer account". That changes the user's developer account, so it's their step:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData -destination "platform=macOS" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

Scenario logs are in `build/scenarios/`; nib's own Sync Log is `~/Library/Application Support/nib/sync.jsonl`.
