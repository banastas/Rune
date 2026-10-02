; Java, as Sublime 4 scopes it (Packages/Java): names are variables, types and capitalized
; names classes, declared names as Sublime declares them, ALL_CAPS constants. Later patterns win
; where two capture the same text.
(identifier) @variable.other.java
(this) @variable.language.this.java
(super) @variable.language.super.java
((identifier) @support.class.java (#match? @support.class.java "^[A-Z]([A-Za-z0-9]*[a-z][A-Za-z0-9]*)?$"))
((identifier) @constant.other.java (#match? @constant.other.java "^[A-Z][A-Z0-9_]+$"))
(type_identifier) @support.class.java
((type_identifier) @storage.type.variant.java (#eq? @storage.type.variant.java "var"))
[(integral_type) (floating_point_type) (boolean_type)] @storage.type.primitive.java
(void_type) @storage.type.void.java
(dimensions) @storage.modifier.array.java

(package_declaration (scoped_identifier name: (identifier) @only.entity.name.namespace.package.java))
(package_declaration (identifier) @only.entity.name.namespace.package.java)
(import_declaration (scoped_identifier name: (identifier) @entity.name.class.java))
(class_declaration name: (identifier) @entity.name.class.java)
(record_declaration name: (identifier) @entity.name.class.java)
(interface_declaration name: (identifier) @only.entity.name.interface.java)
(enum_declaration name: (identifier) @only.entity.name.enum.java)
(enum_constant name: (identifier) @only.entity.name.constant.java)
(superclass (type_identifier) @entity.other.inherited-class.java)
(superclass (generic_type (type_identifier) @entity.other.inherited-class.java))
(super_interfaces (type_list (type_identifier) @entity.other.inherited-class.java))
(super_interfaces (type_list (generic_type (type_identifier) @entity.other.inherited-class.java)))
(field_declaration declarator: (variable_declarator name: (identifier) @variable.other.member.java))
((field_declaration declarator: (variable_declarator name: (identifier) @only.entity.name.constant.java)) (#match? @only.entity.name.constant.java "^[A-Z][A-Z0-9_]+$"))
(constructor_declaration name: (identifier) @only.entity.name.function.constructor.java)
(method_declaration name: (identifier) @entity.name.function.java)
(formal_parameter name: (identifier) @variable.parameter.java)
(spread_parameter (variable_declarator name: (identifier) @variable.parameter.java))
(catch_formal_parameter name: (identifier) @variable.parameter.java)
(lambda_expression parameters: (identifier) @variable.parameter.java)
(inferred_parameters (identifier) @variable.parameter.java)
(method_invocation name: (identifier) @variable.function.java)
(method_reference "::" . (identifier) @variable.function.reference.java)
(marker_annotation "@" @punctuation.definition.annotation.java)
(marker_annotation name: (identifier) @only.variable.annotation.java)
(annotation "@" @punctuation.definition.annotation.java)
(annotation name: (identifier) @only.variable.annotation.java)

(null_literal) @constant.language.null.java
(true) @constant.language.boolean.true.java
(false) @constant.language.boolean.false.java
[(decimal_integer_literal) (hex_integer_literal) (octal_integer_literal) (binary_integer_literal)] @constant.numeric.value.java
[(decimal_floating_point_literal) (hex_floating_point_literal)] @constant.numeric.value.java
(character_literal) @string.quoted.single.java
(string_literal) @string.quoted.double.java
(escape_sequence) @constant.character.escape.java
(line_comment) @comment.line.double-slash.java
(block_comment) @comment.block.java
((block_comment) @comment.block.documentation.java (#match? @comment.block.documentation.java "^/[*][*]"))

"package" @keyword.declaration.namespace.package.java
"import" @keyword.declaration.import.java
["public" "private" "protected" "static" "final" "abstract" "synchronized" "native" "transient" "volatile" "strictfp" "sealed" "non-sealed"] @storage.modifier.java
"class" @keyword.declaration.class.java
"interface" @keyword.declaration.interface.java
"enum" @keyword.declaration.enum.java
"record" @keyword.declaration.record.java
"extends" @storage.modifier.extends.java
"implements" @storage.modifier.implements.java
"throws" @storage.modifier.throws.java
"new" @keyword.other.storage.new.java
["if" "else" "switch" "case" "default"] @keyword.control.conditional.java
["for" "while" "do"] @keyword.control.loop.java
["return" "break" "continue" "throw" "yield"] @keyword.control.flow.java
["try" "catch" "finally"] @keyword.control.exception.java
"assert" @keyword.control.flow.assert.java
"instanceof" @keyword.operator.word.instanceof.java
