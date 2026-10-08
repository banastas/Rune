; Makefiles, as Sublime 4 scopes them (Packages/Makefile): assignments, rules and directives,
; and make's references with their $( and ). A recipe's shell is the shell's, embedded
; (Injections), with make's references blanked out for it; their parts are captured here, so
; they show through. The highlighter marks a pattern's %.
(comment) @comment.line.number-sign.makefile
(variable_assignment name: (word) @variable.other.makefile)
(variable_assignment value: (text) @string.unquoted.makefile)

(rule (targets (word) @entity.name.function.makefile))
(rule (prerequisites (word) @string.unquoted.makefile))
(rule ":" @keyword.operator.assignment.makefile)
(rule "|" @string.unquoted.makefile)
(recipe_line "@" @constant.language.makefile)

(variable_reference) @meta.interpolation.makefile
(variable_reference ["$" "(" "{"] @keyword.other.block.begin.makefile)
(variable_reference [")" "}"] @keyword.other.block.end.makefile)
(variable_reference (word) @variable.parameter.makefile)
(automatic_variable ["$" "@" "^" "<" "?" "*" "%" "+" "|"] @variable.language.automatic.makefile)

(function_call ["$" "("] @keyword.other.block.begin.makefile)
(function_call ")" @keyword.other.block.end.makefile)
(function_call function: _ @support.function.builtin.makefile)
(function_call (arguments) @meta.function-call.arguments.makefile)
(function_call (arguments (text) @string.unquoted.makefile))
(function_call (arguments "," @punctuation.separator.makefile))
(shell_function ["$" "("] @keyword.other.block.begin.makefile)
(shell_function ")" @keyword.other.block.end.makefile)
(shell_function "shell" @support.function.builtin.makefile)

["ifeq" "ifneq" "ifdef" "ifndef" "else" "endif"] @keyword.control.conditional.makefile
(ifeq_directive ["(" ")"] @punctuation.section.group.makefile)
(ifeq_directive "," @punctuation.separator.makefile)
(include_directive ["include" "-include" "sinclude"] @keyword.control.import.makefile)
(include_directive filenames: (list (word) @string.unquoted.makefile))
["export" "unexport" "override" "define" "endef" "undefine" "private" "vpath"] @keyword.control.makefile
