# Show HN draft

Draft for Hacker News, 2026-11-04, for the open-source release. As Blit's (`../blit/launch/show-hn.md`): HN wants specifics and distrusts marketing, so this leads with what was learned about iCloud Drive, not with adjectives. The long version is `launch/icloud-sync-post.md`; post that first, somewhere it can stay (TODO: where), and link it from the text below.

## Title

Pick one (80 characters at most; no "fastest" or "best"):

1. `Show HN: Rune – a Mac text editor that holds its file so iCloud can't lose edits` (80)
2. `Show HN: Rune – open-source Mac editor; what I learned about iCloud Drive sync` (78)
3. `Show HN: Rune – one scratch file on all my Macs, synced through iCloud Drive` (76)
4. `Show HN: Rune – a Mac editor built on macOS 26's iCloud sync controls` (69)

The second says the most to HN; the first is the most literal about what's different.

**URL:** https://github.com/banastas/Rune (the source, as HN prefers for open-source projects; the site is linked from the README)

## Text

> Hi HN. I keep one scratch file that I write in all day, on a laptop and a desktop. I wanted it on both Macs without thinking about it, and never to lose a line when I switch. iCloud Drive almost does this, so I built a small editor, Rune, around the parts it doesn't.
>
> What I found, measured on macOS 27 (the write-up has the numbers):
>
> - Saving once a second, iCloud never uploads while you type: each save restarts the upload. The last one finished 6 s after typing stopped.
> - macOS 26 added sync controls to FileManager: pause syncing a file, and upload now with fail-on-conflict. Rune holds the file while it's open and uploads itself. From a save on one Mac to the text on the other: 2.5 s median, 3.6 s p95 (iCloud alone: 3.6 and 6.2).
> - Save in place. An atomic save (temp file, rename) makes a new file, and the pause is silently gone.
> - A file that was paused while another Mac's version reached the server can stay stale for good. iCloud calls it current, `fetchLatestRemoteVersionOfItem` agrees in 7 ms, and no resume mode fixes it. Rune writes a small note beside the file that's never paused, and when a note names a version it doesn't have, it evicts and re-downloads.
> - On macOS 27.0.1, pausing a file while iCloud is still uploading it crashes `fileproviderd`, and iCloud Drive stops for every app on the Mac until it restarts (16 minutes, once). Rune waits for the upload to finish first.
> - An upload call can simply never answer, so every iCloud call has a time limit.
>
> The editor around it: TextKit 2, tree-sitter highlighting that matches Sublime Text's colors, a recovery journal (every keystroke on disk within 300 ms), three-way merges with conflict blocks when two Macs change the same lines, and local History. Swift 6, macOS 27, Apple silicon.
>
> It's MIT. The signed, notarized build at rune.banast.as is pay what you want; everything works without paying. The design doc in the repo (PRD.md §4, and §8 for every failure along the way) is probably the most useful part if you're building on iCloud Drive yourself.
>
> I'd like to hear from anyone who's used the sync controls: have you seen the stale-after-pause behavior, or the crash on a later 27.x?

## Before posting

- [ ] The repository is public (the site's price section links to it).
- [ ] A release without the trial is out (1.3?), and the site's Download is that release.
- [ ] Lemon Squeezy product 1423364 is pay what you want, without license keys.
- [ ] The write-up is published, and linked from the text and the README.
- [ ] Numbers in the text checked against `launch/icloud-sync-post.md` and PRD §8 once more.
- [ ] A clean suite run (`scripts/run-m1-scenarios.sh`), so the "tested" claims are current.
- [ ] Post on a weekday morning, US Eastern time. Stay around for the first 2–3 hours.
- [ ] Don't ask anyone to upvote.

## Answers to have ready

- **Why not Obsidian / iA Writer / Sublime with the file in iCloud Drive?** They work, with iCloud's own schedule: nothing uploads while you type, and a stale copy is possible after a race. Rune's one idea is holding the file and uploading itself. Be generous about them; Rune does much less.
- **Why not a CRDT (Automerge, Yjs)?** It fixes merge semantics, which diff3 over lines (then words) already handles for one person, and it would move the text out of a plain file (PRD §4.10, option 5). The file stays readable by Finder, Terminal and any other editor.
- **Why iCloud and not a server?** No account, no server to keep up, no cost beyond the iCloud plan you have. The same reason Blit has no server.
- **What about the 2-3 s window before an upload finishes?** Close the lid in it and the other Mac has the old text until the laptop wakes; typing on the old text then merges instead of losing anything. A local-network path between the Macs would close it; the numbers so far haven't called for it (PRD §4.10).
- **What if Rune crashes with a file paused?** A pause outlives the app, so Rune keeps a list of the files it paused and settles them at its next launch (PRD §4.9, 14a; `Document.settlePausedFiles`). Removed without quitting it first, Rune can leave a file paused on that Mac (14b).
- **Is the crash still there?** It was on 27.0.1. TODO: say which version you've seen it on last, and whether it's filed (FB number).
- **iPhone?** No app. The file is a plain file in iCloud Drive, so the Files app sees it.
- **Why not the Mac App Store?** Rune isn't sandboxed: it opens any file anywhere, as a text editor should, and has a command-line tool for `$EDITOR`.
- **Why open source, and why pay?** It was $19 at launch. The useful part for others is how the sync works, and that's easier to trust when you can read it. Paying for the signed build is optional and funds the work.
- **Can I build it myself?** Yes, Xcode 27: `scripts/build-nib.sh adhoc` builds without an Apple team. Without Rune's iCloud container its scratch file starts in `iCloud Drive/nib-spike/`; the README says what to change for a container of your own.
