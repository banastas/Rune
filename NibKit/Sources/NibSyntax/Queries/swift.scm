; Swift, whose colors are Nib's own (HL8: Sublime has no Swift). Its scopes are the ones
; Sublime gives the same things in its other languages, so a scheme colors Swift as it colors
; them: keywords and modifiers keywords, types storage types (the standard library's support),
; a function's name a function and a call a call (a capitalized call a class, an initializer),
; parameters and call labels parameters (as Python's keyword arguments), other names
; variables, attributes annotations (as Java's), a class's name a class (and a struct's, an
; enum's or a protocol's plain, as TypeScript's and Rust's are). Later patterns win where two
; capture the same text.
(simple_identifier) @variable.other.swift
(type_identifier) @storage.type.swift
((type_identifier) @support.type.swift (#any-of? @support.type.swift "Int" "Int8" "Int16" "Int32" "Int64" "UInt" "UInt8" "UInt16" "UInt32" "UInt64" "Double" "Float" "CGFloat" "Bool" "String" "Substring" "Character" "Array" "ArraySlice" "Dictionary" "Set" "Optional" "Result" "Void" "Any" "AnyObject" "Never" "Error" "Range" "ClosedRange" "Sequence" "Collection" "Equatable" "Hashable" "Comparable" "Identifiable" "Codable" "Encodable" "Decodable" "Sendable" "CustomStringConvertible" "Task" "AsyncSequence" "URL" "Data" "Date" "UUID" "TimeInterval"))
(self_expression) @variable.language.this.swift
(super_expression) @variable.language.super.swift
(navigation_suffix (simple_identifier) @variable.other.member.swift)
(prefix_expression (simple_identifier) @variable.other.member.swift)
((navigation_expression . (simple_identifier) @storage.type.swift) (#match? @storage.type.swift "^[A-Z]"))
(property_declaration (pattern (simple_identifier) @variable.other.readwrite.declaration.swift))
(enum_entry (simple_identifier) @variable.other.member.declaration.swift)
(enum_type_parameters (simple_identifier) @variable.parameter.swift)
; A closure's $0, $1: its parameters, wherever they are.
((simple_identifier) @variable.parameter.swift (#match? @variable.parameter.swift "^[$][0-9]+$"))

(class_declaration declaration_kind: "class" name: (type_identifier) @only.entity.name.class.swift)
(class_declaration declaration_kind: "actor" name: (type_identifier) @only.entity.name.class.swift)
(class_declaration declaration_kind: "struct" name: (type_identifier) @only.entity.name.struct.swift)
(class_declaration declaration_kind: "enum" name: (type_identifier) @only.entity.name.enum.swift)
(protocol_declaration name: (type_identifier) @only.entity.name.interface.swift)
(typealias_declaration name: (type_identifier) @only.entity.name.type.swift)
(type_parameter (type_identifier) @variable.parameter.type.swift)

(function_declaration name: (simple_identifier) @entity.name.function.swift)
(protocol_function_declaration name: (simple_identifier) @entity.name.function.swift)
(parameter external_name: (simple_identifier) @variable.parameter.swift)
(parameter name: (simple_identifier) @variable.parameter.swift)
(lambda_parameter (simple_identifier) @variable.parameter.swift)
(value_argument (value_argument_label (simple_identifier) @variable.parameter.swift))
(call_expression (simple_identifier) @variable.function.swift)
(call_expression (navigation_expression (navigation_suffix (simple_identifier) @variable.function.swift)))
((call_expression (simple_identifier) @support.class.swift) (#match? @support.class.swift "^[A-Z]"))
((call_expression (navigation_expression (navigation_suffix (simple_identifier) @support.class.swift))) (#match? @support.class.swift "^[A-Z]"))
((call_expression (simple_identifier) @support.function.builtin.swift) (#any-of? @support.function.builtin.swift "print" "debugPrint" "dump" "min" "max" "abs" "zip" "stride" "sequence" "repeatElement" "assert" "assertionFailure" "precondition" "preconditionFailure" "fatalError" "type" "swap" "withUnsafePointer" "withUnsafeMutablePointer" "withExtendedLifetime" "readLine" "isKnownUniquelyReferenced"))

(attribute "@" @punctuation.definition.annotation.swift)
(attribute (user_type (type_identifier) @only.variable.annotation.swift))
[(visibility_modifier) (member_modifier) (function_modifier) (property_modifier) (parameter_modifier) (inheritance_modifier) (mutation_modifier) (ownership_modifier)] @storage.modifier.swift

[(integer_literal) (real_literal) (hex_literal) (oct_literal) (bin_literal)] @constant.numeric.value.swift
(boolean_literal) @constant.language.boolean.swift
"nil" @constant.language.null.swift
(line_string_literal) @string.quoted.double.swift
(multi_line_string_literal) @string.quoted.double.block.swift
(raw_string_literal) @string.quoted.other.raw.swift
(str_escaped_char) @constant.character.escape.swift
(interpolated_expression) @clear.meta.interpolation.swift
(line_string_literal ["\\(" ")"] @clear.punctuation.section.interpolation.swift)
(multi_line_string_literal ["\\(" ")"] @clear.punctuation.section.interpolation.swift)
(regex_literal) @string.regexp.swift
(comment) @comment.line.double-slash.swift
((comment) @comment.line.documentation.swift (#match? @comment.line.documentation.swift "^///"))
(multiline_comment) @comment.block.swift
(statement_label) @entity.name.label.swift

"import" @keyword.declaration.import.swift
["func" "init" "deinit" "subscript"] @keyword.declaration.function.swift
["let" "var"] @keyword.declaration.variable.swift
["struct" "class" "enum" "protocol" "extension" "actor" "typealias" "associatedtype"] @keyword.declaration.type.swift
"case" @keyword.control.conditional.case.swift
["if" "guard" "switch" (else) (default_keyword)] @keyword.control.conditional.swift
["for" "while" "repeat" "in"] @keyword.control.loop.swift
["return" "break" "continue" "fallthrough" (throw_keyword)] @keyword.control.flow.swift
[(try_operator) "do" (catch_keyword)] @keyword.control.exception.swift
; The grammar reads `defer { … }` as a call with a closure: the name is the keyword.
((simple_identifier) @keyword.control.exception.swift (#eq? @keyword.control.exception.swift "defer"))
["async" "await" (throws)] @keyword.control.async.swift
(where_keyword) @keyword.other.where.swift
["some" "any"] @storage.modifier.swift
(as_operator) @keyword.operator.type.swift
["#if" "#elseif" "#else" "#endif"] @keyword.control.directive.swift
(macro_invocation "#" @keyword.control.directive.swift (simple_identifier) @keyword.control.directive.swift)
