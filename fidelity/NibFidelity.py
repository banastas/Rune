# Nib's fidelity harness (PRD HL7, S3): every token's scope and colour in the reference
# files, as Sublime renders them with An Old Hope · Nib. Run by fidelity/run.sh:
#
#   subl --command 'nib_fidelity_dump {"files": [...], "out": "..."}'
#
# Opens the files in a window of its own, sets the scheme on those views only, writes
# <out>/<file>.json for each, and closes them. Sublime's own settings are left alone.

import json
import os

import sublime
import sublime_plugin

SCHEME = "Packages/User/an-old-hope-nib.tmTheme"


class NibFidelityDumpCommand(sublime_plugin.ApplicationCommand):
    def run(self, files=[], out=""):
        sublime.run_command("new_window")
        window = sublime.active_window()
        pending = list(files)

        def next_file():
            if not pending:
                window.run_command("close_window")
                with open(os.path.join(out, "done"), "w") as f:
                    f.write("ok\n")
                return
            path = pending.pop(0)
            view = window.open_file(path)
            view.settings().set("color_scheme", SCHEME)
            wait(view, path, 0)

        def wait(view, path, tries):
            # Loaded, then a moment for the syntax to tokenize the whole file.
            if view.is_loading() or tries < 5:
                sublime.set_timeout(lambda: wait(view, path, tries + 1), 100)
                return
            dump(view, path)
            view.set_scratch(True)
            view.close()
            next_file()

        def dump(view, path):
            text = view.substr(sublime.Region(0, view.size()))
            tokens = []
            for region, scope in view.extract_tokens_with_scopes(sublime.Region(0, view.size())):
                style = view.style_for_scope(scope)
                tokens.append([region.begin(), region.end(), scope.strip(), style.get("foreground"),
                               style.get("background"), bool(style.get("bold")), bool(style.get("italic"))])
            result = {"file": os.path.basename(path), "syntax": view.syntax().name if view.syntax() else None,
                      "scheme": view.settings().get("color_scheme"), "text": text, "tokens": tokens}
            with open(os.path.join(out, os.path.basename(path) + ".json"), "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=0)

        next_file()
