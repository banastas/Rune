; Diffs, as Sublime 4 scopes them (Packages/Diff). A line's text after its mark is a hidden
; token, so whole lines are captured and the highlighter splits the rest: a hunk's section
; after the second @@, a range's sign and comma, a path's slashes, /dev/null.
(old_file) @meta.diff.header.from-file
(old_file "---" @punctuation.definition.from-file.diff)
(old_file (filename) @meta.header.from-file.diff)
(new_file) @meta.diff.header.to-file
(new_file "+++" @punctuation.definition.to-file.diff)
(new_file (filename) @meta.header.to-file.diff)

(location) @meta.diff.range.unified
(location "@@" @punctuation.definition.range.diff)
(linerange) @meta.range.unified.diff

(deletion) @markup.deleted.diff
(deletion ["-" "--" "<"] @punctuation.definition.deleted.diff)
(addition) @markup.inserted.diff
(addition ["+" "++" ">"] @punctuation.definition.inserted.diff)
(change) @markup.changed.diff
(special) @comment.line.diff
(special "\\" @punctuation.definition.comment.begin.diff)
(comment) @comment.line.number-sign.diff
