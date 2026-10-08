; Python, as Sublime 4 scopes it (Packages/Python). Names are variables (An Old Hope's green),
; capitalized ones classes, builtins support; a docstring is a comment; a raw string (lowercase
; r) is a regular expression, as Sublime reads it. The highlighter splits a string's prefix and
; quotes, a regular expression's classes, %-placeholders and a format spec's colon.
; Later patterns win where two capture the same text.
(identifier) @variable.other.python
((identifier) @variable.other.constant.python (#match? @variable.other.constant.python "^_*[A-Z][A-Z0-9_]*$"))
((identifier) @support.class.python (#match? @support.class.python "^_*[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*$"))
((identifier) @support.class.exception.python (#match? @support.class.exception.python "^[A-Z][A-Za-z]*(Error|Exception|Warning|Exit|Interrupt)$"))
((identifier) @only.support.variable.magic.python (#match? @only.support.variable.magic.python "^__[a-z][a-z0-9_]*__$"))
((identifier) @support.type.python (#any-of? @support.type.python "str" "int" "float" "bool" "bytes" "list" "dict" "set" "tuple" "frozenset" "object" "type" "complex" "bytearray" "memoryview"))
((identifier) @support.function.builtin.python (#any-of? @support.function.builtin.python "abs" "all" "any" "ascii" "bin" "breakpoint" "callable" "chr" "compile" "delattr" "dir" "divmod" "enumerate" "eval" "exec" "filter" "format" "getattr" "globals" "hasattr" "hash" "help" "hex" "id" "input" "isinstance" "issubclass" "iter" "len" "locals" "map" "max" "min" "next" "oct" "open" "ord" "pow" "print" "range" "repr" "reversed" "round" "setattr" "slice" "sorted" "sum" "super" "vars" "zip" "__import__"))
; After a dot, a lowercase name is the object's own (re.compile isn't the builtin).
((attribute attribute: (identifier) @variable.other.python) (#match? @variable.other.python "^_*[a-z]"))

(call function: (identifier) @variable.function.python)
((call function: (attribute attribute: (identifier) @variable.function.python)) (#match? @variable.function.python "^_*[a-z]"))
((call function: (identifier) @support.class.python) (#match? @support.class.python "^_*[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*$"))
((call function: (identifier) @support.type.python) (#any-of? @support.type.python "str" "int" "float" "bool" "bytes" "list" "dict" "set" "tuple" "frozenset" "object" "type" "complex" "bytearray" "memoryview"))
((call function: (identifier) @support.function.builtin.python) (#any-of? @support.function.builtin.python "abs" "all" "any" "ascii" "bin" "breakpoint" "callable" "chr" "compile" "delattr" "dir" "divmod" "enumerate" "eval" "exec" "filter" "format" "getattr" "globals" "hasattr" "hash" "help" "hex" "id" "input" "isinstance" "issubclass" "iter" "len" "locals" "map" "max" "min" "next" "oct" "open" "ord" "pow" "print" "range" "repr" "reversed" "round" "setattr" "slice" "sorted" "sum" "super" "vars" "zip" "__import__"))

(decorator "@" @punctuation.definition.annotation.python)
(decorator (identifier) @variable.annotation.python)
(decorator (call function: (identifier) @variable.annotation.python))
(decorator (attribute attribute: (identifier) @variable.annotation.python))
(decorator (call function: (attribute attribute: (identifier) @variable.annotation.python)))

(class_definition name: (identifier) @only.entity.name.class.python)
(function_definition name: (identifier) @entity.name.function.python)
; __init__ and the like: a definition's name, and magic (only., since a magic name alone is a
; variable's, which is only. too).
((function_definition name: (identifier) @only.entity.name.function.python) (#match? @only.entity.name.function.python "^__.+__$"))
((function_definition name: (identifier) @only.support.function.magic.python) (#match? @only.support.function.magic.python "^__.+__$"))

(parameters (identifier) @variable.parameter.python)
(parameters (typed_parameter (identifier) @variable.parameter.python))
(parameters (default_parameter name: (identifier) @variable.parameter.python))
(parameters (typed_default_parameter name: (identifier) @variable.parameter.python))
(parameters (list_splat_pattern (identifier) @variable.parameter.python))
(parameters (dictionary_splat_pattern (identifier) @variable.parameter.python))
(lambda_parameters (identifier) @variable.parameter.python)
(keyword_argument name: (identifier) @variable.parameter.python)
(keyword_separator) @storage.modifier.named-args-only.python
((identifier) @variable.language.this.python (#any-of? @variable.language.this.python "self" "cls"))

(import_from_statement module_name: (dotted_name (identifier) @only.meta.import-name.python))
(import_from_statement module_name: (relative_import (dotted_name (identifier) @only.meta.import-name.python)))

(none) @constant.language.null.python
(true) @constant.language.boolean.true.python
(false) @constant.language.boolean.false.python
(ellipsis) @constant.language.ellipsis.python
(integer) @constant.numeric.value.python
(float) @constant.numeric.value.python

(comment) @comment.line.number-sign.python
((comment) @comment.line.shebang.python (#match? @comment.line.shebang.python "^#!"))

(string) @string.quoted.double.python
((string) @string.quoted.single.python (#match? @string.quoted.single.python "^[a-zA-Z]*'"))
(escape_sequence) @constant.character.escape.python
(interpolation) @clear.meta.interpolation.python
(interpolation ["{" "}"] @punctuation.section.interpolation.python)
(format_specifier) @constant.other.format-spec.python
(type_conversion) @storage.modifier.conversion.python
((string (string_start) @_start (string_content) @clear.source.regexp.python) (#match? @_start "^[bB]?r"))
(module . (comment)* . (expression_statement (string) @comment.block.documentation.python))
(class_definition body: (block . (expression_statement (string) @comment.block.documentation.python)))
(function_definition body: (block . (expression_statement (string) @comment.block.documentation.python)))

"def" @keyword.declaration.function.python
"class" @keyword.declaration.class.python
"lambda" @storage.type.function.inline.python
"lambda" @keyword.declaration.function.inline.python
"async" @keyword.declaration.async.python
["if" "elif" "else"] @keyword.control.conditional.python
["for" "while"] @keyword.control.loop.python
(for_statement "in" @keyword.control.loop.in.python)
(for_in_clause "in" @keyword.control.loop.in.python)
["return" "yield" "await" "break" "continue" "pass" "raise"] @keyword.control.flow.python
["try" "except" "finally"] @keyword.control.exception.python
["import" "from"] @keyword.control.import.python
"as" @keyword.control.as.python
"with" @keyword.control.context.with.python
["global" "nonlocal" "del" "assert"] @keyword.other.python
["and" "or" "not" "is"] @keyword.operator.logical.python
(comparison_operator "in" @keyword.operator.logical.python)
