# Nib — QA and UX review: the plan

*Started 2026-10-06 at 22:40 and paused before any reviewer reported (the user's call). Restart it
from here.*

**What it is.** M3's "QA and UX review" (PRD §8): every window, strip message, alert, menu and
setting checked against the PRD's own rules (§0 Family DNA: V1-V14, W1-W8, A1-A17; the UX spec
§5, its keyboard table §5.12 and copy deck §5.13), the way Blit's was (`../blit/qa/blit-qa-ux-review.md`).
The sync engine isn't in it: the suite and the two-Mac runs test that.

**How.**
1. Six reviewers in parallel, one per area below, each read-only (no edits, builds, scenarios or
   launches; nothing of the user's own files), each sent the shared brief and its area.
2. Every finding checked against the code before it goes in the report (a reviewer's claim is a lead,
   not a fact).
3. The report written to `qa/nib-qa-ux-review.md`, as Blit's: findings most valuable first (Bug, then
   Rule, then Polish), each with where, the rule, what it says now and the fix; then what was checked
   and found solid; then the method and what a static review can't see.
4. The user chooses which findings to fix; nothing is changed before that.

**The pictures** the reviewers look at are the latest suite's, in `build/scenarios/*.png` (run the
suite first if they're old).

## The shared brief

> You're one of six reviewers in a QA and UX review of Nib, a macOS text editor (Swift 6, SwiftUI +
> AppKit, TextKit 2) in /Volumes/Photography/_GitHub/Nib. Read-only: don't edit any file, build, run
> scripts or scenarios, or launch the app. Don't read the user's own documents (iCloud Drive files,
> ~/Library/Mobile Documents); the repository is all you need.
>
> The rules: PRD.md §0 "Family DNA" (Visual language V1-V14, Voice W1-W8, Adaptations A1-A17) and
> the UX spec §5 (§5.1-§5.13; the copy deck is §5.13). Decisions recorded as "the user's call" or in
> §8 are settled: don't report them as findings, but do report code that contradicts them. Pictures
> of most windows from the latest test run are in build/scenarios/*.png (view them with the Read tool).
>
> YOUR AREA: (one of the six below)
>
> Report findings only where you've read the code (or seen the picture) that shows the problem. For
> each finding: **Title** (one line); Severity: Bug (wrong or misleading behaviour or text, or
> broken), Rule (breaks a PRD rule, or inconsistent with the rest of Nib), or Polish (small); Where:
> path:line (and the picture's name if it shows it); Rule: the PRD id(s); Now: what it does or says
> (quote the text); Fix: a concrete suggestion (replacement text, or the change). Most valuable
> first, at most 25. Then one short paragraph: what you checked and found solid, and what you
> couldn't check without running the app.

## The six areas

1. **The strip and what shows over the text.** SyncState lines (`nib/Model/SyncState.swift`); the
   strip (`nib/Views/StatusStrip.swift`); every strip notice (each `.show(` call, mostly in
   `nib/Model/Document.swift`); the conflict and deleted banners; the toast; the sync HUD
   (`nib/Views/SyncHUD.swift`); the menu bar item and panel (`nib/Views/MenuBar.swift`); notifications
   (`nib/Model/Notifier.swift`, NibText's Alerts and Spoken). W5's HUD grammar, W2 (✓ only when
   earned), W1/W4, the one red (V3), glyph and word (V4), §5.2-§5.4, §5.7, §5.13, and the same fact
   said the same way in the strip, the HUD, the menu bar panel and notifications.
2. **Menus and the keyboard.** Every command in `nib/NibApp.swift`; the command palette, Go to File
   and Go to Heading (`nib/Vendor/FromBlit/CommandPalette.swift`, `PaletteSession`, `showPalette`);
   key handling in `nib/Views/Editor.swift` and `MultiCarets.swift`. Every row of §5.12 (there, in a
   menu, on that key?), KB1-KB4 (Escape's order), W3 (Apple parity, ellipses, title case), clashing
   key equivalents, enabled and disabled states, names matching across menus, palette and PRD.
3. **Settings, first run and About.** `nib/Views/SettingsView.swift` (General, Files, Editor,
   Themes), `FirstRun.swift`, `AboutView.swift`, `AcknowledgementsView.swift`, `ShortcutField.swift`,
   `nib/Model/DefaultApps.swift`, `LoginItem.swift`. §5.8-§5.10, W7 (each control explained, what it
   doesn't do too), V12 (480 pt, forms that size to fit), and above all each caption against what the
   code does with its setting; the General tab's height (it can't scroll; the Air's screen is about
   900 points).
4. **The other windows.** History, the Sync Log, the merge view, the find bar, the gutter and
   minimap, the document window and tabs (`nib/Views/*.swift`), and their empty and edge states.
   V1, V2, V10, V12, A17, W6, W5 where HUD text is used, titles, sizes, focus on open, and the same
   thing named and drawn the same way in each.
5. **Accessibility and motion.** VoiceOver labels, hints and traits on every control and custom view
   (AX1-AX3; the gutter, minimap, match outline, carets, status item, Dock tile, pixel glyphs);
   actions only the mouse can do; Reduce Motion for every animation (A16: transitions, TimelineViews,
   timers, the CRT, marching dashes, About's cursor); contrast on the HUD's black and the scheme's
   background; colour never the only signal (V4).
6. **Alerts, errors and text outside windows.** Every NSAlert, `.alert(`, `confirmationDialog` and
   panel message; errors shown to the user; the CLI's messages, exit codes and usage
   (`NibKit/Sources/NibCLI`, `nib/Model/CLIBridge.swift`); Services and Shortcuts
   (`nib/Model/Services.swift`, `Support/Info.plist`); notifications' text; the Help menu. W1-W8,
   sentences vs HUD uppercase in the right places, buttons named for their action, destructive actions
   asking first, and the same terms everywhere (scratch file, History, Sync Log, iCloud Drive, this Mac,
   Reopen Closed File…).
