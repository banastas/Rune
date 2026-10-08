; Commit messages, as Sublime 4 scopes them (Packages/Git Formats/Git Commit): the subject a
; heading, issue references in the message (split by the highlighter), and git's comments with
; their headings and changed files.
(subject) @markup.heading.subject.git.commit
(message_line) @meta.message.git.commit
(generated_comment) @comment.line.git.commit
(generated_comment (text) @markup.heading.on-branch.git.commit)
(branch) @entity.name.reference.branch.git.commit
(title) @markup.heading.git.commit
(change) @keyword.other.change-list.git.commit
(generated_comment (change (modified)) (filepath) @markup.changed.file.content.git.commit)
(generated_comment (change (deleted)) (filepath) @markup.deleted.file.git.commit)
(generated_comment (change (new)) (filepath) @markup.inserted.file.git.commit)
