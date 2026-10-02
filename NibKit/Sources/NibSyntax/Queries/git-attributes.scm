; .gitattributes, as Sublime 4 scopes it (Packages/Git Formats/Git Attributes): patterns as in
; .gitignore, then each attribute's name and value.
(comment) @comment.line.git
(pattern) @string.unquoted.git.attributes
(pattern) @entity.name.pattern.git.attributes
(dir_sep) @punctuation.separator.path.glob.git
(wildcard) @constant.other.wildcard.asterisk.glob.git
[(builtin_attr) (attr_name)] @variable.language.attribute.git.attributes
(attr_set) @punctuation.separator.key-value.git.attributes
(attr_unset) @keyword.operator.logical.git.attributes
[(string_value) (boolean_value)] @string.unquoted.git.attributes
; [attr]: the brackets plain, the word a string (split by the highlighter).
(macro_tag) @meta.brackets.git.attributes
