// E11: vendored tree-sitter highlight queries, embedded as raw string
// literals instead of SwiftPM resource bundles (a few KB of text each; not
// worth Bundle.module plumbing across nine new targets). See each grammar
// target's VENDOR.md for source commit and any query-composition notes
// (TypeScript's query is javascript's + typescript's concatenated, per
// upstream's own "; inherits: javascript" convention).
enum HighlightQueries {
  static let json = #"""
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
"""#

  static let python = #"""
; Identifier naming conventions

(identifier) @variable

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z_]*$"))

; Function calls

(decorator) @function
(decorator
  (identifier) @function)

(call
  function: (attribute attribute: (identifier) @function.method))
(call
  function: (identifier) @function)

; Builtin functions

((call
  function: (identifier) @function.builtin)
 (#match?
   @function.builtin
   "^(abs|all|any|ascii|bin|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|complex|delattr|dict|dir|divmod|enumerate|eval|exec|filter|float|format|frozenset|getattr|globals|hasattr|hash|help|hex|id|input|int|isinstance|issubclass|iter|len|list|locals|map|max|memoryview|min|next|object|oct|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip|__import__)$"))

; Function definitions

(function_definition
  name: (identifier) @function)

(attribute attribute: (identifier) @property)
(type (identifier) @type)

; Literals

[
  (none)
  (true)
  (false)
] @constant.builtin

[
  (integer)
  (float)
] @number

(comment) @comment
(string) @string
(escape_sequence) @escape

(interpolation
  "{" @punctuation.special
  "}" @punctuation.special) @embedded

[
  "-"
  "-="
  "!="
  "*"
  "**"
  "**="
  "*="
  "/"
  "//"
  "//="
  "/="
  "&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "->"
  "+="
  "<"
  "<<"
  "<<="
  "<="
  "<>"
  "="
  ":="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "~"
  "@="
  "and"
  "in"
  "is"
  "not"
  "or"
  "is not"
  "not in"
] @operator

[
  "as"
  "assert"
  "async"
  "await"
  "break"
  "class"
  "continue"
  "def"
  "del"
  "elif"
  "else"
  "except"
  "exec"
  "finally"
  "for"
  "from"
  "global"
  "if"
  "import"
  "lambda"
  "nonlocal"
  "pass"
  "print"
  "raise"
  "return"
  "try"
  "while"
  "with"
  "yield"
  "match"
  "case"
] @keyword
"""#

  static let go = #"""
; Function calls

(call_expression
  function: (identifier) @function)

