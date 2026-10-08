; Markdown's blocks, as Sublime 4 scopes them (Packages/Markdown, GFM).
(atx_heading) @markup.heading.markdown
(atx_heading (atx_h1_marker)) @markup.heading.1.markdown
(atx_heading (atx_h2_marker)) @markup.heading.2.markdown
(atx_heading (atx_h3_marker)) @markup.heading.3.markdown
(atx_heading (atx_h4_marker)) @markup.heading.4.markdown
(atx_heading (atx_h5_marker)) @markup.heading.5.markdown
(atx_heading (atx_h6_marker)) @markup.heading.6.markdown
(atx_heading (inline) @entity.name.section.markdown)
(setext_heading) @markup.heading.markdown
(setext_heading (paragraph) @entity.name.section.markdown)

(list_item (list_marker_minus)) @markup.list.unnumbered.markdown
(list_item (list_marker_star)) @markup.list.unnumbered.markdown
(list_item (list_marker_plus)) @markup.list.unnumbered.markdown
(list_item (list_marker_dot)) @markup.list.numbered.markdown
(list_item (list_marker_parenthesis)) @markup.list.numbered.markdown

(block_quote) @markup.quote.markdown

(fenced_code_block (info_string (language) @constant.other.language-name.markdown))
(fenced_code_block (code_fence_content) @meta.code-fence.body.markdown-gfm)
(fenced_code_block (code_fence_content) @markup.raw.code-fence.markdown-gfm)
(indented_code_block) @markup.raw.block.markdown

(link_reference_definition (link_destination) @markup.underline.link.markdown)
