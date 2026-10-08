; Shell (bash and zsh), as Sublime 4 scopes it (Packages/ShellScript). Generic first: later
; patterns win where two capture the same text.
(word) @string.unquoted.shell
(extglob_pattern) @string.unquoted.shell
(string) @string.quoted.double.shell
(raw_string) @string.quoted.single.shell
(ansi_c_string) @string.quoted.single.dollar.shell
(heredoc_body) @string.unquoted.heredoc.shell
(heredoc_start) @keyword.control.heredoc-token.shell
(heredoc_end) @keyword.control.heredoc-token.shell
(number) @constant.numeric.value.shell
(file_descriptor) @constant.numeric.value.shell
(comment) @comment.line.number-sign.shell
((comment) @comment.line.shebang.shell (#match? @comment.line.shebang.shell "^#!"))

(variable_name) @variable.other.readwrite.shell
(simple_expansion) @clear.meta.interpolation.parameter.shell
(expansion) @clear.meta.interpolation.parameter.shell
(command_substitution) @clear.meta.interpolation.command.shell
(special_variable_name) @variable.language.builtin.shell
(variable_assignment name: (variable_name) @variable.other.readwrite.shell)
(for_statement variable: (variable_name) @variable.other.readwrite.shell)
(declaration_command (variable_name) @variable.other.readwrite.shell)

(command name: (command_name (word) @variable.function.shell))
((command name: (command_name (word) @support.function.shell))
 (#any-of? @support.function.shell "echo" "print" "printf" "read" "set" "shift" "source" "test" "cd" "pwd" "eval" "exec" "trap" "wait" "kill" "true" "false" "type" "command" "builtin" "alias" "unalias" "getopts" "let" "ulimit" "umask" "hash" "export" "unset" "autoload" "emulate" "setopt" "unsetopt" "zmodload" "bindkey"))
((command name: (command_name (word) @keyword.control.flow.shell)) (#any-of? @keyword.control.flow.shell "exit" "return"))
((command argument: (word) @variable.parameter.option.shell) (#match? @variable.parameter.option.shell "^[-+]"))

(function_definition name: (word) @entity.name.function.shell)
(test_operator) @variable.parameter.option.shell
(expansion ["${" "}"] @punctuation.section.interpolation.shell)
(command_substitution ["$(" ")"] @punctuation.section.interpolation.shell)

["if" "then" "else" "elif" "fi" "case" "esac"] @keyword.control.conditional.shell
["for" "while" "until" "do" "done" "in" "select"] @keyword.control.loop.shell
"function" @keyword.declaration.function.shell
["local" "readonly" "declare" "typeset"] @keyword.declaration.variable.shell
["export" "unset"] @support.function.shell
