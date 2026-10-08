; PHP, as Sublime 4 scopes it (Packages/PHP): the code between <?php and ?>. The HTML round it is
; HTML's: one injection over the file, the code blanked in it and marked embedded PHP (Injections).
; Later patterns win where two capture the same text.
(comment) @comment.line.double-slash.php
((comment) @comment.line.number-sign.php (#match? @comment.line.number-sign.php "^#"))
((comment) @comment.block.php (#match? @comment.block.php "^/[*]"))
((comment) @comment.block.documentation.phpdoc.php (#match? @comment.block.documentation.phpdoc.php "^/[*][*]"))

(variable_name) @variable.other.php
((variable_name) @variable.language.this.php (#eq? @variable.language.this.php "$this"))
((name) @constant.other.php (#match? @constant.other.php "^[A-Z][A-Z0-9_]+$"))
((name) @constant.language.builtin.php (#match? @constant.language.builtin.php "^__[A-Z]+__$"))
(member_access_expression name: (name) @variable.other.member.php)
(nullsafe_member_access_expression name: (name) @variable.other.member.php)
(member_call_expression name: (name) @variable.function.php)
(nullsafe_member_call_expression name: (name) @variable.function.php)
(scoped_call_expression name: (name) @variable.function.php)
(function_call_expression function: (name) @variable.function.php)
((function_call_expression function: (name) @support.function.builtin.php) (#any-of? @support.function.builtin.php "count" "array_map" "array_filter" "array_reduce" "array_keys" "array_values" "array_merge" "array_slice" "array_splice" "array_search" "array_key_exists" "array_unique" "array_reverse" "array_sum" "array_column" "array_combine" "array_fill" "array_flip" "array_push" "array_pop" "array_shift" "array_unshift" "in_array" "sort" "usort" "ksort" "asort" "implode" "explode" "join" "str_replace" "str_contains" "str_starts_with" "str_ends_with" "str_repeat" "str_pad" "str_split" "strlen" "strtolower" "strtoupper" "strpos" "stripos" "strrpos" "substr" "substr_count" "sprintf" "printf" "vsprintf" "number_format" "trim" "ltrim" "rtrim" "ucfirst" "ucwords" "lcfirst" "nl2br" "htmlspecialchars" "htmlentities" "html_entity_decode" "strip_tags" "addslashes" "json_encode" "json_decode" "serialize" "unserialize" "var_dump" "var_export" "print_r" "isset" "empty" "unset" "is_array" "is_string" "is_int" "is_numeric" "is_null" "is_bool" "is_callable" "intval" "floatval" "strval" "boolval" "gettype" "get_class" "method_exists" "property_exists" "class_exists" "function_exists" "define" "defined" "constant" "die" "exit" "file_get_contents" "file_put_contents" "fopen" "fclose" "fread" "fwrite" "file_exists" "is_file" "is_dir" "mkdir" "unlink" "dirname" "basename" "pathinfo" "realpath" "date" "time" "strtotime" "mktime" "microtime" "sleep" "usleep" "preg_match" "preg_match_all" "preg_replace" "preg_split" "preg_quote" "min" "max" "abs" "round" "floor" "ceil" "rand" "mt_rand" "random_int" "range" "compact" "extract" "header" "setcookie" "session_start" "ob_start" "ob_get_clean" "error_log" "trigger_error" "iterator_to_array" "call_user_func" "func_get_args"))
"echo" @support.function.builtin.php
(declare_directive "strict_types" @constant.other.php)

(namespace_definition name: (namespace_name (name) @only.entity.name.namespace.php))
(namespace_use_clause (qualified_name (namespace_name (name) @only.variable.namespace.php)))
(namespace_use_clause (qualified_name (name) @only.support.class.php))
(namespace_use_clause (name) @only.support.class.php)
(named_type (name) @only.support.class.php)
(named_type (qualified_name (name) @only.support.class.php))
(object_creation_expression (name) @only.support.class.php)
(object_creation_expression (qualified_name (name) @only.support.class.php))
(scoped_call_expression scope: (name) @only.support.class.php)
(class_constant_access_expression . (name) @only.support.class.php)
(primitive_type) @storage.type.primitive.php
(const_element (name) @only.entity.name.constant.php)
(class_declaration name: (name) @only.entity.name.class.php)
(interface_declaration name: (name) @only.entity.name.interface.php)
(trait_declaration name: (name) @only.entity.name.trait.php)
(enum_declaration name: (name) @only.entity.name.enum.php)
(method_declaration name: (name) @entity.name.function.php)
((method_declaration name: (name) @support.function.magic.php) (#match? @support.function.magic.php "^__"))
(function_definition name: (name) @entity.name.function.php)
(simple_parameter name: (variable_name) @variable.parameter.php)
(property_promotion_parameter name: (variable_name) @variable.parameter.php)
(variadic_parameter name: (variable_name) @variable.parameter.php)
(visibility_modifier) @storage.modifier.access.php
[(final_modifier) (abstract_modifier) (static_modifier) (readonly_modifier)] @storage.modifier.php

(string) @string.quoted.single.php
(encapsed_string) @string.quoted.double.php
(escape_sequence) @constant.character.escape.php
[(integer) (float)] @constant.numeric.value.php
(null) @constant.language.null.php
(boolean) @constant.language.boolean.php
(arrow_function "fn" @keyword.declaration.function.php)
(arrow_function "=>" @keyword.declaration.function.arrow.php)

"namespace" @keyword.declaration.namespace.php
"use" @keyword.declaration.use.php
"const" @keyword.declaration.constant.php
"class" @keyword.declaration.class.php
"function" @keyword.declaration.function.php
"declare" @keyword.declaration.php
"new" @keyword.other.new.php
["if" "else" "elseif" "endif" "switch" "case" "default" "endswitch" "match"] @keyword.control.conditional.php
["foreach" "for" "while" "do" "endforeach" "endfor" "endwhile"] @keyword.control.loop.php
"as" @keyword.other.as.php
["return" "break" "continue" "throw"] @keyword.control.flow.php
["try" "catch" "finally"] @keyword.control.exception.php
["extends" "implements" "interface" "trait" "enum"] @storage.modifier.php
