; Git's config files, as Sublime 4 scopes them (Packages/Git Formats/Git Config): sections in
; brackets, keys and values as unquoted strings, booleans as constants.
(comment) @comment.line.git
(section_header ["[" "]"] @punctuation.section.brackets.git.config)
(section_name) @entity.name.section.git.config
(variable (name) @string.unquoted.git.config)
(variable "=" @punctuation.separator.key-value.git.config)
(variable value: (string) @string.unquoted.value.git.config)
((variable value: (string) @string.quoted.double.git.config) (#match? @string.quoted.double.git.config "^\""))
(variable value: [(true) (false)] @constant.language.git.config)
(variable value: (integer) @string.unquoted.value.git.config)
(section_header "\"" @punctuation.definition.string.git.config)
(subsection_name) @string.quoted.double.git.config
