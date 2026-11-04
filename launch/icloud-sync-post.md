<!--
Draft, 2026-11-04. Every claim carries the PRD section it comes from, in [brackets], for
checking; take them out before publishing (or turn the useful ones into links to PRD.md on
GitHub). Things for you to decide are marked TODO.
-->

# Holding the file: making iCloud Drive safe for a text editor

Rune is a small text editor for the Mac. Its main job is one scratch file in iCloud Drive that my two Macs share: I write on the laptop, sit down at the desk, and the text is there. It saves as I type, and edits from two Macs are merged, never overwritten.

That sounds like what iCloud Drive already does. It mostly does, until you look closely. This post is what I found when I looked closely: what iCloud Drive does with a file while an editor has it open, on macOS 27, and what Rune does about each thing. All of it was measured, and Rune's source is now public under the MIT License, so you can check it: the design is in `PRD.md` §4, and §8 is the full record, failures included.

## What Rune promises

Three things, in this order [PRD §4.1]:

1. **Durability.** Every edit is in a recovery journal on this Mac's disk within 300 ms, and in the file within 1 s of a pause. A crash or a kernel panic loses at most the last 300 ms.
2. **No silent loss.** No text that any Mac wrote is ever dropped without you seeing it. Every divergence is merged or shown.
3. **Honest freshness.** Rune says how current its copy is, and asks iCloud instead of waiting for it.

The first is ordinary engineering. The second and third are where iCloud comes in.

## iCloud on its own never uploads while you type

The first test was the plain one: save a 200 KB file once a second, as an editor saving while you type would, and watch iCloud [PRD §8, M0 results, S1].

A single save was uploaded in 2.7-4.1 s. Saves every second were **never uploaded while typing went on**: each save restarted the upload, and the last one finished 6.1 s after typing stopped. Between two Macs, with a save every 5 s, iCloud on its own got each version across in 3.6 s at the median and 6.2 s at the 95th percentile [PRD §8, M0, S1b first run].

That's better than I expected, and it isn't the problem. The problem is the window: while you type, nothing leaves the Mac. Close the lid in that window, and the desk Mac has the old text.

## macOS 26's sync controls

macOS 26 added two controls to `FileManager` that change this [PRD §4.3]:

- **Pause:** `pauseSyncForUbiquitousItem` stops iCloud syncing one file on its own schedule.
- **Upload now:** `uploadLocalVersionOfUbiquitousItem(at:withConflictResolutionPolicy: .failOnConflict)` uploads this version now, and is refused if the server has a newer one.

They work for a plain file in iCloud Drive with no entitlement, from an app bundle; from a command-line binary they answer "feature not supported" [PRD §8, M0, S1].

