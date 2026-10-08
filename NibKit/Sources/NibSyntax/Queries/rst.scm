; reStructuredText, as Sublime 4 scopes it (Packages/RestructuredText): a heading's adornment (not
; its title) a heading, inline markup by kind, links' and targets' names titles. A link's or a
; footnote's parts are split by the highlighter, its marks left plain.
"adornment" @markup.heading.restructuredtext
(literal) @markup.raw.restructuredtext
(strong) @markup.bold.restructuredtext
(emphasis) @markup.italic.restructuredtext
(interpreted_text (role) @entity.name.tag.restructuredtext)
(reference) @meta.link.restructuredtext
(standalone_hyperlink) @markup.underline.link.restructuredtext
(target name: (name) @meta.link.reference.def.restructuredtext)
(footnote_reference) @meta.footnote.link.restructuredtext
(citation_reference) @meta.footnote.link.restructuredtext
(footnote (label) @constant.other.footnote.restructuredtext)
(citation (label) @constant.other.footnote.restructuredtext)
(footnote (body) @string.other.footnote.restructuredtext)
(directive (type) @meta.other.directive.restructuredtext)
(substitution_reference) @variable.other.substitution.restructuredtext
(comment) @comment.line.double-dot.restructuredtext
