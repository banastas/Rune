; Ruby, as Sublime 4 scopes it (Packages/Ruby): a local name or a method call is plain, a
; capitalized constant a class (all capitals a constant), symbols constants, the methods Sublime
; knows (its lists, below) builtins or keywords. Later patterns win where two capture the same text.
(comment) @comment.line.number-sign.ruby
(constant) @support.class.ruby
((constant) @variable.other.constant.ruby (#match? @variable.other.constant.ruby "^[A-Z][A-Z0-9_]+$"))
(module name: (constant) @only.entity.name.namespace.ruby)
(module name: (scope_resolution name: (constant) @only.entity.name.namespace.ruby))
(class name: (constant) @only.entity.name.class.ruby)
(class name: (scope_resolution name: (constant) @only.entity.name.class.ruby))
(superclass (constant) @entity.other.inherited-class.ruby)
(assignment left: (constant) @only.entity.name.constant.ruby)

(instance_variable) @variable.other.readwrite.instance.ruby
(class_variable) @variable.other.readwrite.class.ruby
(global_variable) @variable.other.readwrite.global.ruby
(self) @variable.language.this.ruby
((identifier) @variable.language.ruby (#any-of? @variable.language.ruby "__FILE__" "__LINE__" "__ENCODING__"))
(simple_symbol) @constant.other.symbol.ruby
(hash_key_symbol) @constant.other.symbol.ruby
(pair (hash_key_symbol) . ":" @constant.other.symbol.ruby)
(delimited_symbol) @constant.other.symbol.ruby

((identifier) @support.function.builtin.ruby (#any-of? @support.function.builtin.ruby "Array" "Complex" "Float" "Hash" "Integer" "Rational" "String" "__callee__" "__dir__" "__method__" "abort" "ancestors" "append_features" "assert_match" "assert_no_match" "at_exit" "autoload" "binding" "callcc" "caller" "caller_locations" "chomp" "chop" "class" "class_eval" "class_exec" "class_variable_get" "class_variable_set" "class_variables" "clone" "const_get" "const_missing" "const_set" "constants" "define_method" "define_singleton_method" "display" "dup" "enum_for" "eql" "eval" "exec" "exit" "extend_object" "extended" "fork" "format" "freeze" "gets" "global_variables" "gsub" "hash" "included" "included_modules" "index" "inspect" "instance_variable_get" "instance_variable_set" "instance_variables" "itself" "lambda" "local_variables" "match" "method" "method_added" "method_removed" "method_undefined" "methods" "module_eval" "module_exec" "name" "object_id" "open" "p" "prepend_features" "prepended" "print" "printf" "private_class_method" "private_constant" "private_instance_methods" "private_methods" "proc" "protected_instance_methods" "protected_methods" "public_class_method" "public_constant" "public_instance_method" "public_instance_methods" "public_method" "public_methods" "public_send" "putc" "puts" "rand" "readline" "readlines" "refine" "remove_class_variable" "remove_const" "remove_instance_variable" "remove_method" "rindex" "scan" "select" "send" "set_trace_func" "singleton_class" "singleton_method" "singleton_methods" "sleep" "spawn" "sprintf" "srand" "sub" "syscall" "system" "taint" "tap" "test" "to_a" "to_ary" "to_c" "to_enum" "to_f" "to_h" "to_hash" "to_i" "to_int" "to_io" "to_proc" "to_r" "to_s" "to_str" "to_sym" "trace_var" "trap" "trust" "undef_method" "untaint" "untrace_var" "untrust" "using" "warn" "autoload?" "class_variable_defined?" "const_defined?" "exit!" "frozen?" "include?" "instance_methods?" "instance_of?" "instance_variable_defined?" "is_a?" "iterator?" "kind_of?" "method_defined?" "nil?" "private_method_defined?" "protected_method_defined?" "public_method_defined?" "respond_to?" "respond_to_missing?" "singleton_class?" "tainted?" "untrusted?" "gsub!" "sub!" "eql?" "match?" "block_given?" "super"))
((identifier) @keyword.other.special-method.ruby (#any-of? @keyword.other.special-method.ruby "initialize" "new" "include" "extend" "prepend" "attr_reader" "attr_writer" "attr_accessor" "attr" "module_function" "public" "protected" "private"))
((identifier) @keyword.control.import.ruby (#any-of? @keyword.control.import.ruby "require" "require_relative" "gem"))
((identifier) @keyword.control.flow.throw.ruby (#any-of? @keyword.control.flow.throw.ruby "raise" "fail" "throw"))
((identifier) @keyword.control.exception.catch.ruby (#eq? @keyword.control.exception.catch.ruby "catch"))
((identifier) @keyword.control.loop.loop.ruby (#eq? @keyword.control.loop.loop.ruby "loop"))

(method name: (identifier) @only.entity.name.function.ruby)
(singleton_method name: (identifier) @only.entity.name.function.ruby)
(method_parameters (identifier) @only.variable.parameter.ruby)
(keyword_parameter name: (identifier) @only.variable.parameter.ruby)
(optional_parameter name: (identifier) @only.variable.parameter.ruby)
(splat_parameter name: (identifier) @only.variable.parameter.ruby)
(hash_splat_parameter name: (identifier) @only.variable.parameter.ruby)
(block_parameter name: (identifier) @only.variable.parameter.ruby)
(block_parameters (identifier) @only.variable.parameter.ruby)
(lambda_parameters (identifier) @only.variable.parameter.ruby)

(string) @string.quoted.double.ruby
((string) @string.quoted.single.ruby (#match? @string.quoted.single.ruby "^'"))
(interpolation) @clear.meta.interpolation.ruby
(interpolation ["#{" "}"] @punctuation.section.interpolation.ruby)
(escape_sequence) @constant.character.escape.ruby
(regex) @string.regexp.ruby
[(integer) (float) (rational) (complex)] @constant.numeric.value.ruby
(true) @constant.language.boolean.true.ruby
(false) @constant.language.boolean.false.ruby
(nil) @constant.language.null.ruby

"module" @keyword.declaration.namespace.ruby
"class" @keyword.declaration.class.ruby
"def" @keyword.declaration.function.ruby
"end" @keyword.control.block.end.ruby
"do" @keyword.control.block.do.ruby
"begin" @keyword.control.block.begin.ruby
["rescue" "ensure"] @keyword.control.exception.rescue.ruby
"retry" @keyword.control.flow.retry.ruby
["if" "unless" "else" "elsif" "case" "when" "then"] @keyword.control.conditional.ruby
["while" "until" "for" "in"] @keyword.control.loop.ruby
["return" "yield" "next" "break" "redo"] @keyword.control.flow.ruby
["and" "or" "not"] @keyword.operator.logical.ruby
["alias" "undef" "defined?"] @keyword.other.ruby
