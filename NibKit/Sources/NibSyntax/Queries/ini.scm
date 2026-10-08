; INI, which Sublime doesn't color (HL8: Nib's own): as Sublime colors Git's config files, which
; are the same format. Sections a heading, keys and values unquoted strings; the highlighter
; marks a value's booleans and quotes.
(comment) @comment.line.ini
(section_name ["[" "]"] @punctuation.section.brackets.ini)
(section_name (text) @entity.name.section.ini)
(setting_name) @string.unquoted.ini
(setting "=" @punctuation.separator.key-value.ini)
(setting_value) @string.unquoted.value.ini
