; .gitignore, as Sublime 4 scopes it (Packages/Git Formats/Git Ignore): patterns are unquoted
; strings, with their globs; the highlighter marks a pattern's dots as separators.
(comment) @comment.line.git
(pattern) @string.unquoted.git.ignore
(pattern) @entity.name.pattern.git.ignore
(directory_separator) @punctuation.separator.path.glob.git
[(wildcard_chars) (wildcard_chars_allow_slash) (wildcard_char_single)] @constant.other.wildcard.asterisk.glob.git
(negation) @keyword.operator.logical.path.glob.git.ignore
(bracket_expr) @meta.character-class.glob.git
(bracket_expr "[" @punctuation.definition.character-class.begin.glob.git)
(bracket_expr "]" @punctuation.definition.character-class.end.glob.git)
(bracket_char) @constant.character.character-class.glob.git
(pattern_char_escaped) @constant.character.escape.path.glob.git
