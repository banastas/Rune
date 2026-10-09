# Rune on Product Hunt

Everything the submission form asks for, ready to paste. Written plainly: what Rune does, said
literally (no "game-changer", no "seamless"). The images are in `launch/product-hunt/`, made by
`scripts/make-brand.sh` from `scripts/brand/rune-ph.html`.

## The form

**Name** (40 characters at most)

> Rune

**Tagline** (60 at most; no full stop). Pick one:

> A Mac text editor with one scratch file for all your Macs (57)

> A small Mac text editor that saves as you type and merges (57)

> Write it down on one Mac, find it on the other (46)

The first says what it is; the third is the one people will remember. The second leans on
"merges", which needs the description to make sense.

**Description** (260 at most; this is the length shown in previews)

> Rune is a small, fast text editor for the Mac. One scratch file in iCloud Drive is shared by all your Macs: saved as you type, and edits from two Macs are merged, never overwritten. Plain-text paste, Sublime Text's colors and keys, and Find in History.

(252 characters.)

**Links:** https://rune.banast.as

**Topics** (up to 3): Mac · Productivity · Developer Tools

**Pricing:** Paid, with a free trial: $19 once, for 3 Macs; 7 days free on each Mac.

**Thumbnail** (240×240): `launch/product-hunt/thumbnail-240x240.png`, the app icon.

**Gallery** (1270×760, in this order; the first is also the preview when the page is shared):
1. `1-rune-1270x760.png`: the icon, name and tagline, and the scratch window with its synced strip.
2. `2-conflicts-1270x760.png`: a conflict in Rune beside the same file in any other editor.
3. `3-find-in-history-1270x760.png`: Find naming the saved version that still has deleted text.

**Makers:** you. **Hunter:** you, or someone else willing to post it.

## The maker's first comment

> I've used Sublime Text every day for almost twenty years, but only a few of its features, and it doesn't do the one thing I wanted most: keep one scratch file the same on every Mac I use, without losing a line when two of them change it. So I built Rune, a small editor around that file.
>
> How it works: the scratch file is stored in iCloud Drive. Rune saves the file a second after you stop typing, uploads each version itself, and when two Macs both changed the file, it merges the changes, by line and then by word. Where both changed the same lines, both versions stay in the file between git's conflict markers, so nothing is lost even if you open it in another editor. The status line at the bottom says whether each version is saved, uploaded, or loaded on your other Mac.
>
> It's now my everyday text editor too: highlighting that matches Sublime Text in 33 languages, Sublime Text's keys and multiple carets, and ⌘V pastes plain text only, with no fonts or colors. And when Find has no matches, Rune searches the file's saved versions and tells you which one still has what you deleted.
>
> There's no account and no server of mine: your files go only through iCloud Drive, and there's no analytics. It's $19 once for 3 Macs, with 7 days free on each.
>
> I'd like to hear what's missing or doesn't work, especially from people who use it on more than one Mac.

## Before and on the day

- **Schedule** the launch for 12:01 AM Pacific: the day's ranking runs midnight to midnight PT.
- **Don't ask for upvotes:** Product Hunt's guidelines say not to. Tell people it's live and ask
  what they think.
- **Answer every comment** through the day; that's most of what a launch is.
- **The site and the store** should be live first: they are (Rune 1.0, rune.banast.as).
- **dev.banast.as** lists Rune (Released) and Blit (Beta, until it's on sale).
