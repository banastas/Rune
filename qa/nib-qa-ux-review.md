# Nib — QA and UX review

*2026-10-07 · the repository at `a747c42` (a clean tree, untouched by the review) · the plan:
`qa/nib-qa-ux-review-plan.md`*

**How it was run.** Six static reviewers, one per area: the strip and what shows over the text;
menus and the keyboard; Settings, the first run and About; the other windows; accessibility and
motion; alerts, errors and text outside the windows. Each read the code against the PRD's own rules
(§0 V1-V14, W1-W8, A1-A17; §5; the keyboard table §5.12; the copy deck §5.13) and looked at the
latest suite's pictures (`build/scenarios/*.png`). About 140 findings came back; where two areas
found the same thing they're merged here. The most serious ones were checked against the code
before going in (**checked**); a few rest on how SwiftUI or macOS behaves at run time and are
marked **to check** on the Mac. Nothing was changed: you choose what to fix.

**Headline.** Nothing here loses text that the journal and History don't keep, and the sync engine
the suite tests holds. What the review found is around it:
- **Commands that can change text unseen:** Replace All with its field hidden, a History window
  restoring into a file that's closed, and opening a path with no file.
- **A strip that sometimes says less than it knows, or more:** a problem wiped by the first
  keystroke; files outside iCloud forever "SAVED LOCALLY"; a SYNCED time that moves on its own.
- **Copy that has drifted from the code:** captions, the conflict notification's ⌘3, error lines.
- **Accessibility gaps:** every editor is "Scratch" to VoiceOver; the find bar and palette are silent.
- **Two windows too tall for the Air's screen.**

Reduce Motion, colour never the only signal, and the HUD's tokens all held up (§4).

