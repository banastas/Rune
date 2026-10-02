; Rust, as Sublime 4 scopes it (Packages/Rust): names are variables, types and capitalized names
; storage types (the standard library's support), declared names plain, ALL_CAPS constants. A
; format macro's {} placeholders and a number's type suffix are split by the highlighter.
; Later patterns win where two capture the same text.
(identifier) @variable.other.rust
(field_identifier) @variable.other.rust
(shorthand_field_identifier) @variable.other.rust
(self) @variable.language.rust
((identifier) @storage.type.rust (#match? @storage.type.rust "^[A-Z]([A-Za-z0-9]*[a-z][A-Za-z0-9]*)?$"))
((identifier) @constant.other.rust (#match? @constant.other.rust "^[A-Z][A-Z0-9_]+$"))
(type_identifier) @storage.type.rust
(primitive_type) @storage.type.rust
((type_identifier) @support.type.rust (#any-of? @support.type.rust "String" "Vec" "Option" "Result" "Box" "HashMap" "HashSet" "BTreeMap" "BTreeSet" "VecDeque" "Rc" "Arc" "RefCell" "Cell" "Mutex" "Clone" "Copy" "Debug" "Default" "Display" "Send" "Sync" "Sized" "Iterator" "IntoIterator" "Fn" "FnMut" "FnOnce" "From" "Into" "PartialEq" "Eq" "PartialOrd" "Ord" "Hash" "Drop" "ToString" "AsRef"))
((identifier) @support.type.rust (#any-of? @support.type.rust "Some" "None" "Ok" "Err" "String" "Vec" "Option" "Result" "Box" "HashMap" "HashSet" "BTreeMap" "BTreeSet" "VecDeque" "Rc" "Arc" "RefCell" "Cell" "Mutex"))
(field_declaration name: (field_identifier) @variable.other.member.rust)

(const_item name: (identifier) @only.entity.name.constant.rust)
(static_item name: (identifier) @only.entity.name.constant.rust)
(struct_item name: (type_identifier) @only.entity.name.struct.rust)
(enum_item name: (type_identifier) @only.entity.name.enum.rust)
(union_item name: (type_identifier) @only.entity.name.union.rust)
(trait_item name: (type_identifier) @only.entity.name.trait.rust)
(type_item name: (type_identifier) @only.entity.name.type.rust)
(impl_item type: (type_identifier) @only.entity.name.impl.rust)
(impl_item type: (generic_type type: (type_identifier) @only.entity.name.impl.rust))
(mod_item name: (identifier) @only.entity.name.module.rust)
(function_item name: (identifier) @entity.name.function.rust)
(function_signature_item name: (identifier) @entity.name.function.rust)
(parameter pattern: (identifier) @variable.parameter.rust)
(self_parameter (self) @variable.parameter.rust)
(closure_parameters (identifier) @variable.parameter.rust)
(call_expression function: (identifier) @variable.function.rust)
(call_expression function: (scoped_identifier name: (identifier) @variable.function.rust))
(call_expression function: (field_expression field: (field_identifier) @variable.function.rust))
(call_expression function: (generic_function function: (identifier) @variable.function.rust))
(call_expression function: (generic_function function: (scoped_identifier name: (identifier) @variable.function.rust)))
(call_expression function: (generic_function function: (field_expression field: (field_identifier) @variable.function.rust)))
; A tuple struct or variant called is a type (Some(x), Lookup::Fresh(x)), as written.
((call_expression function: (identifier) @storage.type.rust) (#match? @storage.type.rust "^[A-Z]"))
((call_expression function: (scoped_identifier name: (identifier) @storage.type.rust)) (#match? @storage.type.rust "^[A-Z]"))
((call_expression function: (identifier) @support.type.rust) (#any-of? @support.type.rust "Some" "Ok" "Err"))
((struct_expression name: (type_identifier) @keyword.other.rust) (#eq? @keyword.other.rust "Self"))

(macro_invocation macro: (identifier) @only.support.macro.rust)
(macro_invocation "!" @support.macro.rust)
(macro_invocation (token_tree (string_literal) @meta.format.rust))
(attribute_item "#" @punctuation.definition.annotation.rust)
(inner_attribute_item ["#" "!"] @punctuation.definition.annotation.rust)
(attribute (identifier) @variable.annotation.rust)
(attribute arguments: (token_tree (identifier) @only.meta.annotation.parameters.rust))
(lifetime) @storage.modifier.lifetime.rust
(lifetime (identifier) @only.storage.modifier.lifetime.rust)
(visibility_modifier) @storage.modifier.rust
(mutable_specifier) @storage.modifier.rust

(integer_literal) @constant.numeric.integer.decimal.rust
(float_literal) @constant.numeric.float.rust
(boolean_literal) @constant.language.boolean.rust
(string_literal) @string.quoted.double.rust
(raw_string_literal) @string.quoted.other.raw.rust
(char_literal) @string.quoted.single.rust
(escape_sequence) @constant.character.escape.rust
(line_comment) @comment.line.double-slash.rust
(line_comment [(doc_comment) (outer_doc_comment_marker) (inner_doc_comment_marker)]) @comment.line.documentation.rust
(block_comment) @comment.block.rust

"let" @keyword.declaration.variable.rust
["const" "static"] @keyword.declaration.variable.constant.rust
"fn" @keyword.declaration.function.rust
"struct" @keyword.declaration.struct.rust
"enum" @keyword.declaration.enum.rust
"impl" @keyword.declaration.impl.rust
"trait" @keyword.declaration.trait.rust
"type" @keyword.declaration.type.rust
"mod" @keyword.declaration.module.rust
"use" @keyword.declaration.import.rust
["if" "else" "match" "for" "while" "loop" "return" "break" "continue" "in" "await" "yield"] @keyword.control.rust
["as" "where" "unsafe" "async" "move" "dyn" "ref" "extern"] @keyword.other.rust
[(crate) (super)] @keyword.other.rust
"pub" @storage.modifier.rust