So Rune **holds** a file while it's open: it pauses iCloud's syncing of it and decides itself when to upload (3 s after typing pauses, every 20 s while it goes on, and at once when you switch apps, lock the screen or the Mac sleeps) and when to fetch (when Rune comes forward, and every 30 s while it's in front) [PRD §4.3 step 7, §4.4].

Held, saving every second and uploading every few seconds, every upload succeeded, in 2.2-3.0 s for both 200 KB and 2.4 MB [PRD §8, M0, S1]. Between two Macs: **2.5 s at the median and 3.6 s at the 95th percentile**, from the write on one Mac to the text readable on the other, against 3.6 and 6.2 s [PRD §8, M0, S1b]. The upload is the slow part; once it returns, the other Mac has it in well under a second.

The refusal is the other half. If the server has a version this Mac hasn't seen, the upload fails with `localVersionConflictingWithServer` instead of making an iCloud conflict copy. Rune fetches the newer version, merges, saves and uploads again [PRD §4.3 step 7, §4.6]. On two Macs racing the same file, it worked as written: one upload accepted, the other refused, the refused Mac fetched the newer version, merged its line in, and the merged upload was accepted [PRD §8, M0, S1b second run]. For a held file, that refusal is where almost every conflict is found, before iCloud has made a conflict copy of anything [PRD §4.6].

What follows is everything that went wrong on the way.

## 1. Saving by renaming drops the hold

Editors usually save atomically: write a temp file, rename it over the original. On a paused file, that rename **makes a new file** (a new inode). The pause is gone, iCloud uploads on its own again, and both "upload now" and "resume" answer "not supported". File presenters see the rename as a deletion [PRD §8, M0, S1].

So Rune saves **in place**: it writes the bytes that differ, truncates, and fsyncs the same file, inside one `NSFileCoordinator` block that first checks the file on disk still matches the version the buffer came from [PRD §4.3 steps 4-5]. A write torn by a crash is what the journal is for, and the pause keeps a torn file from uploading meanwhile.

## 2. A held file can stay stale for good, while iCloud calls it current

This is the one that mattered most.

On two Macs, both holding the same file: Mac B merged and uploaded a three-line version, and both Macs resumed syncing, with `.preserveLocalChanges`. **Mac A kept its two-line copy for 26 minutes**, and would have kept it longer. iCloud called it current and uploaded. `fetchLatestRemoteVersionOfItem` answered in 7 ms with Mac A's own version. There was no conflict copy. Evicting and re-downloading by hand brought the three-line version: the server had had the merge all along [PRD §8, M0, S1b second run].

The next run tried the other resume modes. `.afterUploadWithFailOnConflict`: accepted, still stale. `.dropLocalChanges`: returned ok, file unchanged after 15 s. Fetching: "nothing newer", in 1 ms. Eviction and download: the right version, in 0.6 s [PRD §8, M0, S1b third run]. So: **a version that reaches the server while a Mac has the file paused is never applied on that Mac afterwards, and nothing iCloud says reveals it.** Files that aren't paused don't have the problem.

No text was lost, and a stale copy can't overwrite the newer one, because its next upload would be refused. But a promise of honest freshness can't rest on iCloud's "current".

What Rune does [PRD §8, M0, "What Nib does about it"; §4.4]:

- **A note that is never paused.** Every upload also rewrites a tiny file beside the scratch file, in a hidden `.nib` folder: the version's SHA-256, its parent, the Mac and the time. No Mac ever holds it, so it travels the way unpaused files do, in a few seconds, and its presenter fires when it arrives.
- **The note over iCloud's word.** When a Mac sees a note for a version it doesn't have, and has nothing unsent, it refreshes: takes the server's version, evicts the file, downloads it, holds it again. That took about 1-3 s. With unsent edits, it does nothing special: its next upload is refused, and the merge runs.
- **Never `.preserveLocalChanges`.** Apple's documentation says it "may automatically pick the winner". Rune resumes a file whose saves are all uploaded taking the server's version, and one with unsent saves with fail-on-conflict.

Eviction has its own catch: right after an upload, iCloud sometimes answers "cannot be evicted" (`-2008`, or `-2007`). Rune's own file presenter has to step aside during the eviction too, or it answers "busy". Rune retries with backoff, about 15 s in all [PRD §8, M1 progress, two-Mac test, fourth run; §8, M0, "Built"].

## 3. Pausing a file mid-upload crashes iCloud Drive

For a day, holds failed now and then with `Couldn't communicate with a helper application` (Cocoa 4097 or 4099), mostly on files a test had just created. Rune retried them in the background. Then a test run hung: a coordinated read of its file that was never granted.

`fileproviderd`, the process behind iCloud Drive, had crashed and didn't come back for 16 minutes. While it was gone, a coordinated read from any process waited without an answer: iCloud Drive was stopped for every app on the Mac, not only Rune. There were 36 crash reports, all the same: `-[FPDXPCServicer pauseSyncForItemAtURL:behavior:bundleID:completionHandler:]` building an array with a nil in it, on macOS 27.0.1. Matched against Rune's Sync Log, each came a second or two after Rune paused a file **iCloud was still uploading**. The "failed holds" had been the crash all along [PRD §8, M2 progress, "Nib's pauses were crashing iCloud's file provider"].

It's a macOS bug, but Rune's calls set it off. So a hold now **waits until iCloud has finished uploading the file**, checking every quarter second for up to 15 s. If iCloud is still uploading when the 15 s are up, Rune doesn't pause: the file runs unheld, and the hold is tried again 2, 5, 10, 20 and 40 s later, then every minute [PRD §4.3; §8, M2, `icloudoff`'s second hold]. It crashed twice more after the first fix, both times when a test wrote to the file just as the pause went in, so that iCloud began uploading again under it. Now a hold never pauses a file iCloud still says it's uploading, not even at the 15 s mark, and the tests write only once the file is held. No crash since [PRD §8, M2, `icloudoff`'s second hold; TODO: the PRD says so as of 2026-10-02, so check the crash reports before posting].

There's a trap on the other side. A **re-hold**, after Rune itself put a newer version in place, has to pause *at once*. The first version of the fix waited there too, and in those few unpaused seconds iCloud put the server's older copy back over Rune's newer save [PRD §8, M2, same entry]. Nothing was lost (the journal and History had it), but it's the opposite of what a hold is for.

