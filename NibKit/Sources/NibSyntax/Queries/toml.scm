; TOML, as Sublime 4 scopes it (Packages/TOML): table names a section, keys unquoted strings,
; dates and times constants (split by the highlighter at their separators).
(comment) @comment.line.number-sign.toml
(table ["[" "]"] @punctuation.section.brackets.toml)
(table_array_element ["[[" "]]"] @punctuation.section.brackets.toml)
(table [(bare_key) (dotted_key) (quoted_key)] @entity.name.section.toml)
(table_array_element [(bare_key) (dotted_key) (quoted_key)] @entity.name.section.toml)
(dotted_key "." @punctuation.accessor.dot.toml)
(pair [(bare_key) (dotted_key)] @string.unquoted.toml)
(pair (quoted_key) @string.quoted.double.toml)
(pair "=" @punctuation.separator.key-value.toml)

(string) @string.quoted.double.toml
((string) @string.quoted.single.toml (#match? @string.quoted.single.toml "^'"))
((string) @string.quoted.double.block.toml (#match? @string.quoted.double.block.toml "^\"\"\""))
((string) @string.quoted.single.block.toml (#match? @string.quoted.single.block.toml "^'''"))
(escape_sequence) @constant.character.escape.toml
(integer) @constant.numeric.value.toml
(float) @constant.numeric.value.toml
(boolean) @constant.language.boolean.toml
[(offset_date_time) (local_date_time) (local_date)] @constant.other.datetime.toml
(local_time) @constant.other.time.toml

(array ["[" "]"] @punctuation.section.sequence.toml)
(array "," @punctuation.separator.sequence.toml)
(inline_table ["{" "}"] @punctuation.section.mapping.toml)
(inline_table "," @punctuation.separator.sequence.toml)
