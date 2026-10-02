; XML, as Sublime 4 scopes it (Packages/XML). A qualified name's namespace and colon
; (`itunes:image`) are split off by the highlighter, as are a string's quotes, a comment's
; markers and an entity's & # ; (Highlighter.delimiters).

; Tags
(STag) @meta.tag.xml
(ETag) @meta.tag.xml
(EmptyElemTag) @meta.tag.xml
(STag (Name) @entity.name.tag.localname.xml)
(ETag (Name) @entity.name.tag.localname.xml)
(EmptyElemTag (Name) @entity.name.tag.localname.xml)
(STag "<" @punctuation.definition.tag.begin.opening.xml)
(STag ">" @punctuation.definition.tag.end.opening.xml)
(EmptyElemTag "<" @punctuation.definition.tag.begin.opening.xml)
(EmptyElemTag "/>" @punctuation.definition.tag.end.self-closing.xml)
(ETag "</" @punctuation.definition.tag.begin.closing.xml)
(ETag ">" @punctuation.definition.tag.end.closing.xml)
; An end tag the parse couldn't place, as while a tag is being typed above it (`<enclo`
; before `</item>`): its name keeps its color, as in Sublime, whose syntax goes line by line.
(ERROR "</" @punctuation.definition.tag.begin.closing.xml . (Name) @entity.name.tag.localname.xml)