> TODO: did you file this with Apple (Feedback Assistant)? If so, add the FB number; if it's fixed in a later 27.x, say which.

## 4. Every iCloud call needs a time limit

In a two-Mac test, both Macs uploaded within about 2 s of each other. One upload was accepted. **The other upload call never answered**: still "uploading" 35 s later. Rune had no time limit, so everything waiting behind that call stopped: the next upload, the fetch, the note check. That Mac never got its refusal, and the two Macs ended on different versions. Nothing was lost; each Mac had its own line [PRD §8, M1 progress, two-Mac test, third run].

Every sync call has a limit now: 15 s for an upload or a fetch, 20 s for a pause or a resume. iCloud's calls can't be cancelled, so the limit doesn't wait for the abandoned call. With no answer, the status line says `ICLOUD ISN'T ANSWERING · SAVED LOCALLY · RETRYING` and Rune tries again in 2 s; the retry is refused or accepted at once [same entry]. Later, the same went for questions that look harmless: asking iCloud for a file's state, or whether Rune's iCloud folder is there, can wait for minutes when iCloud's daemons are stuck, so they have limits too, and never run on the main thread [PRD §8, M2 progress, after `bigfile`].

## 5. What it costs the disk

macOS writes a report when an app writes more than 8 GiB a day, and the report it writes names one process. Rune's first report took a day to read right: macOS counts writes by **resource coalition**, an app with everything it starts, and the coalition it named was the one my builds and test runs belonged to, not the Rune I use [PRD §8, M2, "Disk writes"].

It still found real waste. A save wrote the whole file: 2.4 MB a save at the end of a 2.4 MB file. It writes only the bytes that differ now; the same 41 saves wrote 1 KB of the file. The journal wrote a whole snapshot at every pause; it logs edits now [same entry; PRD §4.3 steps 1, 5].

And iCloud's own daemons write far more than Rune does for each upload: while a test typed into a 223 KB file with an upload every 4-5 s, `bird`, `fileproviderd`, `nsurlsessiond` and `cloudd` wrote 122 MB in 70 s [same entry]. That's why Rune uploads every 20 s while you type, not every 3, and 3 s after you stop [PRD §4.3 step 7].

> TODO: optional. Cut this section if the post runs long; it's the least iCloud-specific.

## How it was tested

None of this came from reading documentation. It came from running the real app against a real iCloud folder, many times.

- **The scenarios.** A Debug build of Rune launched with `-NibScenario <name>` runs one scripted scenario against test files in its own iCloud folder: typing, saving, uploads, another app's version, a deletion, iCloud Drive turned off, a 2.4 MB file, and so on. It checks what happened and logs PASS or FAIL. It keeps its settings, journal and History apart from the copy I use, and it opens only test files [PRD §6.4; CLAUDE.md]. The suite is about 80 scenario runs and 590 checks, plus about 240 unit tests for the merge, the journal and the rest [today's suite, `build/scenarios/`].
- **Two Macs.** A MacBook Air and a Mac mini run the same script from a shared start time: one adds a line, the other has to show it; both add a line at the same moment, and both have to end with the same file, SHA-256 and all. It has run 29 times [PRD §8, "The twenty-ninth two-Mac run"]. Some runs failed in ways no single Mac would show: the upload that never answered, the eviction iCloud refused, a run where the two Macs ended with different files and the text doubled on both, with nothing lost [PRD §8, M2 progress, fourteenth run].

> TODO: today's suite (2026-11-04) didn't run clean: iCloud was slow to upload all morning, and HEAD's build failed the same checks. Worth a sentence here, or leave it out.

## What it still can't promise

A Mac that hasn't uploaded can't tell anyone anything. If you close the laptop lid within the 2-3 s of its upload, the desk Mac has the old text until the laptop wakes [PRD §4.1, §4.10]. What Rune promises then is that typing on the stale copy produces a merge, not a loss. Making that window smaller would need a second path between the Macs, on the local network or through CloudKit, and so far the numbers haven't called for it [PRD §4.10].

## The code

Rune is free and open source, under the MIT License: [github.com/banastas/Rune](https://github.com/banastas/Rune). The signed, notarized build is at [rune.banast.as](https://rune.banast.as); pay what you want for it.

The sync is in `NibKit/Sources/NibSync/` and `nib/Model/Document.swift`. `PRD.md` §4 is the design, and §8 is the full record of what iCloud did along the way, dated, with the numbers. If you're building on iCloud Drive's sync controls and see something different, I'd like to hear it.

> TODO: where to send people (an email, GitHub issues, Mastodon…).
