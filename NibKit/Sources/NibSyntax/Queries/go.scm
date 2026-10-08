; Go, as Sublime 4 scopes it (Packages/Go): names are variables, types storage types, builtins
; support. A struct tag is an annotation, and a string's %-verbs placeholders (split by the
; highlighter). Later patterns win where two capture the same text.
(identifier) @variable.other.go
((identifier) @variable.language.anonymous.go (#eq? @variable.language.anonymous.go "_"))
(field_identifier) @variable.other.member.go
(package_identifier) @variable.other.go
(package_clause (package_identifier) @only.entity.name.namespace.go)

(const_spec name: (identifier) @variable.other.constant.declaration.go)
(var_spec name: (identifier) @variable.other.readwrite.declaration.go)
(short_var_declaration left: (expression_list (identifier) @variable.other.readwrite.declaration.go))
(range_clause left: (expression_list (identifier) @variable.other.readwrite.declaration.go))
(field_declaration name: (field_identifier) @variable.other.member.declaration.go)

(type_identifier) @storage.type.go
((type_identifier) @support.type.builtin.go (#any-of? @support.type.builtin.go "any" "bool" "byte" "comparable" "complex64" "complex128" "error" "float32" "float64" "int" "int8" "int16" "int32" "int64" "rune" "string" "uint" "uint8" "uint16" "uint32" "uint64" "uintptr"))
(type_spec name: (type_identifier) @only.entity.name.type.go)
; A composite literal's type is a variable to Sublime (&client{…}, &http.Client{…}).
(composite_literal type: (type_identifier) @variable.other.go)
(composite_literal type: (qualified_type name: (type_identifier) @variable.other.member.go))

(function_declaration name: (identifier) @entity.name.function.go)
(method_declaration name: (field_identifier) @entity.name.function.go)
(method_elem name: (field_identifier) @entity.name.function.go)
(parameter_declaration name: (identifier) @variable.parameter.go)
(variadic_parameter_declaration name: (identifier) @variable.parameter.go)
(call_expression function: (identifier) @variable.function.go)
(call_expression function: (selector_expression field: (field_identifier) @variable.function.go))
((call_expression function: (identifier) @support.function.builtin.go) (#any-of? @support.function.builtin.go "append" "cap" "clear" "close" "complex" "copy" "delete" "imag" "len" "make" "max" "min" "new" "panic" "print" "println" "real" "recover"))

(nil) @constant.language.null.go
(true) @constant.language.boolean.true.go
(false) @constant.language.boolean.false.go
(iota) @constant.numeric.iota.go
[(int_literal) (float_literal) (imaginary_literal)] @constant.numeric.value.go
(rune_literal) @string.quoted.single.go
(interpreted_string_literal) @string.quoted.double.go
(raw_string_literal) @string.quoted.backtick.go
(field_declaration tag: (raw_string_literal) @meta.annotation.go)
(escape_sequence) @constant.character.escape.go
(comment) @comment.line.double-slash.go
((comment) @comment.block.go (#match? @comment.block.go "^/[*]"))

"package" @keyword.declaration.namespace.go
"import" @keyword.other.import.go
"const" @keyword.declaration.const.go
"var" @keyword.declaration.var.go
"type" @keyword.declaration.type.go
"struct" @keyword.declaration.struct.go
"interface" @keyword.declaration.interface.go
"func" @keyword.declaration.function.go
["map" "chan"] @keyword.declaration.go
["return" "for" "defer" "go" "goto" "fallthrough" "select"] @keyword.control.go
["if" "else" "switch" "case" "default"] @keyword.control.conditional.go
["break" "continue"] @keyword.control.flow.go
"range" @keyword.other.go
