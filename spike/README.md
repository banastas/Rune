# nib M0 spikes

Throwaway code that answers M0's questions. **S1** (`nib-spike`): what iCloud Drive actually does for a plain file on macOS 27, and whether macOS 26's sync controls (pause, upload now, fetch latest) work for nib's scratch file. **S2** (`nib-textspike`, `nib-launch-appkit`, `nib-launch-swiftui`): TextKit 1 vs TextKit 2 at scratch sizes, and what the SwiftUI lifecycle costs at launch. Results and conclusions are in the [PRD](../PRD.md#m0-results).

This isn't the sync engine. M1 writes that properly.

**Safety:** every mode refuses paths outside `iCloud Drive/nib-spike/` and uses generated text. Nothing here opens the live scratch file (PRD §8).

## Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
scripts/bundle.sh      # wraps it in NibSpike.app, ad-hoc signed
```

The sync controls need an app identity: from a bare command-line binary, `pauseSync` and `uploadLocalVersion` fail with "feature not supported". Run the binary inside the bundle: `.build/NibSpike.app/Contents/MacOS/nib-spike`.

## Modes

```bash
B=.build/NibSpike.app/Contents/MacOS/nib-spike

$B status                                    # iCloud state, flags, xattrs of every spike file
$B upload   --size 200k                      # write, time until iCloud reports it uploaded
$B typing   --size 200k --every 1 --count 15 # plain saves every second: does upload keep up?
$B push-typing --size 200k --every 1 --count 20 --upload-every 3   # paused, in-place saves, upload now
$B controls --size 200k --write inplace      # pause, save (inplace|replace|atomic), upload now, fetch, resume
$B evict    --size 200k                      # xattrs, eviction, reading a dataless file, download
$B presenter --size 20k                      # NSFilePresenter and folder events for three kinds of change
$B metadata                                  # NSMetadataQuery scopes without an iCloud entitlement
$B writer   --every 5 --count 24 --mode plain|push   # two Macs, Mac A: writes latency.md
$B reader   --seconds 150 --fetch-every 0            # two Macs, Mac B: logs arrival latency
$B cleanup                                   # resumes sync on anything left paused
```

Pausing survives a crash, so run `cleanup` after an interrupted run.

## S2

```bash
T=.build/release/nib-textspike
$T --engine tk1|tk2 --size 197k|2.4m --keys 300 --highlight none|window [--full-layout yes]
.build/release/nib-launch-appkit      # prints first-window time and idle memory, then quits
.build/release/nib-launch-swiftui
```

The text spike's window sits on screen at 1% opacity and never becomes key, so it draws at Retina scale without taking focus.

## Runners

- `run-s1.sh`: every single-Mac mode, output to `results/`.
- Two Macs (still to do, S1b): see the PRD's M0 results for the steps.
