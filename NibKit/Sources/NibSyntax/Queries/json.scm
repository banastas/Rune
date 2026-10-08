; JSON, as Sublime 4 scopes it (Packages/JSON). Keys are strings in a mapping key, so An Old
; Hope's key rule (written for Sublime 3's meta.structure.dictionary.key) doesn't apply (HL7).
(pair key: (string) @meta.mapping.key.json)
(string) @string.quoted.double.json
(escape_sequence) @constant.character.escape.json
(number) @constant.numeric.value.json
(true) @constant.language.boolean.true.json
(false) @constant.language.boolean.false.json
(null) @constant.language.null.json
(comment) @comment.line.double-slash.json