**Fixed so far:** the first round (2026-10-07), F1-F9, F16, F18, F23, F24, F29, F30 and F36, each
with a check in its scenario or NibKit's tests (PRD §8, "The QA and UX review, and its first round of
fixes"); the second (2026-10-07), F22, F25, F28, F31, F37-F39 and F48, with parts of F74, F82 and F84
(PRD §8, "The QA review's second round"); the third (2026-10-07), the rest of §1: F10-F15, F17,
F19-F21, F26, F27 (HTML out of Settings › Files), F32-F35, with parts of F65 and F82 (PRD §8, "The QA review's third
round"); the fourth (2026-10-07), §2 but F48 (done), F50 (the user's call) and F58, F60 (next): F40-F47, F49,
F51-F57, F59, F61-F63 (PRD §8, "The QA review's fourth round"); the fifth, F58 and F60 (PRD §8, "The QA review's
fifth round"). Of §1 and §2, only F50 is left, the user's call. The sixth (2026-10-07), §3's polish: all but
two parts of F82 (PRD §8, "The QA review's sixth round").

---

## 1 · Bugs: wrong, misleading or broken

### 1.1 Commands that can change text unseen

**F1. Replace All works while the Replace field is hidden, and can delete every match** — `nib/NibApp.swift:487-490`, `nib/Model/Find.swift:23` · ED7, W1 · **checked** · **fixed 2026-10-07**
Replace (⌥⌘E) and Replace All (⌃⌥Return) are enabled whenever the bar is shown, including after
⌘F, where the Replace row is collapsed. The replacement is then "" (or an old one nobody can see),
so ⌃⌥Return in a find-only bar deletes every match (one undo step).
*Fix:* enable them only while the Replace row is shown, or have them open it first.

**F2. A History window outlives its file, and Restore then writes into the closed file** — `nib/Views/HistoryView.swift:116-128`, `nib/Model/Document.swift:1601-1608, 2307` · SY13, §4.3 · **checked** · **fixed 2026-10-07**
`HistoryWindow` looks its document up once. Close the file's tab and the History window keeps the
closed `Document`, which keeps `ready`; Restore This Version replaces its buffer and saves, and
`save` doesn't look at `closing`, so the restored text is written into the file with no window and
no hold. The other way round, a History window saying "Open the file to see its History." stays
so after the file opens.
*Fix:* close a file's History windows as it closes (`Documents.watchClosing`), and refuse saves
and restores once `closing`.

**F3. Opening a path with no file makes an empty file at once** — `nib/Model/Document.swift:334-343`, `nib/Model/CLIBridge.swift:100`, `nib/NibApp.swift:551`, `nib/Model/Palette.swift:94` · SY4, W2, AP4 · **checked** · **fixed 2026-10-07**
Meant for the scratch file, but every open does it: `nib REAMDE.md` (a typo) leaves an empty file
(synced, in iCloud Drive), `nib /no/such/dir/x.md` exits 0 while the window shows "COULDN'T
CREATE…", and Open Recent or Go to File on a file deleted since launch makes it again, empty.
*Fix:* a missing file opens as a buffer that makes the file at its first save (as `subl` does);
the CLI refuses a missing folder (exit 1); Recent is filtered by existence when shown.

**F4. A Move that iCloud doesn't answer in time shows Swift's own error, and can leave an empty file behind** — `NibKit/Sources/NibSync/CloudControl.swift:37-43`, `nib/Model/FileCommands.swift:121-126` · W1, W4 · **checked** · **fixed 2026-10-07**
"THE OPERATION COULDN'T BE COMPLETED. (NIBSYNC.CLOUDCONTROL.CONTROLERROR ERROR 1.)", and Nib
reopens the old path; if the move then finishes, opening makes an empty file there (F3).
*Fix:* make `ControlError` a `LocalizedError` ("iCloud didn't answer in 20 s"), say "✕ COULDN'T
MOVE “NOTES.MD” · ICLOUD DIDN'T ANSWER IN 20 S · IT MAY STILL MOVE", and reopen whichever path has
the file.

### 1.2 The strip, the HUD and the menu bar saying the wrong thing

**F5. The first keystroke wipes a standing problem from the strip** — `nib/Model/Document.swift:827` · V9, §4.8 E, §4.9 rows 8, 11, 13, W2 · **checked** · **fixed 2026-10-07**
`textDidChange` sets "· EDITING" whatever the state was. After "✕ MOVED TO THE TRASH · …", "ICLOUD
DRIVE IS OFF…" or a moved scratch file, the red line and the menu bar ✕ go at the first key and
don't come back (no save lands to set them again); the deleted banner itself stays. With the disk
full the strip flips between "· EDITING" and "✕ DISK FULL" at every keystroke.
*Fix:* keep a `.problem` (and the deleted or iCloud-off state) through typing; say the typing is
kept: "✕ MOVED TO THE TRASH · TYPING KEPT IN THE JOURNAL · RESTORE PUTS IT BACK". `needsLook` true
while deleted.

**F6. Files outside iCloud Drive read "= SAVED LOCALLY" forever, and the menu bar marches while one is open** — `nib/Model/Document.swift:448, 600-603, 1093`, `nib/Views/MenuBar.swift:59-63`, `nib/Views/SyncHUD.swift:102` · §4.5 ("Local file: ✓ SAVED · 10:42:05"), A10, A11, W2 · **checked** · **fixed 2026-10-07**
New since the safety rule went: a file in ~/Documents is never held, so never uploaded, and stays
`.saved`: "= SAVED LOCALLY", with the tooltip "iCloud doesn't have this version yet", the HUD's panel
titled ICLOUD, and `MenuBarState.pending` true, so the menu bar line marches (a 0.16 s timer) for as
long as it's open.
*Fix:* a local-file state, "✓ SAVED · 10:42:05", its own tooltip ("Written to this Mac's disk; this
file isn't in iCloud Drive"), the THIS MAC panel in the HUD, and not pending.

**F7. "✓ SYNCED · 10:42:07" moves forward every 30 s with nothing uploaded** — `nib/Model/Document.swift:1297-1301` · W2, §4.5, A10 · **checked** · **fixed 2026-10-07**
Each check that finds nothing newer stamps `.synced(Date())`: every 30 s while Nib is in front and at
every focus, while the HUD's UPLOADED still says 10:42:07.
*Fix:* leave `.synced` as it is; its time is the upload's (`uploadedAt`).

**F8. The conflict notification says ⌘3 "keeps one"; it keeps both** — `NibKit/Sources/NibText/Alerts.swift:38-39` · W1, W2, §5.4 · **checked** · **fixed 2026-10-07**
"…between markers. ⌘1, ⌘2 or ⌘3 keeps one." (the banner says "⌘3 keeps both").
*Fix:* "…between markers. In Nib, ⌘1 or ⌘2 in a block keeps one version, ⌘3 keeps both."

**F9. Conflict sources come out "ICloud" and "The file", in the file's own markers** — `nib/Model/Document.swift:1439` · W3, W8 · **checked** · **fixed 2026-10-07**
`source.prefix(1).uppercased() + …` makes "ICloud" (and "Another app", "The file"): in the conflict
markers written to the file (">>>>>>> ICloud · 10:42:05"), the notification ("Conflict with ICloud
in notes.md"), the banner, the Conflicts menu ("Use ICloud · 10:42") and the undo name.
*Fix:* a label form and a sentence form per source; never capitalise "iCloud".

**F10. The conflict banner guesses who the other side is** — `nib/Views/ConflictBanner.swift:40-55` · W1, W2 · pictures `synchud-warning.png`, `snapshot-in-app.png` · **fixed 2026-10-07**
The first label not starting with this Mac's name: "This Mac and this Mac both changed this file.",
"The file and this Mac…" after a crash, a duplicate file named as the other Mac ("scratch-test 2.md
and this Mac…") while the block in view is between two Macs, and a Mac named "Studio 2" taken for
"Studio".
*Fix:* compare whole labels with `device`; give "This Mac", "The file" and duplicates their own
sentences; with several sources, "Several versions changed this file…".

**F11. The menu bar's ✕ lights for any open file, but its panel, tooltip and Settings note speak only of the scratch file** — `nib/Views/MenuBar.swift:183, 188-190, 267`, `nib/Views/SettingsView.swift:54` · W1, §5.7 · **checked** · **fixed 2026-10-07**
A conflict in notes.md lights the ✕; the panel shows the scratch card at "✓ SYNCED"; the tooltip
says "SOMETHING NEEDS A LOOK".
*Fix:* a panel line per other file that needs a look ("✕ NOTES.MD · CONFLICT · 2 PLACES", opening
it), the file named in the tooltip, and the Settings note saying "your open files".

**F12. The HUD's STATE and ON DISK rows say things that aren't so** — `nib/Views/SyncHUD.swift:106, 224-225` · W2, W1 · **fixed 2026-10-07**
ON DISK is "CURRENT" for a deleted file before typing and "SAVING" for good after; "SAVING" for good
with iCloud Drive off or the disk full; "CURRENT" for the offline copy. STATE is "✕ PROBLEM" or "‖
WAITING" without saying what (and not red).
*Fix:* "GONE", "NOT SAVED · IN THE JOURNAL", "IN THE RECOVERY FOLDER", "NOT HERE YET"; STATE with the
problem's first fact, in the red's text tint.

**F13. A save time is shown before anything was saved** — `nib/Model/Document.swift:164, 448, 554`, `SyncHUD.swift:104`, `MenuBar.swift:78` · W2, W5 · **fixed 2026-10-07**
At open: "= SAVED LOCALLY · <the time it opened>", the HUD's SAVED at launch, the panel "SAVED
22:24:04 · UPLOADED —"; a held file opened already uploaded shows "✓ SYNCED" beside "UPLOADED —".
*Fix:* "—" until a save (or the file's modification time), "--:--" where the time isn't known.

**F14. "1 PLACE" when the whole of both versions is between markers** — `nib/Model/Document.swift:1453, 1470, 1634, 1654`, `Alerts.swift:38` · W2 · **fixed 2026-10-07**
With no proven base, a conflict version or a duplicate: "✕ CONFLICT WITH AIR · 1 PLACE · BOTH
VERSIONS ARE IN THE TEXT".
*Fix:* "BOTH WHOLE VERSIONS ARE IN THE TEXT, BETWEEN MARKERS", and the same in the notification.

**F15. "◐ OFFLINE" on a Mac that's online** — `nib/Model/Document.swift:360-362, 444` · W2, W4 · **fixed 2026-10-07**
A file not here in 20 s opens from the copy as "◐ OFFLINE · …" even when only iCloud is slow (the
no-copy case already tells the two apart).
*Fix:* "◐ NOT HERE YET · ICLOUD IS SLOW TO BRING IT · SHOWING THE COPY FROM 16:38 · …" when online.

**F16. A moved scratch file's line can say it moved to itself** — `nib/Model/Document.swift:2210-2213` · W1 · **checked** · **fixed 2026-10-07**
"SCRATCH.MD MOVED TO SCRATCH.MD · …" for a move to another folder (the new name only).
*Fix:* the new place and name: "…MOVED TO ICLOUD DRIVE › ARCHIVE › SCRATCH.MD · …".

**F17. Error lines are Cocoa's whole sentences, uppercased, then lowercased into notifications and sentences** — `nib/Model/Document.swift:2596` (`short`), `Alerts.swift:76-82`, `nib/Views/FirstRun.swift:98, 331-333`, `nib/Model/CLIBridge.swift:46`, `nib/Model/SyncState.swift:81-82` · W1, W3, W5, §5.13 · **checked** · **fixed 2026-10-07**
"COULDN'T SAVE SCRATCH.MD · YOU DON'T HAVE PERMISSION TO SAVE THE FILE “SCRATCH.MD” IN THE FOLDER
“NIB” · …" (the name twice, no quotes on the first, too long for the strip); the notification
lowercases it ("…in the folder “nib”", "readme.md"); the welcome window says "Nib couldn't read
Sublime Text's settings: sublime text's scheme “mariana…” not found · nothing imported" (it did read
them); `nib` writes "(problem: nib's icloud folder isn't available · …)"; tooltips read "Problem:
icloud drive is off on this mac · …".
*Fix:* short HUD words for the common errors (PERMISSION DENIED, FILE IS LOCKED, FOLDER IS GONE,
DISK IS READ-ONLY) with a sentence form of each; `Spoken.sentence` where a sentence is wanted;
never lowercase names.

**F18. The large-file alert says every save writes the whole file** — `nib/NibApp.swift:141` · W2 · **checked** · **fixed 2026-10-07**
Not so since 2026-10-02 (a save writes from the first byte that differs).
*Fix:* "…and History keeps only the versions opened and closed with. In iCloud Drive every save is
uploaded whole."

**F19. "The clipboard has no text" when the text came from somewhere else** — `nib/Model/Clipboard.swift:64` · W1 · **fixed 2026-10-07**
Said for the Service, the Shortcut and `nib -a` too.
*Fix:* name the source: "NOTHING TO APPEND · THE SELECTION IS EMPTY ONCE CLEANED" and so on.

**F20. Restored versions are named by time of day only** — `nib/Model/Document.swift:1605-1608` · W1 · **fixed 2026-10-07**
"= BACK TO THE VERSION FROM 17:40:00 (SAVED)", "Revert to 17:40:00", for a version up to 30 days old.
*Fix:* History's own "Sep 26 17:40:00" / "Yesterday 09:12:05".

**F21. The strip keeps saying "SEE THE WELCOME WINDOW" after it's closed** — `nib/Model/Document.swift:291` · W1 · **fixed 2026-10-07**
*Fix:* "NO SCRATCH FILE YET · HELP › WELCOME TO NIB SETS ONE UP".

### 1.3 Settings and the first run

**F22. The General tab and the welcome window are taller than the Air's screen, and can't scroll** — `nib/Views/SettingsView.swift:30-31, 75`, `nib/Views/FirstRun.swift:194, 216` · V12, §5.8 · **checked** · pictures `settings-general.png`, `firstrun-3-taken.png` · **fixed 2026-10-07**
General is about 967 points tall with its title bar (the picture is 1934 pixels at 2×), and taller
with a shortcut warning; the Air shows about 900 under its menu bar, so the scratch file's buttons
end up off screen. The welcome window's fixed 560×580 hides its own Notifications note under the
footer when two shortcut warnings show. (Editor is probably over 900 too: no picture yet.)
*Fix:* move the scratch file to §5.8's Scratch & Sync tab (F48), shorten the long notes; let the
welcome window size to each step, 580 its minimum.

**F23. Global shortcuts accept keys every app uses** — `nib/Model/HotKey.swift:86-94` · W7, §8 · **checked** · **fixed 2026-10-07**
Any key with ⌘ is taken (⌘C, ⌘V, ⌘Z, ⌘W, ⌘Q): a Carbon hot key would take Copy or Paste from every
app. ⌥ with a letter too (⌥E is the accent key), the very reason ⇧ alone is refused.
*Fix:* refuse ⌘/⇧⌘ with the standard Edit and File keys and ⌥/⌥⇧ with a character key (⌥Space
stays), saying why: "⌘C is Copy in every app; Nib would take it from all of them. Add ⌃ or ⌥."

**F24. The refusal of keys another action has is wiped as it's set** — `nib/Views/ShortcutField.swift:124-126`, `nib/Model/HotKey.swift:250-282` · W1 · **checked** · **fixed 2026-10-07**
`set` stores "Clean Clipboard already uses ⌃⌥⌘V. These keys stay …", then `stop()` → `resume()` →
`register()` clears it: the field snaps back with no reason. (The `firstrun` scenario calls `set`
directly, so it never saw this.)
*Fix:* `stop()` before `set`, or keep refusals apart from what `register` clears.

**F25. Import from Sublime Text sets nine Editor settings its captions don't mention** — `nib/Theme/Scheme.swift:243-257`, `nib/Views/SettingsView.swift:213`, `nib/Views/FirstRun.swift:325-329` · W7, W2, HL4 · **checked** · **fixed 2026-10-07**
Tab size, spaces, line numbers, invisibles, indent guides, matching brackets, closing pairs,
trimming and the final newline, from Sublime's defaults if not its user file, so nearly always. The
Themes note says it reads the scheme and font; the first run lists five of them; the report never
mentions guides, brackets or pairs.
*Fix:* say all of it in both places ("…and sets Nib's to match"), ask "Use Sublime's color scheme,
font and editor settings?", and add the three to the report.

**F26. The welcome window looks for the scratch file once, then offers Create** — `nib/Views/FirstRun.swift:77-87, 275, 282-284` · W4, §4 · **checked** · **fixed 2026-10-07**
On a second Mac, if iCloud hasn't listed the folder within 10 s it says there's no scratch.md yet
and offers Create, which makes an empty one where the other Mac's is on its way.
*Fix:* Look Again, and "If another Mac has one, iCloud may still be bringing it", or keep watching
the folder while the window's open.

**F27. With HTML set to open in Nib, links to local .html files open in Nib too, and nothing says so** — `nib/Views/SettingsView.swift:101, 110`, `nib/Model/DefaultApps.swift:53` · W7 · seen by the user (2026-10-06) · **fixed 2026-10-07**: HTML taken out of Settings › Files (the user's call), given back once where Nib had it
A link in a terminal or another app to a page on this Mac opens it as text in Nib.
*Fix:* say so on the HTML row ("Any app that opens a .html file on this Mac opens it in Nib, as text;
web links still open in your browser"); and see the user's open question on an Open in Nib Quick
Action and File › Open in Browser.

**F28. Captions that say something the code doesn't do** — `nib/Views/SettingsView.swift:54, 71, 183, 206`, `nib/Views/FirstRun.swift:296` · W1, W7 · **checked** (206, 54) · **fixed 2026-10-07**
- Themes: "Colors the text only." The scheme colours the page: background, caret, selection, line
  highlight, gutter, minimap (`snapshot-themes.png`).
- The menu bar note: "the scratch file's sync" (it follows every open file, F11).
- Paste Clean: names two commands (the same options clean Append, the Services and `nib -a`) and
  hard-codes Clean Clipboard's keys, which General can change.
- The first run says the scratch file is on every Mac even after one outside iCloud Drive was
  chosen; General doesn't say a file outside iCloud Drive stays on this Mac.
*Fix:* say what each does, from the code.

### 1.4 Keys and menus

**F29. Caps Lock turns off ⌘K and ⌘1…⌘9** — `nib/NibApp.swift:217` · A6, KB2 · **checked** · **fixed 2026-10-07**
`.deviceIndependentFlagsMask` includes Caps Lock; digits are also read as characters, so ⌘1 is "&"
on AZERTY.
*Fix:* compare only ⌘⇧⌥⌃; match digits by key code.

**F30. ⌥↑, ⌥↓, ⌃A and ⌃E drop the extra carets** — `nib/Views/MultiCarets.swift:318-335` · ED8 · **checked** · **fixed 2026-10-07**
The paragraph moves aren't among the caret moves, so they collapse to one caret.
*Fix:* add them, with and without extending.

**F31. In the merge view, Find, Replace, Go to Line and Show Sync Details likely act on the window behind the sheet** — `nib/NibApp.swift:384-386, 473-490, 505` · §5.5, ED7 · **to check** (two reviewers, from the code) · **fixed 2026-10-07**
The Conflicts menu works there because the window's document is still the focused one while the
sheet is up; if so, ⌘F opens the parent's find bar under the sheet, ⌘G and Replace All act on the
buffer behind, and ⌃G opens the strip's line field behind it.
*Fix:* while `merge != nil`, send these to the merge result's editor (with a find bar in the sheet),
or disable them.

**F32. Escape hides the conflict banner before the find bar** — `nib/Views/Editor.swift:61-67` · KB1, §5.12, V9 · **checked** · **fixed 2026-10-07**
The order is HUD, banner, find bar; with the bar open and the caret in the text, the first Escape
hides the red banner (until the blocks change) and the bar stays. KB1 and §5.12 also disagree.
*Fix:* carets, HUD, find bar, then the banner; one order in the PRD.

### 1.5 Windows

**F33. Once opened, the Sync Log re-reads the whole log after every line, for the rest of the session** — `nib/Views/SyncLogView.swift:42-67` · A11, §6.5 · **checked** · **fixed 2026-10-07**
Its model observes every append from the first time it's used and decodes all of `sync.jsonl`
(never trimmed) each time, window open or not.
*Fix:* observe only while the window's open, and read only what's new.

**F34. The merge panes' titles come from the first block only** — `nib/Views/MergeView.swift:34-35` · W1, W2 · picture `snapshot-mergeview.png` · **fixed 2026-10-07**
One source and one time for every block in the pane.
*Fix:* the shared name when the blocks agree; otherwise a range of times, or none.

**F35. The Sync Log's Show History leads to a dead end for a file that isn't open** — `nib/Views/SyncLogView.swift:198-201` · W6, SY13 · **fixed 2026-10-07**
"Open the file to see its History." with no way to open it (and a `fileExists` in `body`).
*Fix:* show the path's History read-only with an Open button, or offer it only for open files.

### 1.6 Accessibility

**F36. Every editor tells VoiceOver it's "Scratch"** — `nib/Views/Editor.swift:76` · AX1 · **checked** · **fixed 2026-10-07**
Every file tab and untitled buffer is "Scratch, edit text"; the merge panes and History's preview
have no label.
*Fix:* the file's name (set again after Rename and Move To); the panes' titles; "Version from …".

**F37. Problems aren't spoken while Nib is in front, and a tab not in front is neither spoken nor notified** — `nib/Model/Document.swift:2079-2087, 964-967, 1243-1244, 2580`, `nib/Model/Notifier.swift:43` · V9, A8, AX2 · **fixed 2026-10-07**
The strip shows them, but VoiceOver hears nothing; a conflict in a background tab is announced
nowhere.
*Fix:* announce a new problem at high priority; notify (naming the file) when its window isn't
visible, even with Nib in front.

**F38. The find bar and the command palette are silent** — `nib/Views/FindBar.swift:26-33`, `nib/Model/Find.swift:119-125`, `nib/Vendor/FromBlit/CommandPalette.swift:71-104` · AX2, KB2, KB3 · **fixed 2026-10-07**
Moving to a match, "No matches", the palette's highlighted row and its count are only drawn; a
palette row opens only by a double click.
*Fix:* announce "2 of 4: …" and "No matches"; announce the highlighted row; give rows a button
trait and an action.

**F39. Pixel glyphs are spoken with Blit's transfer words** — `nib/Vendor/FromBlit/PixelGlyphs.swift:28-39` · V4, AX1 · **fixed 2026-10-07**
✓ "done", ▲ "transferring", ▼ "down", ‖ "paused": the HUD reads "STATE, done SYNCED", the Sync Log
reads an upload as "transferring".
*Fix:* label HUD rows and log lines with `Spoken.sentence`, or give the glyphs Nib's words.

---

## 2 · Rules: the PRD says otherwise, or Nib disagrees with itself

**F40. Failure notices mostly lack the ✕, and none are red; a notice hides a standing problem** — `nib/Views/StatusStrip.swift:98, 107, 133-134`, `nib/Model/FileCommands.swift:19, 85, 103-124`, `nib/Model/Untitled.swift:153, 162` · V3, V9 · **fixed 2026-10-07**
"COULDN'T SAVE “X” · …" and "“NOTES.MD” IS ALREADY THERE · NOTHING MOVED" show bright with no glyph;
"✕ …" notices draw their ✕ in white; any notice replaces a red problem line (and its tag) for up to
20 s; "‖" notices are bright.
*Fix:* ✕ on every failure, drawn in the red; keep the problem and its tag under routine notices;
"‖" dim.

**F41. The same fact is worded differently on each surface** — `nib/Model/Document.swift:1909-1913`, `SyncHUD.swift:134-136, 222-223`, `MenuBar.swift:86-88`, `StatusStrip.swift:147-149` · **fixed 2026-10-07**
Another Mac's older version: HUD "OLDER · 21:06", panel "M4CK800K412 HASN'T GOT THIS VERSION YET ·
HAS 21:06:27'S", tooltip "…hasn't got this version yet (it has one from 21:06:27…)"; "= ON THIS MAC
ONLY" in the strip and "= THIS MAC ONLY" in the HUD; the HUD's STATE "✓ SYNCED" while the strip says
"▼ NEWER ON AIR…".
*Fix:* one helper for the three surfaces.

**F42. Upload trouble doesn't say why, and §4.5's line for a stalled upload isn't built** — `nib/Model/Document.swift:1246-1252` · §4.5, §4.9 row 12, W4 · **fixed 2026-10-07**
A failed upload call is a dim "‖ ICLOUD ISN'T TAKING UPLOADS · SAVED LOCALLY · RETRYING" with no
reason or time; an unheld file sits at "= SAVED LOCALLY" however long iCloud waits.
*Fix:* "✕ ICLOUD REFUSED THE UPLOAD · <REASON> · TRYING AGAIN AT 10:47"; the 60 s "ICLOUD HASN'T
STARTED UPLOADING (2 MIN)".

**F43. The menu bar line marches after most pauses in typing** — `nib/Views/MenuBar.swift:59-63, 184-185` · A10, V8 · **fixed 2026-10-07**
Pending counts from the save, but the upload waits 3 s for the pause by design (UploadSchedule) and
takes 0.5-3 s, so an ordinary pause marches for a second or two.
*Fix:* count from when the upload is due.

**F44. Commands only on the strip or a banner, so not in a menu or the palette** — `nib/Views/StatusStrip.swift:22-31, 170-183`, `nib/Views/DeletedBanner.swift:41-54` · KB1, KB3 · **fixed 2026-10-07**
Empty Trash, Show in Finder, Show Sync Log for this file, Restore.
*Fix:* File › Show in Finder, Show Sync Log for This File, Restore (enabled while deleted), Empty
Trash… (while offered).

**F45. "Reveal in Finder" here, "Show in Finder" everywhere else; the strip's Save Now isn't ⌘S** — `nib/Views/StatusStrip.swift:177, 182` · W3 · **checked** · **fixed 2026-10-07**
Save Now flushes, skipping ⌘S's trim and final newline; for an untitled buffer, Reveal shows Nib's own
Untitled folder.
*Fix:* "Show in Finder" (and §5.2), hidden for untitled buffers; Save Now runs File › Save.

**F46. Text, Selection and Edit commands are enabled with no editor, and do nothing** — `nib/NibApp.swift:457, 494-522` · W3, KB1 · **fixed 2026-10-07**
With Settings, the Sync Log or History in front, ⌘], ⌘/, ⌘D, ⇧⌘C, ⌘U stay enabled and silently do
nothing; the same in a read-only document.
*Fix:* disable on `document == nil || locked`, or validate through the text view.

**F47. Show Scratch (⌥Space, P0) isn't in any menu** — `nib/NibApp.swift:463-465` · KB1, KB3, SC2 · **fixed 2026-10-07**
So the palette can't list it.
*Fix:* Window › Show Scratch with its global key shown.

**F48. Settings is missing §5.8's notifications item and Scratch & Sync tab** — `nib/Views/SettingsView.swift:15-75` · §5.8, §5.13, W7 · **fixed 2026-10-07**
No notifications line ("saves never notify"), no this Mac's name (which receipts show), History
retention, Clear History…, the ADP note or the sync note; no word that text always wraps.
*Fix:* a Scratch & Sync tab with the scratch file (also F22), the sync note, notifications with Open
Notification Settings, and History.

**F49. Commands without the keys KB1 promises, and §8 says otherwise** — `nib/NibApp.swift:428-444, 460, 521, 526`, `PRD.md:1477` · KB1 · **fixed 2026-10-07**
Rename…, Move To…, Revert To ›, the View toggles, the syntax picks, One Caret, Welcome to Nib.
*Fix:* reword KB1 ("Apple's or Sublime's key where one exists") and correct §8; don't invent keys.

**F50. No commands for indentation, encoding or line endings, and no Hide Status Bar** — `nib/Views/StatusStrip.swift:71-73`, `nib/NibApp.swift:438-450` · §5.2, ED5, KB4
The strip shows "2 SPACES · UTF-8 · LF" but nothing changes or converts them; View › Hide Status Bar
(§5.2) isn't built.
*Fix:* View › Indentation and Line Endings (and menus on the strip's slots), or record in §8 that
they're dropped.

**F51. The find bar's options have no menu items or keys** — `nib/Views/FindBar.swift:34-37` · KB1, KB4 · **fixed 2026-10-07**
*Fix:* Edit › Find toggles; Sublime's ⌥⌘C and ⌥⌘W while the bar is shown.

**F52. "Resolve…" has an ellipsis but usually just moves the caret** — `nib/NibApp.swift:623`, `ConflictBanner.swift:30-31` · W3 · **fixed 2026-10-07**
With three blocks or fewer it goes to the next one, asking nothing; the HUD's RESOLVE says it opens
the merge view.
*Fix:* name it for what it will do, or always open the merge view.

**F53. "What macOS may ask" leaves out two questions; step 3 leaves out deleted files** — `nib/Views/FirstRun.swift:304, 368` · AP5, SY15 · **fixed 2026-10-07**
The notifications question at Done and Finder control for Empty Trash aren't mentioned; folder
prompts for Documents and Desktop now that Nib opens any file have no usage descriptions
(`Support/Info.plist`).
*Fix:* say both; add the folder usage descriptions ("Nib opens only the files you open in it").

**F54. Removing an imported scheme deletes it at once, unasked** — `nib/Views/SettingsView.swift:204`, `nib/Theme/Scheme.swift:143-147` · V8 · **fixed 2026-10-07**
*Fix:* to the Trash, or ask first; a note that the original isn't touched.

**F55. History calls merged, restored and closed-with versions "saved"** — `nib/Model/Document.swift:2511-2523` · SY13, A13 · **fixed 2026-10-07**
*Fix:* keep the reason and show it.

**F56. The empty scratch file's line isn't built** — `nib/Views/ScratchView.swift:22-41` · §5.1, W6, §5.13 · **fixed 2026-10-07**
*Fix:* "Paste or type. Saved as you go, on every Mac." in the comment colour while it's empty.

**F57. History reads and hashes on the main thread, in `body`** — `nib/Views/HistoryView.swift:22, 40, 104` · T5 · **fixed 2026-10-07**
2.4 MB hashed per selection change, under History's lock.
*Fix:* load on the journal queue into state.

**F58. Sizes: the find bar needs about 700 points, the merge sheet more than its window; History's list takes half** — `nib/Views/FindBar.swift:16-48`, `MergeView.swift:108`, `HistoryView.swift:28-38` · V12 · **fixed 2026-10-07**
*Fix:* `ViewThatFits` for the bar; a merge minimum about 600×420; History in a 170-300 pt sidebar.

**F59. HUD grey on the editor's background is under 4.5:1** — `nib/Views/MergeView.swift:132-135`, `nib/Views/Editor.swift:1290-1297` · V2 · **fixed 2026-10-07**
The merge panes' titles (4.1:1) and the block hints "⌘1 USE · ⌘3 BOTH" (4.2:1), both 9 pt.
*Fix:* a grey of at least #909090.

**F60. Conflict blocks' words, the gutter ✕ and resolving aren't spoken** — `nib/Views/Editor.swift:1268-1311, 1391-1404`, `nib/Model/Document.swift:883-889`, `MergeView.swift:68-88` · §5.4, AX2 · **fixed 2026-10-07**
*Fix:* custom actions in a block ("Use Air's version, Command-1"…), and say each resolve and "All
conflicts resolved".

**F61. Labels that skip `Spoken`** — `SyncState.swift:81-82`, `MenuBar.swift:188, 273, 383`, `FindBar.swift:33`, `SettingsView.swift:227`, `FirstRun.swift:351` · AX1 · **fixed 2026-10-07**
*Fix:* `Spoken.sentence`, and `keys.spoken` for shortcuts.

**F62. Results that appear beside a button aren't said** — `MenuBar.swift:268-280`, `SettingsView.swift:216-228`, `FirstRun.swift:197-214` · AX2 · **fixed 2026-10-07**
*Fix:* announce them.

**F63. Services › Append to Nib Scratch confirms nothing while Nib is behind** — `nib/Model/Services.swift:19-30` · W1, SC6 · **fixed 2026-10-07**
*Fix:* the Toast, as Append Clipboard to Scratch shows.

---

## 3 · Polish

- **F64.** Curly quotes around file names, unevenly (FirstRun, banners, Alerts, Document's save
  line). W3. **Fixed 2026-10-07.**
- **F65.** Times from another day without a date ("✓ SYNCED · 10:42:07" from yesterday); 24-hour
  times may follow the Mac's 12-hour setting (to check). W1, W5. **Fixed 2026-10-07.**
- **F66.** "Its note" (internal word) in "‖ … WAITING FOR ITS NOTE TO MERGE IT"; "· OPENING" without
  saying it waits on iCloud. W1, W4. **Fixed 2026-10-07.**
- **F67.** "CLIPBOARD CLEANED · ALREADY PLAIN AND CLEAN"; "⌘Z UNDOES IT" against "⌘Z UNDOES";
  "SAVED LOCALLY 10:42:05" without its dot; the HUD log's paths and semicolons. W5. **Fixed 2026-10-07.**
- **F68.** The HUD's WARNING says only the first block's lines for "2 CONFLICTS"; its RESOLVE hides
  its name from VoiceOver. **Fixed 2026-10-07.**
- **F69.** Settings › Files: "Shell scripts files", "Plain text files"; a declined shell prompt leaves
  the row "now Xcode"; "now no app"; one extension shown per kind. **Fixed 2026-10-07.**
- **F70.** Rename refuses ".env" as "CAN'T BE A FILE NAME" (**checked**), and "“” CAN'T BE…" for an
  empty field. **Fixed 2026-10-07.**
- **F71.** Save… for an untitled buffer is app-modal and suggests ".txt" for JavaScript. **Fixed 2026-10-07.**
- **F72.** Failures that guess a cause or only beep (Duplicate's "NOT WRITABLE", ⌘N, Reopen Closed
  File); the Trash messages ("NOT ALLOWED TO CONTROL FINDER" for any error, "(3 items)" twice). **Fixed 2026-10-07.**
- **F73.** The CLI's usage: "-h, --help this", `--scratch` and the exit statuses missing, "no option
  -x", `-w` ignored silently with `-a`. **Fixed 2026-10-07.**
- **F74.** The scratch-change alert's wording ("Nib reopens to use it, in iCloud Drive › Nib") and its
  app-modal sheet; step 3 says "Done" when the button reads "Reopen Nib"; "Continue skips it" after the
  import is done. **Fixed 2026-10-07.**
- **F75.** Shortcuts' descriptions are fragments; Get Scratch fails without saying why. **Fixed 2026-10-07.**
- **F76.** "One Caret (⎋)" puts its key in the title; Go to Heading… missing from the palette; Revert
  To's versions and syntax picks named bare in the palette; Nib-folder files with a folder icon. **Fixed 2026-10-07.**
- **F77.** Go to Heading's empty line ("No headings: ⌘R lists a Markdown file's"). **Fixed 2026-10-07.**
- **F78.** ⌘W "Close" where Apple says Close Tab, and no Close Window ⇧⌘W. **Fixed 2026-10-07.**
- **F79.** The Sync Log: "Closed · closing" before anything closed; "0 events" while loading; a
  selection kept after the search hides it; times "Oct 6  22:29:37" against History's "Today …";
  "3 kB" against "KB" elsewhere. **Fixed 2026-10-07.**
- **F80.** History: lowercase sources ("saved · 588 bytes"); no folder subtitle; Restore enabled on the
  current text, doing nothing. **Fixed 2026-10-07.**
- **F81.** The find count cuts "NO MATCHES IN THE SELECTION"; In Selection's VoiceOver label is its
  whole tooltip. **Fixed 2026-10-07.**
- **F82.** Syntax names spoken "Html", "Javascript"; the gutter not hidden or labelled for VoiceOver;
  the Toast always interrupts VoiceOver; Recent rows with the same name sound the same; the panel
  isn't keyboard-navigable; the Dock ✕ has no words; About's "NIB" and "V0.1 · BUILD 3" read raw;
  the palette's group labels at 2.3:1. **Mostly fixed 2026-10-07**: left, the menu bar panel by the keyboard, and words for the Dock ✕ (macOS gives a Dock tile no accessibility of its own but its red badge).
- **F83.** Acknowledgements cuts long names and versions in its 230-point list (**checked**,
  `acknowledgements.png`). **Fixed 2026-10-07.**
- **F84.** Settings opens on its third tab (Editor) the first time; the Dock switch goes grey with no
  reason given; the Editor tab's one seven-sentence note for six switches. **Fixed 2026-10-07.**
- **F85.** "Login Items" is "Login Items & Extensions" since macOS 15 (**to check** on macOS 27). **Fixed 2026-10-07.**

---

## 4 · Checked and found solid

- **Reduce Motion (A16)** in every animated part: the HUD's CRT becomes a fade, About's `_` stays lit,
  the menu bar line stands still in dashes and follows the setting live, the Toast only fades, scrolls
  are never animated.
- **Colour never alone (V4):** the strip's tag, the find count, the WARNING panel, the merge view's
  marks and the Sync Log all pair colour with a glyph or word; the current match's outline shows.
- **Tokens:** the HUD's #0A0A0A and #2B2B2B, the one red (#B35C5C, #C98080 for text), black on red at
  4.6:1, HUD dim at 4.8:1 on the HUD's black, the find colours at 17:1, gutter numbers at 4.5:1.
- **Dark only (A17)** everywhere.
- **Notifications:** once while a problem lasts, never while Nib is in front, taken back when it's over.
- **Keys:** every row of §5.12 is in a menu on its key (but Show Scratch, F47, and the tab keys, by
  design); no two of Nib's keys collide; ⌘1-⌘3 yield to a conflict block; toggles flip their titles;
  the palette takes its names and keys from the live menus.
- **Settings' captions** for tab width, ⌘S tidying, the font, the login item and the Files tab's three
  shell prompts match the code; the shortcut field's Escape, Delete and Tab; About and its
  Acknowledgements as §5.10 and DS3 ask.
- **Windows:** document titles and subtitles, the find bar's focus, the gutter's fixed width, the
  minimap hidden from VoiceOver and under 200 points, the Sync Log's empty lines, the merge header's
  HUD grammar.
- **The Empty Trash question** asks first, in Finder's words, with a destructive button.

## 5 · Method, and what a static review can't see

Six reviewers read the code and the pictures, and each finding marked **checked** was confirmed in
the code before it went in; the rest are consistent with what was read, and are taken as reported.
To check on the Mac:
- whether the merge view's menus act behind the sheet (F31);
- the Editor tab's real height (F22);
- how VoiceOver reads the strip, the HUD and the panel;
- the folder prompts macOS shows for files Nib now opens anywhere (F53);
- whether the Sync Log's selected filter really draws blank (`snapshot-synclog.png`);
- what macOS returns when a default-app prompt is declined;
- the Login Items pane's name on macOS 27 (F85);
- whether ⌘F reaches the Sync Log's search field.