; Attributes, and the pseudo-attributes of <?xml-stylesheet ?>
(Attribute (Name) @entity.other.attribute-name.localname.xml)
(PseudoAtt (Name) @entity.other.attribute-name.localname.xml)
(Attribute "=" @punctuation.separator.key-value.xml)
(PseudoAtt "=" @punctuation.separator.key-value.xml)
((AttValue) @string.quoted.double.xml (#match? @string.quoted.double.xml "^\""))
((AttValue) @string.quoted.single.xml (#match? @string.quoted.single.xml "^'"))
((PseudoAttValue) @string.quoted.double.xml (#match? @string.quoted.double.xml "^\""))
((PseudoAttValue) @string.quoted.single.xml (#match? @string.quoted.single.xml "^'"))

; The declaration and processing instructions
(XMLDecl) @meta.tag.preprocessor.xml
(StyleSheetPI) @meta.tag.preprocessor.xml
(XmlModelPI) @meta.tag.preprocessor.xml
(PI) @meta.tag.preprocessor.xml
(XMLDecl "xml" @entity.name.tag.xml)
(StyleSheetPI "xml-stylesheet" @entity.name.tag.xml)
(XmlModelPI "xml-model" @entity.name.tag.xml)
(PI (PITarget) @entity.name.tag.xml)
(XMLDecl ["version" "encoding" "standalone"] @entity.other.attribute-name.localname.xml)
(XMLDecl "=" @punctuation.separator.key-value.xml)
(XMLDecl "\"" @string.quoted.double.xml)
(XMLDecl "'" @string.quoted.single.xml)
(XMLDecl [(VersionNum) (EncName) "yes" "no"] @string.quoted.double.xml)
["<?" "<!" "<!["] @punctuation.definition.tag.begin.xml
"?>" @punctuation.definition.tag.end.xml

; Comments and CDATA
(Comment) @comment.block.xml
(CDSect) @meta.tag.sgml.cdata.xml
(CDStart "CDATA" @keyword.declaration.cdata.xml)
(CDStart "[" @punctuation.definition.tag.begin.content.xml)
(CData) @string.unquoted.cdata.xml
(CDSect "]]>" @punctuation.definition.tag.end.xml)

; Entities
(EntityRef) @constant.character.entity.named.xml
((CharRef) @constant.character.entity.hexadecimal.xml (#match? @constant.character.entity.hexadecimal.xml "^&#[xX]"))
((CharRef) @constant.character.entity.decimal.xml (#match? @constant.character.entity.decimal.xml "^&#[0-9]"))
(PEReference) @variable.parameter.xml

; DOCTYPE and its internal subset
(doctypedecl) @meta.tag.sgml.doctype.xml
(doctypedecl "DOCTYPE" @keyword.declaration.doctype.xml)
(doctypedecl (Name) @variable.other.documentroot.localname.xml)
(doctypedecl "[" @punctuation.section.brackets.begin.xml)
(doctypedecl "]" @punctuation.section.brackets.end.xml)
(doctypedecl ">" @punctuation.definition.tag.end.xml)
(elementdecl ">" @punctuation.definition.tag.end.xml)
(AttlistDecl ">" @punctuation.definition.tag.end.xml)
(GEDecl ">" @punctuation.definition.tag.end.xml)
(PEDecl ">" @punctuation.definition.tag.end.xml)
(NotationDecl ">" @punctuation.definition.tag.end.xml)
(ExternalID ["PUBLIC" "SYSTEM"] @storage.type.external-content.xml)
(PublicID "PUBLIC" @storage.type.external-content.xml)
((PubidLiteral) @string.quoted.double.xml (#match? @string.quoted.double.xml "^\""))
((PubidLiteral) @string.quoted.single.xml (#match? @string.quoted.single.xml "^'"))
((SystemLiteral) @string.quoted.double.xml (#match? @string.quoted.double.xml "^\""))
((SystemLiteral) @string.quoted.single.xml (#match? @string.quoted.single.xml "^'"))
((EntityValue) @string.quoted.double.xml (#match? @string.quoted.double.xml "^\""))
((EntityValue) @string.quoted.single.xml (#match? @string.quoted.single.xml "^'"))

(elementdecl) @meta.tag.sgml.element.xml
(elementdecl "ELEMENT" @keyword.declaration.element.xml)
(elementdecl (Name) @variable.other.element.xml)
(contentspec ["EMPTY" "ANY"] @constant.other.xml)
(Mixed "#PCDATA" @constant.other.placeholder.xml)
(Mixed (Name) @string.unquoted.xml)
(children (Name) @string.unquoted.xml)
[(Mixed "(" @punctuation.section.group.begin.xml) (children "(" @punctuation.section.group.begin.xml)
 (Enumeration "(" @punctuation.section.group.begin.xml) (NotationType "(" @punctuation.section.group.begin.xml)]
[(Mixed ")" @punctuation.section.group.end.xml) (children ")" @punctuation.section.group.end.xml)
 (Enumeration ")" @punctuation.section.group.end.xml) (NotationType ")" @punctuation.section.group.end.xml)]
[(Mixed "*" @keyword.operator.xml) (children ["*" "?" "+"] @keyword.operator.xml)]
[(Mixed "|" @punctuation.separator.xml) (children ["|" ","] @punctuation.separator.xml)
 (Enumeration "|" @punctuation.separator.xml) (NotationType "|" @punctuation.separator.xml)]

(AttlistDecl) @meta.tag.sgml.attlist.xml
(AttlistDecl "ATTLIST" @keyword.declaration.attlist.xml)
(AttlistDecl (Name) @variable.other.element.xml)
(AttDef (Name) @entity.other.attribute-name.xml)
[(StringType) (TokenizedType)] @storage.type.attribute.xml
(NotationType "NOTATION" @storage.type.attribute.xml)
(Enumeration) @meta.group.enumerated.xml
(Enumeration (Nmtoken) @string.unquoted.xml)
(NotationType (Name) @string.unquoted.xml)
(DefaultDecl ["#REQUIRED" "#IMPLIED" "#FIXED"] @storage.modifier.attribute.default-value.xml)

[(GEDecl) (PEDecl)] @meta.tag.sgml.entity.xml
(GEDecl "ENTITY" @keyword.declaration.entity.xml)
(PEDecl "ENTITY" @keyword.declaration.entity.xml)
(GEDecl (Name) @variable.other.entity.xml)
(PEDecl (Name) @variable.other.entity.xml)
(PEDecl "%" @punctuation.definition.entity.xml)
(NDataDecl "NDATA" @storage.type.ndata.xml)
(NDataDecl (Name) @string.unquoted.xml)

(NotationDecl) @meta.tag.sgml.notation.xml
(NotationDecl "NOTATION" @keyword.declaration.notation.xml)
(NotationDecl (Name) @variable.other.notation.xml)
