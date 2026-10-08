#!/usr/bin/env python3
"""acknowledgements.py — writes nib/Resources/Acknowledgements.txt, the third-party notices Rune
ships with, shown from Rune › About Rune › Acknowledgements (PRD DS3).

Adapted from Blit's scripts/acknowledgements.py at de24207 (no shared code, PRD §7). Built from
what Rune is built with, each from its own source at the version in use:
  - the packages the app resolves (nib.xcodeproj's Package.resolved, NibKit's among them), each
    from its checkout at the pinned revision (Xcode's, in build/DerivedData/SourcePackages):
    its LICENSE, its NOTICE (Apache 2.0 §4(d) asks for it to be passed on), and the license
    files of code it includes that its own LICENSE doesn't already contain;
  - the grammars copied into NibKit/Vendor (NibKit/Vendor/README.md), the same from each folder;
  - An Old Hope, the scheme An Old Hope · Rune is made from (themes/An-Old-Hope-LICENSE.md);
  - the fonts' OFL texts (nib/Resources/Fonts).
Nothing in the file is written by hand, so it follows what Rune ships.

Usage:
  scripts/acknowledgements.py                 # write the file
  scripts/acknowledgements.py --checkouts DIR # the package checkouts to read
  scripts/acknowledgements.py --check         # exit 1 if the file is out of date

It stops (exit 2) if a package's checkout is missing or isn't at the pinned revision, or if a
package or a vendored folder has no license file, or a vendored folder isn't listed below:
shipping without its notice isn't an option.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(ROOT, "nib.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
CHECKOUTS = os.path.join(ROOT, "build/DerivedData/SourcePackages/checkouts")
VENDOR = os.path.join(ROOT, "NibKit/Vendor")
SCHEME_LICENSE = os.path.join(ROOT, "themes/An-Old-Hope-LICENSE.md")
FONTS = os.path.join(ROOT, "nib/Resources/Fonts")
OUTPUT = os.path.join(ROOT, "nib/Resources/Acknowledgements.txt")

# How each package calls itself, by Package.resolved identity.
NAMES = {"swift-tree-sitter": "SwiftTreeSitter", "sparkle": "Sparkle"}
# The grammars in NibKit/Vendor, as NibKit/Vendor/README.md lists them: folder → (repository,
# version). A folder there that isn't here stops the script.
VENDORED = {
    "tree-sitter-c": ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2"),
    "tree-sitter-css": ("https://github.com/tree-sitter/tree-sitter-css", "0.25.0"),
    "tree-sitter-diff": ("https://github.com/tree-sitter-grammars/tree-sitter-diff", "0.2.0"),
    "tree-sitter-git-config": ("https://github.com/the-mikedavis/tree-sitter-git-config", "3a61756"),
    "tree-sitter-gitattributes": ("https://github.com/tree-sitter-grammars/tree-sitter-gitattributes", "0.1.6"),
    "tree-sitter-gitcommit": ("https://github.com/gbprod/tree-sitter-gitcommit", "0.5.0"),
    "tree-sitter-gitignore": ("https://github.com/shunsambongi/tree-sitter-gitignore", "f4685bf"),
    "tree-sitter-go": ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0"),
    "tree-sitter-ini": ("https://github.com/justinmk/tree-sitter-ini", "1.4.0"),
    "tree-sitter-java": ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5"),
    "tree-sitter-javascript": ("https://github.com/tree-sitter/tree-sitter-javascript", "0.25.0"),
    "tree-sitter-lua": ("https://github.com/tree-sitter-grammars/tree-sitter-lua", "0.5.0"),
    "tree-sitter-make": ("https://github.com/tree-sitter-grammars/tree-sitter-make", "1.1.1"),
    "tree-sitter-php": ("https://github.com/tree-sitter/tree-sitter-php", "0.25.0"),
    "tree-sitter-python": ("https://github.com/tree-sitter/tree-sitter-python", "0.25.0"),
    "tree-sitter-rst": ("https://github.com/stsewd/tree-sitter-rst", "0.2.0"),
    "tree-sitter-ruby": ("https://github.com/tree-sitter/tree-sitter-ruby", "0.23.1"),
    "tree-sitter-rust": ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2"),
    "tree-sitter-sql": ("https://github.com/DerekStride/tree-sitter-sql", "0.3.11"),
    "tree-sitter-swift": ("https://github.com/alex-pinkus/tree-sitter-swift", "0.7.3"),
    "tree-sitter-toml": ("https://github.com/tree-sitter-grammars/tree-sitter-toml", "0.7.0"),
    "tree-sitter-typescript": ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2"),
    "tree-sitter-xml": ("https://github.com/tree-sitter-grammars/tree-sitter-xml", "0.7.0"),
    "tree-sitter-yaml": ("https://github.com/tree-sitter-grammars/tree-sitter-yaml", "0.7.2"),
}
# A package's folders of code Nib doesn't link: swift-tree-sitter's Swift grammar is only its
# tests' (`TestTreeSitterSwift`); Nib's own Swift grammar is the vendored one.
NOT_SHIPPED = {"swift-tree-sitter": {"tree-sitter-swift"}}
# Folders whose license files describe code that isn't shipped.
SKIP_DIRS = {".git", ".github", "test", "tests", "Tests", "examples", "Examples", "docs", "Docs", "script",
             "scripts", "queries", "node_modules", "target", "build", "cli", "highlight", "tags", "xtask"}
RULE = "=" * 78


def fail(message):
    print(f"acknowledgements: {message}", file=sys.stderr)
    sys.exit(2)


def run(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().replace("\r\n", "\n").strip("\n")


def squash(text):
    return re.sub(r"\s+", " ", text).strip().lower()


def first_file(folder, names):
    for name in names:
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    return None


def license_name(text):
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache License 2.0"
    if "SIL OPEN FONT LICENSE" in text.upper():
        return "SIL Open Font License 1.1"
    if "DO WHAT THE FUCK YOU WANT TO" in text.upper():
        return "WTFPL"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD 3-Clause" if "Neither the name" in text else "BSD"
    if "Permission is granted to anyone to use this software for any purpose" in text:
        return "zlib"
    if "UNICODE" in text.upper() and "Permission is hereby granted" in text:
        return "Unicode License"
    return "see the text below"


def copyright_line(texts):
    notice = re.compile(r"^Copyright\s+(\(c\)|©|\d{4})", re.I)   # not "copyright notice that is…" in a license's terms
    for text in texts:
        for line in text.splitlines():
            line = line.strip()
            if notice.match(line):
                return line
    return None


def included_licenses(folder, root_license, skip=frozenset()):
    """License files of code a package or grammar includes, unless its own LICENSE already
    contains them."""
    found = []
    covered = squash(root_license)
    for directory, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not (directory == folder and d in skip))
        if directory == folder:
            continue
        for name in sorted(files):
            lower = name.lower()
            if not (lower.startswith("license") or lower.startswith("licence") or lower.startswith("copying") or lower.startswith("notice")):
                continue
            path = os.path.join(directory, name)
            text = read(path)
            if squash(text) and squash(text) not in covered:
                found.append((os.path.relpath(path, folder), text))
    return found


def entry_from(folder, name, version, url, skip=frozenset()):
    license_path = first_file(folder, ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt"])
    if not license_path:
        fail(f"{name} has no license file in {os.path.relpath(folder, ROOT)}")
    license_text = read(license_path)
    notice_path = first_file(folder, ["NOTICE", "NOTICE.txt", "NOTICE.md"])
    notice_text = read(notice_path) if notice_path else None
    return {
        "name": name,
        "version": version,
        "url": url,
        "copyright": copyright_line([t for t in (notice_text, license_text) if t]),
        "license": license_name(license_text),
        # The NOTICE first: the attributions it asks to keep, before the license's terms.
        "texts": ([("NOTICE", notice_text)] if notice_text else [])
                 + [("LICENSE", license_text)]
                 + [(f"{path} (included code)", text) for path, text in included_licenses(folder, license_text, skip)],
    }


def package_entries(checkouts):
    with open(RESOLVED) as f:
        pins = json.load(f)["pins"]
    entries = []
    for pin in pins:
        identity, location, state = pin["identity"], pin["location"], pin.get("state", {})
        folder = os.path.join(checkouts, os.path.basename(location).removesuffix(".git"))
        if not os.path.isdir(folder):
            fail(f"no checkout of {identity} at {folder} (build Rune once, or pass --checkouts)")
        head = run(["git", "-C", folder, "rev-parse", "HEAD"]).stdout.strip()
        if state.get("revision") and head != state["revision"]:
            fail(f"{identity}'s checkout is at {head[:10]}, not the pinned {state['revision'][:10]}")
        entries.append(entry_from(folder, NAMES.get(identity, identity), state.get("version") or state.get("revision", "")[:12],
                                  location.removesuffix(".git"), NOT_SHIPPED.get(identity, frozenset())))
    return entries


def vendored_entries():
    folders = sorted(d for d in os.listdir(VENDOR) if os.path.isdir(os.path.join(VENDOR, d)))
    unlisted = [d for d in folders if d not in VENDORED]
    if unlisted:
        fail("NibKit/Vendor has folders this script doesn't list: " + ", ".join(unlisted))
    gone = [d for d in VENDORED if d not in folders]
    if gone:
        fail("listed here but not in NibKit/Vendor: " + ", ".join(gone))
    return [entry_from(os.path.join(VENDOR, d), d, VENDORED[d][1], VENDORED[d][0]) for d in folders]


def scheme_entry():
    text = read(SCHEME_LICENSE)
    return {
        "name": "An Old Hope (the color scheme An Old Hope · Rune is made from)",
        "version": None,
        "url": "https://github.com/jesseleite/an-old-hope-syntax-atom",
        "copyright": copyright_line([text]),
        "license": license_name(text),
        "texts": [("LICENSE", text)],
    }


def font_entries():
    entries = []
    for name in sorted(os.listdir(FONTS)):
        if not name.endswith("-OFL.txt"):
            continue
        text = read(os.path.join(FONTS, name))
        entries.append({
            "name": name.removesuffix("-OFL.txt") + " (font)",
            "version": None,
            "url": None,
            "copyright": copyright_line([text]),
            "license": license_name(text),
            "texts": [("LICENSE", text)],
        })
    return entries


def render(entries):
    lines = [
        "NIB — ACKNOWLEDGEMENTS",
        "",
        "Rune is built with the open-source software below. Each is listed with its",
        "copyright notice and license, as its license asks. Thank you to everyone",
        "who made them.",
        "",
        "Written by scripts/acknowledgements.py from what Rune is built with;",
        "don't edit it by hand.",
    ]
    for entry in entries:
        title = entry["name"] + (f" {entry['version']}" if entry["version"] else "")
        lines += ["", RULE, title]
        if entry["url"]:
            lines.append(entry["url"])
        if entry["copyright"]:
            lines.append(entry["copyright"])
        lines += [f"License: {entry['license']}", RULE]
        for label, text in entry["texts"]:
            lines += ["", f"--- {label} ---", "", text]
    return "\n".join(lines) + "\n"


def main():
    args = sys.argv[1:]
    checkouts = CHECKOUTS
    if "--checkouts" in args:
        index = args.index("--checkouts")
        if index + 1 >= len(args):
            fail("--checkouts needs a folder")
        checkouts = args[index + 1]
    entries = (sorted(package_entries(checkouts) + vendored_entries(), key=lambda e: e["name"].lower())
               + [scheme_entry()] + font_entries())
    text = render(entries)
    current = read(OUTPUT) + "\n" if os.path.exists(OUTPUT) else None
    if "--check" in args:
        if current != text:
            print("acknowledgements: nib/Resources/Acknowledgements.txt is out of date (run scripts/acknowledgements.py)")
            sys.exit(1)
        print("acknowledgements: up to date")
        return
    if current != text:
        with open(OUTPUT, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"acknowledgements: wrote {os.path.relpath(OUTPUT, ROOT)}")
    else:
        print("acknowledgements: unchanged")
    for entry in entries:
        extra = [label for label, _ in entry["texts"] if label != "LICENSE"]
        print(f"  {entry['name'][:34]:34} {entry['version'] or '':10} {entry['license']}" + (f" · {', '.join(extra)}" if extra else ""))


if __name__ == "__main__":
    main()