(call_expression
  function: (identifier) @function.builtin
  (#match? @function.builtin "^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$"))

(call_expression
  function: (selector_expression
    field: (field_identifier) @function.method))

; Function definitions

(function_declaration
  name: (identifier) @function)

(method_declaration
  name: (field_identifier) @function.method)

; Identifiers

(type_identifier) @type
(field_identifier) @property
(identifier) @variable

; Operators

[
  "--"
  "-"
  "-="
  ":="
  "!"
  "!="
  "..."
  "*"
  "*"
  "*="
  "/"
  "/="
  "&"
  "&&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "++"
  "+="
  "<-"
  "<"
  "<<"
  "<<="
  "<="
  "="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "||"
  "~"
] @operator

; Keywords

[
  "break"
  "case"
  "chan"
  "const"
  "continue"
  "default"
  "defer"
  "else"
  "fallthrough"
  "for"
  "func"
  "go"
  "goto"
  "if"
  "import"
  "interface"
  "map"
  "package"
  "range"
  "return"
  "select"
  "struct"
  "switch"
  "type"
  "var"
] @keyword

; Literals

[
  (interpreted_string_literal)
  (raw_string_literal)
  (rune_literal)
] @string

(escape_sequence) @escape

[
  (int_literal)
  (float_literal)
  (imaginary_literal)
] @number

[
  (true)
  (false)
  (nil)
  (iota)
] @constant.builtin

(comment) @comment
"""#

  static let rust = #"""
; Identifiers

(type_identifier) @type
(primitive_type) @type.builtin
(field_identifier) @property

; Identifier conventions

; Assume all-caps names are constants
((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]+$'"))

; Assume uppercase names are enum constructors
((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

; Assume that uppercase names in paths are types
((scoped_identifier
  path: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_identifier
  path: (scoped_identifier
    name: (identifier) @type))
 (#match? @type "^[A-Z]"))
((scoped_type_identifier
  path: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_type_identifier
  path: (scoped_identifier
    name: (identifier) @type))
 (#match? @type "^[A-Z]"))

; Assume all qualified names in struct patterns are enum constructors. (They're
; either that, or struct names; highlighting both as constructors seems to be
; the less glaring choice of error, visually.)
(struct_pattern
  type: (scoped_type_identifier
    name: (type_identifier) @constructor))

; Function calls

(call_expression
  function: (identifier) @function)
(call_expression
  function: (field_expression
    field: (field_identifier) @function.method))
(call_expression
  function: (scoped_identifier
    "::"
    name: (identifier) @function))

(generic_function
  function: (identifier) @function)
(generic_function
  function: (scoped_identifier
    name: (identifier) @function))
(generic_function
  function: (field_expression
    field: (field_identifier) @function.method))

(macro_invocation
  macro: (identifier) @function.macro
  "!" @function.macro)

; Function definitions

(function_item (identifier) @function)
(function_signature_item (identifier) @function)

(line_comment) @comment
(block_comment) @comment

(line_comment (doc_comment)) @comment.documentation
(block_comment (doc_comment)) @comment.documentation

"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)
(type_parameters
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

"::" @punctuation.delimiter
":" @punctuation.delimiter
"." @punctuation.delimiter
"," @punctuation.delimiter
";" @punctuation.delimiter

(parameter (identifier) @variable.parameter)

(lifetime (identifier) @label)

"as" @keyword
"async" @keyword
"await" @keyword
"break" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"dyn" @keyword
"else" @keyword
"enum" @keyword
"extern" @keyword
"fn" @keyword
"for" @keyword
"gen" @keyword
"if" @keyword
"impl" @keyword
"in" @keyword
"let" @keyword
"loop" @keyword
"macro_rules!" @keyword
"match" @keyword
"mod" @keyword
"move" @keyword
"pub" @keyword
"raw" @keyword
"ref" @keyword
"return" @keyword
"static" @keyword
"struct" @keyword
"trait" @keyword
"type" @keyword
"union" @keyword
"unsafe" @keyword
"use" @keyword
"where" @keyword
"while" @keyword
"yield" @keyword
(crate) @keyword
(mutable_specifier) @keyword
(use_list (self) @keyword)
(scoped_use_list (self) @keyword)
(scoped_identifier (self) @keyword)
(super) @keyword

(self) @variable.builtin

(char_literal) @string
(string_literal) @string
(raw_string_literal) @string

(boolean_literal) @constant.builtin
(integer_literal) @constant.builtin
(float_literal) @constant.builtin

(escape_sequence) @escape

(attribute_item) @attribute
(inner_attribute_item) @attribute

"*" @operator
"&" @operator
"'" @operator
"""#

  static let shell = #"""
[
  (string)
  (raw_string)
  (heredoc_body)
  (heredoc_start)
] @string

(command_name) @function

(variable_name) @property

[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "select"
  "then"
  "unset"
  "until"
  "while"
] @keyword

(comment) @comment

(function_definition name: (word) @function)

(file_descriptor) @number

[
  (command_substitution)
  (process_substitution)
  (expansion)
]@embedded

[
  "$"
  "&&"
  ">"
  ">>"
  "<"
  "|"
] @operator

(
  (command (_) @constant)
  (#match? @constant "^-")
)
"""#

  static let javascript = #"""
; Variables
;----------

(identifier) @variable

; Properties
;-----------

(property_identifier) @property

; Function and method definitions
;--------------------------------

(function_expression
  name: (identifier) @function)
(function_declaration
  name: (identifier) @function)
(method_definition
  name: (property_identifier) @function.method)

(pair
  key: (property_identifier) @function.method
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (member_expression
    property: (property_identifier) @function.method)
  right: [(function_expression) (arrow_function)])

(variable_declarator
  name: (identifier) @function
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (identifier) @function
  right: [(function_expression) (arrow_function)])

; Function and method calls
;--------------------------

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))

; Special identifiers
;--------------------

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

([
    (identifier)
    (shorthand_property_identifier)
    (shorthand_property_identifier_pattern)
 ] @constant
 (#match? @constant "^[A-Z_][A-Z\\d_]+$"))

((identifier) @variable.builtin
 (#match? @variable.builtin "^(arguments|module|console|window|document)$")
 (#is-not? local))

((identifier) @function.builtin
 (#eq? @function.builtin "require")
 (#is-not? local))

; Literals
;---------

(this) @variable.builtin
(super) @variable.builtin

[
  (true)
  (false)
  (null)
  (undefined)
] @constant.builtin

(comment) @comment

[
  (string)
  (template_string)
] @string

(regex) @string.special
(number) @number

; Tokens
;-------

[
  ";"
  (optional_chain)
  "."
  ","
] @punctuation.delimiter

[
  "-"
  "--"
  "-="
  "+"
  "++"
  "+="
  "*"
  "*="
  "**"
  "**="
  "/"
  "/="
  "%"
  "%="
  "<"
  "<="
  "<<"
  "<<="
  "="
  "=="
  "==="
  "!"
  "!="
  "!=="
  "=>"
  ">"
  ">="
  ">>"
  ">>="
  ">>>"
  ">>>="
  "~"
  "^"
  "&"
  "|"
  "^="
  "&="
  "|="
  "&&"
  "||"
  "??"
  "&&="
  "||="
  "??="
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
]  @punctuation.bracket

(template_substitution
  "${" @punctuation.special
  "}" @punctuation.special) @embedded

[
  "as"
  "async"
  "await"
  "break"
  "case"
  "catch"
  "class"
  "const"
  "continue"
  "debugger"
  "default"
  "delete"
  "do"
  "else"
  "export"
  "extends"
  "finally"
  "for"
  "from"
  "function"
  "get"
  "if"
  "import"
  "in"
  "instanceof"
  "let"
  "new"
  "of"
  "return"
  "set"
  "static"
  "switch"
  "target"
  "throw"
  "try"
  "typeof"
  "var"
  "void"
  "while"
  "with"
  "yield"
] @keyword
"""#

  static let typescript = #"""
; Variables
;----------

(identifier) @variable

; Properties
;-----------

(property_identifier) @property

; Function and method definitions
;--------------------------------

(function_expression
  name: (identifier) @function)
(function_declaration
  name: (identifier) @function)
(method_definition
  name: (property_identifier) @function.method)

(pair
  key: (property_identifier) @function.method
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (member_expression
    property: (property_identifier) @function.method)
  right: [(function_expression) (arrow_function)])

(variable_declarator
  name: (identifier) @function
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (identifier) @function
  right: [(function_expression) (arrow_function)])

; Function and method calls
;--------------------------

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))

; Special identifiers
;--------------------

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

([
    (identifier)
    (shorthand_property_identifier)
    (shorthand_property_identifier_pattern)
 ] @constant
 (#match? @constant "^[A-Z_][A-Z\\d_]+$"))

((identifier) @variable.builtin
 (#match? @variable.builtin "^(arguments|module|console|window|document)$")
 (#is-not? local))

((identifier) @function.builtin
 (#eq? @function.builtin "require")
 (#is-not? local))

; Literals
;---------

(this) @variable.builtin
(super) @variable.builtin

[
  (true)
  (false)
  (null)
  (undefined)
] @constant.builtin

(comment) @comment

[
  (string)
  (template_string)
] @string

(regex) @string.special
(number) @number

; Tokens
;-------

[
  ";"
  (optional_chain)
  "."
  ","
] @punctuation.delimiter

[
  "-"
  "--"
  "-="
  "+"
  "++"
  "+="
  "*"
  "*="
  "**"
  "**="
  "/"
  "/="
  "%"
  "%="
  "<"
  "<="
  "<<"
  "<<="
  "="
  "=="
  "==="
  "!"
  "!="
  "!=="
  "=>"
  ">"
  ">="
  ">>"
  ">>="
  ">>>"
  ">>>="
  "~"
  "^"
  "&"
  "|"
  "^="
  "&="
  "|="
  "&&"
  "||"
  "??"
  "&&="
  "||="
  "??="
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
]  @punctuation.bracket

(template_substitution
  "${" @punctuation.special
  "}" @punctuation.special) @embedded

[
  "as"
  "async"
  "await"
  "break"
  "case"
  "catch"
  "class"
  "const"
  "continue"
  "debugger"
  "default"
  "delete"
  "do"
  "else"
  "export"
  "extends"
  "finally"
  "for"
  "from"
  "function"
  "get"
  "if"
  "import"
  "in"
  "instanceof"
  "let"
  "new"
  "of"
  "return"
  "set"
  "static"
  "switch"
  "target"
  "throw"
  "try"
  "typeof"
  "var"
  "void"
  "while"
  "with"
  "yield"
] @keyword
; Types

(type_identifier) @type
(predefined_type) @type.builtin

((identifier) @type
 (#match? @type "^[A-Z]"))

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; Variables

(required_parameter (identifier) @variable.parameter)
(optional_parameter (identifier) @variable.parameter)

; Keywords

[ "abstract"
  "declare"
  "enum"
  "export"
  "implements"
  "interface"
  "keyof"
  "namespace"
  "private"
  "protected"
  "public"
  "type"
  "readonly"
  "override"
  "satisfies"
] @keyword
"""#

  static let swift = #"""
[
  "."
  ";"
  ":"
  ","
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

; Identifiers
(type_identifier) @type

[
  (self_expression)
  (super_expression)
] @variable.builtin

; Declarations
[
  "func"
  "deinit"
] @keyword.function

[
  (visibility_modifier)
  (member_modifier)
  (function_modifier)
  (property_modifier)
  (parameter_modifier)
  (inheritance_modifier)
  (mutation_modifier)
] @keyword.modifier

(simple_identifier) @variable

(function_declaration
  (simple_identifier) @function.method)

(protocol_function_declaration
  name: (simple_identifier) @function.method)

(init_declaration
  "init" @constructor)

(parameter
  external_name: (simple_identifier) @variable.parameter)

(parameter
  name: (simple_identifier) @variable.parameter)

(type_parameter
  (type_identifier) @variable.parameter)

(inheritance_constraint
  (identifier
    (simple_identifier) @variable.parameter))

(equality_constraint
  (identifier
    (simple_identifier) @variable.parameter))

[
  "protocol"
  "extension"
  "indirect"
  "nonisolated"
  "override"
  "convenience"
  "required"
  "some"
  "any"
  "weak"
  "unowned"
  "didSet"
  "willSet"
  "subscript"
  "let"
  "var"
  (throws)
  (where_keyword)
  (getter_specifier)
  (setter_specifier)
  (modify_specifier)
  (else)
  (as_operator)
] @keyword

[
  "enum"
  "struct"
  "class"
  "typealias"
] @keyword.type

[
  "async"
  "await"
] @keyword.coroutine

(shebang_line) @keyword.directive

(class_body
  (property_declaration
    (pattern
      (simple_identifier) @variable.member)))

(protocol_property_declaration
  (pattern
    (simple_identifier) @variable.member))

(navigation_expression
  (navigation_suffix
    (simple_identifier) @variable.member))

(value_argument
  name: (value_argument_label
    (simple_identifier) @variable.member))

(import_declaration
  "import" @keyword.import)

(enum_entry
  "case" @keyword)

(modifiers
  (attribute
    "@" @attribute
    (user_type
      (type_identifier) @attribute)))

; Function calls
(call_expression
  (simple_identifier) @function.call) ; foo()

(call_expression
  ; foo.bar.baz(): highlight the baz()
  (navigation_expression
    (navigation_suffix
      (simple_identifier) @function.call)))

(call_expression
  (prefix_expression
    (simple_identifier) @function.call)) ; .foo()

((navigation_expression
  (simple_identifier) @type) ; SomeType.method(): highlight SomeType as a type
  (#match? @type "^[A-Z]"))

(directive) @keyword.directive

; See https://docs.swift.org/swift-book/documentation/the-swift-programming-language/lexicalstructure/#Keywords-and-Punctuation
[
  (diagnostic)
  (availability_condition)
  (playground_literal)
  (key_path_string_expression)
  (selector_expression)
  (external_macro_definition)
] @function.macro

(special_literal) @constant.macro

; Statements
(for_statement
  "for" @keyword.repeat)

(for_statement
  "in" @keyword.repeat)

[
  "while"
  "repeat"
  "continue"
  "break"
] @keyword.repeat

(guard_statement
  "guard" @keyword.conditional)

(if_statement
  "if" @keyword.conditional)

(switch_statement
  "switch" @keyword.conditional)

(switch_entry
  "case" @keyword)

(switch_entry
  "fallthrough" @keyword)

(switch_entry
  (default_keyword) @keyword)

"return" @keyword.return

(ternary_expression
  [
    "?"
    ":"
  ] @keyword.conditional.ternary)

[
  (try_operator)
  "do"
  (throw_keyword)
  (catch_keyword)
] @keyword.exception

(statement_label) @label

; Comments
[
  (comment)
  (multiline_comment)
] @comment @spell

((comment) @comment.documentation
  (#match? @comment.documentation "^///[^/]"))

((comment) @comment.documentation
  (#match? @comment.documentation "^///$"))

((multiline_comment) @comment.documentation
  (#match? @comment.documentation "^/[*][*][^*].*[*]/$"))

; String literals
(line_str_text) @string

(str_escaped_char) @string.escape

(multi_line_str_text) @string

(raw_str_part) @string

(raw_str_end_part) @string

(line_string_literal
  [
    "\\("
    ")"
  ] @punctuation.special)

(multi_line_string_literal
  [
    "\\("
    ")"
  ] @punctuation.special)

(raw_str_interpolation
  [
    (raw_str_interpolation_start)
    ")"
  ] @punctuation.special)

[
  "\""
  "\"\"\""
] @string

; Lambda literals
(lambda_literal
  "in" @keyword.operator)

; Basic literals
[
  (integer_literal)
  (hex_literal)
  (oct_literal)
  (bin_literal)
] @number

(real_literal) @number.float

(boolean_literal) @boolean

(nil_literal) @constant.builtin

(wildcard_pattern) @character.special

; Regex literals
(regex_literal) @string.regexp

; Operators
(custom_operator) @operator

[
  "+"
  "-"
  "*"
  "/"
  "%"
  "="
  "+="
  "-="
  "*="
  "/="
  "<"
  ">"
  "<<"
  ">>"
  "<="
  ">="
  "++"
  "--"
  "^"
  "&"
  "&&"
  "|"
  "||"
  "~"
  "%="
  "!="
  "!=="
  "=="
  "==="
  "?"
  "??"
  "->"
  "..<"
  "..."
  (bang)
] @operator

(type_arguments
  [
    "<"
    ">"
  ] @punctuation.bracket)
"""#

  static let markdown = #"""
;From nvim-treesitter/nvim-treesitter
(atx_heading
  (inline) @text.title)

(setext_heading
  (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

[
  (link_title)
  (indented_code_block)
  (fenced_code_block)
] @text.literal

(fenced_code_block_delimiter) @punctuation.delimiter

(code_fence_content) @none

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation.special

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

(backslash_escape) @string.escape
"""#
}
