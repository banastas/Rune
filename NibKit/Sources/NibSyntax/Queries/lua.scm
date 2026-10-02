; Lua, as Sublime 4 scopes it (Packages/Lua): names are variables, a field after a dot plain, a
; table's keys unquoted strings, the standard library support. Later patterns win where two
; capture the same text.
(identifier) @variable.other.lua
(dot_index_expression field: (identifier) @only.meta.property.lua)
(field name: (identifier) @string.unquoted.key.lua)
((field name: (identifier) @support.function.metamethod.lua) (#match? @support.function.metamethod.lua "^__"))
(parameters (identifier) @variable.parameter.function.lua)
((identifier) @support.constant.builtin.lua (#any-of? @support.constant.builtin.lua "io" "math" "string" "table" "os" "coroutine" "debug" "utf8" "package" "_G" "_ENV"))

(function_declaration name: (identifier) @entity.name.function.lua)
(function_declaration name: (dot_index_expression field: (identifier) @only.entity.name.function.lua))
(function_declaration name: (method_index_expression method: (identifier) @only.entity.name.function.lua))
(function_call name: (identifier) @variable.function.lua)
(function_call name: (dot_index_expression field: (identifier) @only.variable.function.lua))
(function_call name: (method_index_expression method: (identifier) @variable.function.lua))
((function_call name: (identifier) @support.function.builtin.lua) (#any-of? @support.function.builtin.lua "assert" "collectgarbage" "dofile" "error" "getmetatable" "ipairs" "load" "loadfile" "next" "pairs" "pcall" "print" "rawequal" "rawget" "rawlen" "rawset" "require" "select" "setmetatable" "tonumber" "tostring" "type" "unpack" "xpcall"))
((function_call name: (dot_index_expression table: (identifier) @_module field: (identifier) @only.support.function.builtin.lua)) (#any-of? @_module "io" "math" "string" "table" "os" "coroutine" "debug" "utf8"))

(string) @string.quoted.double.lua
((string) @string.quoted.single.lua (#match? @string.quoted.single.lua "^'"))
((string) @string.quoted.multiline.lua (#match? @string.quoted.multiline.lua "^\\[=*\\["))
(escape_sequence) @constant.character.escape.lua
(number) @constant.numeric.value.lua
(nil) @constant.language.null.lua
(true) @constant.language.boolean.true.lua
(false) @constant.language.boolean.false.lua
(vararg_expression) @variable.language.lua
(comment) @comment.line.lua
((comment) @comment.block.lua (#match? @comment.block.lua "^--\\[=*\\["))

"local" @storage.modifier.lua
"function" @keyword.declaration.function.lua
["if" "then" "else" "elseif"] @keyword.control.conditional.lua
"return" @keyword.control.return.lua
"end" @keyword.control.end.lua
["for" "in" "while" "repeat" "until"] @keyword.control.loop.lua
"do" @keyword.control.lua
[(break_statement) "goto"] @keyword.control.flow.lua
["and" "or" "not"] @keyword.operator.logical.lua
