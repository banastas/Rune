; YAML, as Sublime 4 scopes it (Packages/YAML): keys and values alike are strings (An Old Hope's
; key rule, written for Sublime 3's entity.name.tag.yaml, doesn't apply, as JSON's doesn't).
(comment) @comment.line.number-sign.yaml
(string_scalar) @string.unquoted.plain.out.yaml
(flow_sequence (flow_node (plain_scalar (string_scalar) @string.unquoted.plain.in.yaml)))
(flow_mapping (flow_node (plain_scalar (string_scalar) @string.unquoted.plain.in.yaml)))
(double_quote_scalar) @string.quoted.double.yaml
(single_quote_scalar) @string.quoted.single.yaml
(escape_sequence) @constant.character.escape.yaml
(block_scalar) @string.unquoted.block.yaml
((block_scalar [">" "|"] @keyword.control.flow.block-scalar.yaml))
(integer_scalar) @constant.numeric.value.yaml
(float_scalar) @constant.numeric.value.yaml
(boolean_scalar) @constant.language.boolean.yaml
(null_scalar) @constant.language.null.yaml
((block_mapping_pair key: (flow_node (plain_scalar (string_scalar) @constant.language.merge.yaml))) (#eq? @constant.language.merge.yaml "<<"))

[(block_mapping_pair ":" @punctuation.separator.key-value.mapping.yaml) (flow_pair ":" @punctuation.separator.key-value.mapping.yaml)]
(block_sequence_item "-" @punctuation.definition.block.sequence.item.yaml)
(flow_sequence ["[" "]"] @punctuation.definition.sequence.yaml)
(flow_sequence "," @punctuation.separator.sequence.yaml)
(flow_mapping ["{" "}"] @punctuation.definition.mapping.yaml)
(flow_mapping "," @punctuation.separator.mapping.yaml)

(anchor "&" @keyword.control.property.anchor.yaml)
(anchor_name) @entity.name.other.anchor.yaml
(alias "*" @keyword.control.flow.alias.yaml)
(alias_name) @variable.other.alias.yaml
(tag) @storage.type.tag-handle.yaml
["---" "..."] @entity.other.document.yaml
