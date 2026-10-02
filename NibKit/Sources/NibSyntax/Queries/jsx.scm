; JSX, as Sublime 4 scopes it (Packages/JavaScript/JSX), after JavaScript's or TypeScript's query:
; for .jsx and .tsx files, and for JSX in a .js file, which Sublime's JavaScript doesn't read.

; Tag names: a lowercase one an element, a capitalized one (or a dotted name) a component.
((jsx_opening_element name: (identifier) @entity.name.tag.native.js) (#match? @entity.name.tag.native.js "^[a-z]"))
((jsx_closing_element name: (identifier) @entity.name.tag.native.js) (#match? @entity.name.tag.native.js "^[a-z]"))
((jsx_self_closing_element name: (identifier) @entity.name.tag.native.js) (#match? @entity.name.tag.native.js "^[a-z]"))
((jsx_opening_element name: (identifier) @entity.name.tag.component.js) (#match? @entity.name.tag.component.js "^[^a-z]"))
((jsx_closing_element name: (identifier) @entity.name.tag.component.js) (#match? @entity.name.tag.component.js "^[^a-z]"))
((jsx_self_closing_element name: (identifier) @entity.name.tag.component.js) (#match? @entity.name.tag.component.js "^[^a-z]"))
(jsx_opening_element name: (member_expression [(identifier) (property_identifier)] @entity.name.tag.component.js))
(jsx_closing_element name: (member_expression [(identifier) (property_identifier)] @entity.name.tag.component.js))
(jsx_self_closing_element name: (member_expression [(identifier) (property_identifier)] @entity.name.tag.component.js))
(jsx_opening_element name: (member_expression (member_expression [(identifier) (property_identifier)] @entity.name.tag.component.js)))
(jsx_self_closing_element name: (member_expression (member_expression [(identifier) (property_identifier)] @entity.name.tag.component.js)))
(jsx_namespace_name) @entity.name.tag.native.js

(jsx_attribute (property_identifier) @entity.other.attribute-name.js)
(jsx_attribute (jsx_namespace_name) @entity.other.attribute-name.js)
(jsx_attribute "=" @punctuation.separator.key-value.js)
(jsx_expression ["{" "}"] @punctuation.section.interpolation.js)
(html_character_reference) @constant.character.escape.js

; A comment in braces is a comment, braces and all.
(jsx_expression "{" @comment.block.js . (comment) . "}" @comment.block.js)
