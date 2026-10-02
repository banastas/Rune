; C, as Sublime 4 scopes it (Packages/C++/C): a variable or a type of one's own is plain; the
; language's types, the standard library's functions and the preprocessor are colored. A member
; after . is one, after -> it's plain, as Sublime has them. Later patterns win where two capture
; the same text.
(comment) @comment.line.double-slash.c
((comment) @comment.block.c (#match? @comment.block.c "^/[*]"))

(preproc_include "#include" @keyword.control.directive.include.c)
(preproc_include path: (system_lib_string) @string.quoted.other.lt-gt.include.c)
(preproc_include path: (string_literal) @string.quoted.double.include.c)
(preproc_def "#define" @keyword.control.directive.define.c)
(preproc_def name: (identifier) @entity.name.constant.preprocessor.c)
(preproc_def value: (preproc_arg) @meta.preprocessor.macro.value.c)
(preproc_function_def "#define" @keyword.control.directive.define.c)
(preproc_function_def name: (identifier) @entity.name.function.preprocessor.c)
(preproc_params (identifier) @variable.parameter.c)
["#if" "#ifdef" "#ifndef" "#else" "#elif" "#endif" "#elifdef" "#elifndef"] @keyword.control.directive.c
(preproc_call directive: (preproc_directive) @keyword.control.directive.c)

[(primitive_type) (sized_type_specifier)] @storage.type.c
((primitive_type) @support.type.stddef.c (#any-of? @support.type.stddef.c "size_t" "ptrdiff_t" "wchar_t" "max_align_t" "nullptr_t"))
((primitive_type) @support.type.stdint.c (#match? @support.type.stdint.c "^u?int(_least|_fast)?[0-9]+_t$|^u?intptr_t$|^u?intmax_t$"))
(type_definition declarator: (type_identifier) @entity.name.type.typedef.c)
(struct_specifier name: (type_identifier) @entity.name.struct.c)
(union_specifier name: (type_identifier) @entity.name.union.c)
(enum_specifier name: (type_identifier) @entity.name.enum.c)
(enumerator name: (identifier) @entity.name.constant.c)

(function_declarator declarator: (identifier) @entity.name.function.c)
(parameter_declaration declarator: (identifier) @variable.parameter.c)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @variable.parameter.c))
(parameter_declaration declarator: (pointer_declarator declarator: (pointer_declarator declarator: (identifier) @variable.parameter.c)))
(parameter_declaration declarator: (array_declarator declarator: (identifier) @variable.parameter.c))
(call_expression function: (identifier) @variable.function.c)
((call_expression function: (identifier) @support.function.C99.c) (#any-of? @support.function.C99.c "printf" "fprintf" "sprintf" "snprintf" "vprintf" "vfprintf" "vsprintf" "vsnprintf" "scanf" "fscanf" "sscanf" "puts" "fputs" "gets" "fgets" "putchar" "getchar" "putc" "getc" "fputc" "fgetc" "fopen" "freopen" "fclose" "fread" "fwrite" "fseek" "ftell" "rewind" "fflush" "feof" "ferror" "perror" "remove" "rename" "tmpfile" "malloc" "calloc" "realloc" "free" "exit" "abort" "atexit" "atoi" "atol" "atoll" "atof" "strtol" "strtoul" "strtoll" "strtoull" "strtod" "strtof" "qsort" "bsearch" "abs" "labs" "llabs" "div" "rand" "srand" "getenv" "system" "memcpy" "memmove" "memset" "memcmp" "memchr" "strcpy" "strncpy" "strcat" "strncat" "strcmp" "strncmp" "strcoll" "strlen" "strchr" "strrchr" "strstr" "strspn" "strcspn" "strpbrk" "strtok" "strerror" "isalpha" "isdigit" "isalnum" "isspace" "isupper" "islower" "ispunct" "isxdigit" "toupper" "tolower" "time" "clock" "difftime" "mktime" "localtime" "gmtime" "strftime" "sqrt" "pow" "fabs" "floor" "ceil" "fmod" "sin" "cos" "tan" "atan" "atan2" "log" "log10" "exp" "va_start" "va_end" "va_arg" "va_copy" "setjmp" "longjmp" "signal" "raise"))
(initializer_pair designator: (field_designator (field_identifier) @variable.other.member.c))
(field_expression operator: "." field: (field_identifier) @variable.other.member.c)

(null) @constant.language.null.c
(true) @constant.language.boolean.true.c
(false) @constant.language.boolean.false.c
(number_literal) @constant.numeric.value.c
(char_literal) @string.quoted.single.c
(string_literal) @string.quoted.double.c
(escape_sequence) @constant.character.escape.c

"typedef" @keyword.declaration.type.c
"struct" @keyword.declaration.struct.c
"union" @keyword.declaration.union.c
"enum" @keyword.declaration.enum.c
["static" "const" "extern" "register" "volatile" "inline" "restrict" "auto" "_Atomic"] @storage.modifier.c
["if" "else" "for" "while" "do" "switch" "case" "default" "goto" "break" "continue"] @keyword.control.c
"return" @keyword.control.flow.return.c
"sizeof" @keyword.operator.word.c
