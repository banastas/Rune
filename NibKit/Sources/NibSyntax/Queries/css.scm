; CSS, as Sublime 4 scopes it (Packages/CSS).
(comment) @comment.block.css

(tag_name) @entity.name.tag.html.css
(universal_selector) @constant.other.wildcard.asterisk.css
(nesting_selector) @entity.name.tag.nesting.css
(class_selector (class_name) @entity.other.attribute-name.class.css)
(id_selector (id_name) @entity.other.attribute-name.id.css)
(attribute_selector (attribute_name) @entity.other.attribute-name.css)
(attribute_selector (plain_value) @string.unquoted.css)
(pseudo_class_selector (class_name) @entity.other.pseudo-class.css)
(pseudo_element_selector (tag_name) @only.entity.other.pseudo-element.css .)

(declaration (property_name) @support.type.property-name.css)
((declaration (property_name) @only.entity.other.custom-property.css) (#match? @only.entity.other.custom-property.css "^--"))
(feature_name) @support.type.property-name.media.css

(plain_value) @support.constant.property-value.css
((plain_value) @constant.language.null.css (#eq? @constant.language.null.css "none"))
((plain_value) @keyword.other.grid.css (#any-of? @keyword.other.grid.css "auto-fill" "auto-fit" "dense" "span"))
(feature_query (plain_value) @only.meta.group.css)
((plain_value) @variable.other.custom-property.css (#match? @variable.other.custom-property.css "^--"))
(color_value) @constant.other.color.rgb-value.css
(integer_value) @constant.numeric.value.css
(float_value) @constant.numeric.value.css
(unit) @constant.numeric.suffix.css
(string_value) @string.quoted.double.css
(important) @keyword.other.important.css

(function_name) @support.function.css

(at_keyword) @keyword.control.at-rule.css
"@media" @keyword.control.at-rule.media.css
"@import" @keyword.control.at-rule.import.css
"@keyframes" @keyword.control.at-rule.keyframe.css
"@supports" @keyword.control.at-rule.supports.css
"@charset" @keyword.control.at-rule.charset.css
"@namespace" @keyword.control.at-rule.namespace.css
(keyframe_block (from) @keyword.other.selector.css)
(keyframe_block (to) @keyword.other.selector.css)
