; TypeScript, as Sublime 4 scopes it (Packages/JavaScript/TypeScript), for .ts and, with jsx.scm
; after it, .tsx files: JavaScript's query, adapted to TypeScript's grammar (its parameters,
; fields and class names are nodes of their own), then the types and TypeScript's keywords.
; Later patterns win where two capture the same text.
(identifier) @variable.other.readwrite.js
((identifier) @variable.other.constant.js (#match? @variable.other.constant.js "^[A-Z][A-Z0-9_]+$"))
(member_expression property: (property_identifier) @meta.property.object.js)
(member_expression object: (identifier) @_process property: (property_identifier) @support.constant.node.js (#eq? @_process "process"))
(public_field_definition name: (property_identifier) @variable.other.readwrite.js)
(pair key: (property_identifier) @meta.mapping.key.js)
(shorthand_property_identifier) @variable.other.readwrite.js
(shorthand_property_identifier_pattern) @variable.other.readwrite.js
(private_property_identifier) @variable.other.readwrite.js
; A capitalized name before a dot is a class to Sublime (Status.Idle), unless it's all capitals.
(member_expression object: (identifier) @support.class.js (#match? @support.class.js "^[A-Z][A-Za-z0-9_]*[a-z]"))

(required_parameter pattern: (identifier) @variable.parameter.function.js)
(optional_parameter pattern: (identifier) @variable.parameter.function.js)
(required_parameter pattern: (array_pattern (identifier) @variable.parameter.function.js))
(required_parameter pattern: (object_pattern (shorthand_property_identifier_pattern) @variable.parameter.function.js))
(required_parameter pattern: (object_pattern (object_assignment_pattern left: (shorthand_property_identifier_pattern) @variable.parameter.function.js)))
(member_expression property: (private_property_identifier) @only.meta.property.object.js)
(arrow_function parameter: (identifier) @variable.parameter.function.js)

(function_declaration name: (identifier) @entity.name.function.js)
(function_expression name: (identifier) @entity.name.function.js)
(generator_function_declaration name: (identifier) @entity.name.function.js)
(method_definition name: (property_identifier) @entity.name.function.js)
(method_definition name: (private_property_identifier) @entity.name.function.js)
((method_definition name: (property_identifier) @entity.name.function.constructor.js) (#eq? @entity.name.function.constructor.js "constructor"))
; Sublime reads an arrow function with a return type as any other value.
(variable_declarator name: (identifier) @entity.name.function.js value: [(function_expression) (arrow_function !return_type)])

(call_expression function: (identifier) @variable.function.js)
(call_expression function: (member_expression property: (property_identifier) @variable.function.js))

(new_expression constructor: (identifier) @support.class.js)

((identifier) @support.type.object.console.js (#eq? @support.type.object.console.js "console"))
((identifier) @support.constant.builtin.js (#any-of? @support.constant.builtin.js "Math" "JSON" "Reflect" "Atomics" "Intl" "globalThis"))
((identifier) @support.class.builtin.js (#any-of? @support.class.builtin.js "Array" "Object" "Map" "Set" "WeakMap" "WeakSet" "Date" "Promise" "RegExp" "Error" "TypeError" "RangeError" "SyntaxError" "Number" "String" "Boolean" "Symbol" "BigInt" "Proxy"))
((identifier) @support.constant.node.js (#any-of? @support.constant.node.js "process" "module" "exports" "require" "__dirname" "__filename" "Buffer" "global"))
((identifier) @support.type.object.dom.js (#any-of? @support.type.object.dom.js "document" "window" "navigator" "location" "history" "localStorage" "sessionStorage"))
(call_expression function: (member_expression object: (identifier) @_console property: (property_identifier) @support.function.console.js) (#eq? @_console "console"))
(call_expression function: (member_expression object: (identifier) @_math property: (property_identifier) @support.function.builtin.js) (#any-of? @_math "Math" "JSON" "Object" "Array" "Date" "Number" "Promise"))
(call_expression function: (member_expression object: (identifier) @_node property: (property_identifier) @support.function.node.js) (#eq? @_node "process"))

(this) @variable.language.this.js
(super) @variable.language.super.js
(true) @constant.language.boolean.true.js
(false) @constant.language.boolean.false.js
(null) @constant.language.null.js
(undefined) @constant.language.undefined.js
(number) @constant.numeric.value.js

(comment) @comment.line.double-slash.js
((comment) @comment.block.js (#match? @comment.block.js "^/[*]"))
((comment) @comment.block.documentation.js (#match? @comment.block.documentation.js "^/[*][*]"))

(string) @string.quoted.double.js
(template_string) @string.quoted.other.js
(template_substitution) @source.js.embedded
(template_substitution ["${" "}"] @punctuation.section.interpolation.js)
(escape_sequence) @constant.character.escape.js
(regex) @string.regexp.js
(regex_flags) @keyword.other.js

["const" "let" "var"] @keyword.declaration.js
"function" @keyword.declaration.function.js
"class" @keyword.declaration.class.js
"async" @keyword.declaration.async.js
"=>" @keyword.declaration.function.arrow.js
["if" "else" "switch" "case" "default"] @keyword.control.conditional.js
["for" "while" "do" "of"] @keyword.control.loop.js
(for_in_statement "in" @keyword.control.loop.js)
["return" "throw" "break" "continue" "await" "yield"] @keyword.control.flow.js
["try" "catch" "finally"] @keyword.control.exception.js
["import" "export" "from" "as"] @keyword.control.import-export.js
(export_statement "default" @keyword.control.import-export.js)
(import_statement "type" @keyword.control.import-export.js)
(import_specifier "type" @keyword.control.import-export.js)
"static" @storage.modifier.js
"extends" @storage.modifier.extends.js
(method_definition ["get" "set"] @storage.type.accessor.js)
"new" @keyword.operator.word.new.js
["typeof" "instanceof" "void" "delete"] @keyword.operator.js

; TypeScript's own. A declaration's name is that and nothing else (`only.`): not a type
; reference too, nor a variable, which An Old Hope would color.
(class_declaration name: (type_identifier) @only.entity.name.class.js)
(abstract_class_declaration name: (type_identifier) @only.entity.name.class.js)
(class name: (type_identifier) @only.entity.name.class.js)
(extends_clause value: (identifier) @entity.other.inherited-class.js)

(type_identifier) @support.class.js
(nested_type_identifier module: (identifier) @support.class.js)
(predefined_type) @support.type.primitive.js
((predefined_type) @support.type.void.js (#eq? @support.type.void.js "void"))
((predefined_type) @support.type.unknown.js (#eq? @support.type.unknown.js "unknown"))
((predefined_type) @support.type.any.js (#eq? @support.type.any.js "any"))
((predefined_type) @support.type.never.js (#eq? @support.type.never.js "never"))
(literal_type (undefined) @support.type.primitive.undefined.js)
(literal_type (null) @support.type.primitive.null.js)
(type_parameter name: (type_identifier) @variable.parameter.type.js)
(type_predicate name: (identifier) @support.class.js)
(type_predicate "is" @keyword.operator.type.is.js)
(array_type ["[" "]"] @storage.modifier.array.js)
(union_type "|" @keyword.operator.type.union.js)
(intersection_type "&" @keyword.operator.type.intersection.js)
(as_expression "as" @keyword.operator.type.js)
(satisfies_expression "satisfies" @keyword.operator.type.js)
(function_type "=>" @keyword.declaration.function.js)
"keyof" @keyword.operator.type.js

(property_signature name: (property_identifier) @variable.other.readwrite.js)
[(property_signature "?" @storage.modifier.optional.js) (optional_parameter "?" @storage.modifier.optional.js)
 (public_field_definition "?" @storage.modifier.optional.js)]
(accessibility_modifier) @storage.modifier.js
["readonly" "abstract" "declare"] @storage.modifier.js
(override_modifier) @storage.modifier.js
"implements" @storage.modifier.implements.js

(interface_declaration "interface" @keyword.declaration.js)
(interface_declaration name: (type_identifier) @only.entity.name.interface.js)
(type_alias_declaration "type" @keyword.declaration.type.js)
(type_alias_declaration name: (type_identifier) @only.entity.name.type.js)
(enum_declaration "enum" @keyword.declaration.enum.js)
(enum_declaration name: (identifier) @only.entity.name.enum.js)
(enum_body (property_identifier) @variable.other.readwrite.js)
(enum_assignment name: (property_identifier) @variable.other.readwrite.js)
["namespace" "module"] @keyword.declaration.namespace.js
