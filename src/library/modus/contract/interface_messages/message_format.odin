// W3C MessageFormat 2 parser and zero-allocation evaluator
// (src/md/features/interface_language.md).
//
// Supports simple patterns with escapes (\{, \}, \\, \|), complex quoted
// patterns, .input and .local declarations, .match selectors with exact keys,
// CLDR plural categories, and mandatory catch-all * fallback, and the built-in
// functions :integer, :number, and :string.
//
// This is a freestanding contract package: it imports base and contract
// packages only, calls no kernel operation, and allocates no memory.
package interface_messages

import "modus:contract/language_tag"
import "modus:contract/text_encoding"

// Maximum byte length of a single MF2 message pattern.
MESSAGE_PATTERN_MAX_BYTES :: 4096

// Maximum number of .input and .local declarations in one message.
MESSAGE_MAX_DECLARATIONS :: 16

// Maximum number of selectors in one .match statement.
MESSAGE_MAX_SELECTORS :: 4

// Maximum number of variants in one .match statement.
MESSAGE_MAX_VARIANTS :: 32

// Maximum number of literal and expression parts in one pattern.
MESSAGE_MAX_PARTS :: 64

// Maximum number of function options on a single expression.
MESSAGE_MAX_OPTIONS :: 8

// Maximum total options stored across all declarations of one message.
MESSAGE_MAX_DECLARATION_OPTIONS :: 64

// Maximum number of runtime arguments passed to message evaluation.
MESSAGE_MAX_ARGUMENTS :: 32

// Maximum byte length of a variable, function, option, or unquoted literal name.
MESSAGE_IDENTIFIER_MAX_BYTES :: 64

// Maximum indirection depth for .local chains and expression nesting.
MESSAGE_MAX_NESTING_DEPTH :: 4

// Maximum value accepted for minimumIntegerDigits.
MESSAGE_MIN_INTEGER_DIGITS_LIMIT :: 20

// Closed set of outcomes from parsing or evaluating an MF2 message.
Message_Status :: enum u32 {
	Ok                       = 0,
	Invalid_Utf8             = 1,
	Pattern_Too_Long         = 2,
	Syntax_Error             = 3,
	Unterminated_Expression  = 4,
	Unexpected_Close_Brace   = 5,
	Invalid_Escape           = 6,
	Unknown_Function         = 7,
	Invalid_Option           = 8,
	Duplicate_Declaration    = 9,
	Missing_Fallback_Variant = 10,
	Duplicate_Variant_Key    = 11,
	Variant_Key_Mismatch     = 12,
	Too_Many_Declarations    = 13,
	Too_Many_Selectors       = 14,
	Too_Many_Variants        = 15,
	Too_Many_Parts           = 16,
	Too_Many_Options         = 17,
	Nesting_Too_Deep         = 18,
	Missing_Variable         = 19,
	Type_Mismatch            = 20,
	Buffer_Too_Small         = 21,
	Invalid_Locale           = 22,
}

// Typed argument payloads passed into MF2 evaluation.
Integer :: distinct i64
Unsigned :: distinct u64
Text :: distinct string

// Tagged union of values an MF2 variable can hold.
Message_Value :: union {
	Integer,
	Unsigned,
	Text,
}

// One named argument supplied by the caller at message evaluation time.
Message_Argument :: struct {
	name:  string,
	value: Message_Value,
}

// Closed set of built-in MF2 formatting and selection functions.
Message_Function :: enum u8 {
	None    = 0,
	Integer = 1,
	Number  = 2,
	String  = 3,
}

// Closed structural kind of a parsed MF2 message.
Message_Kind :: enum u8 {
	Simple          = 0,
	Complex_Pattern = 1,
	Complex_Matcher = 2,
}

// Closed kind of an MF2 declaration.
Declaration_Kind :: enum u8 {
	Input = 0,
	Local = 1,
}

// Closed kind of an expression operand or option value.
Operand_Kind :: enum u8 {
	Variable         = 0,
	Unquoted_Literal = 1,
	Quoted_Literal   = 2,
}

// Closed kind of a variant key in a .match arm.
Variant_Key_Kind :: enum u8 {
	Wildcard         = 0,
	Unquoted_Literal = 1,
	Quoted_Literal   = 2,
}

// Closed selection mode option for :integer and :number.
Select_Mode :: enum u8 {
	Plural = 0,
	Exact  = 1,
}

// Closed grouping mode option for :integer and :number.
Grouping_Mode :: enum u8 {
	Auto   = 0,
	Always = 1,
	Never  = 2,
}

// Compact byte slice into the message source text.
Text_Span :: struct {
	offset: u16,
	length: u16,
}

// One option parsed on a function expression (name=value).
Message_Option :: struct {
	name:       Text_Span,
	value_kind: Operand_Kind,
	value:      Text_Span,
}

// One parsed MF2 expression inside braces.
Message_Expression :: struct {
	operand_kind: Operand_Kind,
	operand:      Text_Span,
	function:     Message_Function,
	option_start: u16,
	option_count: u8,
}

// One parsed .input or .local declaration.
Message_Declaration :: struct {
	kind:          Declaration_Kind,
	variable_name: Text_Span,
	expression:    Message_Expression,
	nesting_depth: u8,
}

// One key of a .match variant arm.
Variant_Key :: struct {
	kind: Variant_Key_Kind,
	text: Text_Span,
}

// One variant arm of a .match statement.
Message_Variant :: struct {
	keys:    [MESSAGE_MAX_SELECTORS]Variant_Key,
	pattern: Text_Span,
}

// Stack-allocated parsed representation of one validated MF2 message.
Parsed_Message :: struct {
	source:                   string,
	kind:                     Message_Kind,
	declaration_count:        u8,
	selector_count:           u8,
	variant_count:            u8,
	declarations:             [MESSAGE_MAX_DECLARATIONS]Message_Declaration,
	declaration_options:      [MESSAGE_MAX_DECLARATION_OPTIONS]Message_Option,
	declaration_option_count: u16,
	selectors:                [MESSAGE_MAX_SELECTORS]Text_Span,
	variants:                 [MESSAGE_MAX_VARIANTS]Message_Variant,
	simple_pattern:           Text_Span,
}

// Internal resolved variable binding computed during evaluation.
@(private = "file")
Resolved_Binding :: struct {
	name:                   string,
	value:                  Message_Value,
	function:               Message_Function,
	select_mode:            Select_Mode,
	grouping_mode:          Grouping_Mode,
	minimum_integer_digits: u8,
}

// Fixed-capacity destination cursor for zero-allocation formatting.
@(private = "file")
Output_Cursor :: struct {
	destination: []u8,
	position:    int,
	overflow:    bool,
}

@(private = "file")
output_append_byte :: proc "contextless" (cursor: ^Output_Cursor, value: u8) {
	if cursor.overflow || cursor.position >= len(cursor.destination) {
		cursor.overflow = true
		return
	}
	cursor.destination[cursor.position] = value
	cursor.position += 1
}

@(private = "file")
output_append_string :: proc "contextless" (cursor: ^Output_Cursor, text: string) {
	raw := transmute([]u8)text
	if cursor.overflow || len(cursor.destination) - cursor.position < len(raw) {
		cursor.overflow = true
		return
	}
	for index in 0 ..< len(raw) {
		cursor.destination[cursor.position + index] = raw[index]
	}
	cursor.position += len(raw)
}

@(private = "file")
span_text :: proc "contextless" (source: string, span: Text_Span) -> string {
	start := int(span.offset)
	end := start + int(span.length)
	if start < 0 || end > len(source) || start > end {
		return ""
	}
	return source[start:end]
}

@(private = "file")
is_structural_whitespace :: proc "contextless" (value: u8) -> bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r'
}

@(private = "file")
is_horizontal_whitespace :: proc "contextless" (value: u8) -> bool {
	return value == ' ' || value == '\t'
}

@(private = "file")
is_identifier_start :: proc "contextless" (value: u8) -> bool {
	return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || value == '_'
}

@(private = "file")
is_identifier_continue :: proc "contextless" (value: u8) -> bool {
	return is_identifier_start(value) || (value >= '0' && value <= '9') || value == '-' || value == '.'
}

@(private = "file")
is_unquoted_literal_byte :: proc "contextless" (value: u8) -> bool {
	return (value >= 'a' && value <= 'z') ||
		(value >= 'A' && value <= 'Z') ||
		(value >= '0' && value <= '9') ||
		value == '_' ||
		value == '-' ||
		value == '.' ||
		value == '+'
}

@(private = "file")
skip_structural_whitespace :: proc "contextless" (source: string, start: int) -> int {
	pos := start
	for pos < len(source) && is_structural_whitespace(source[pos]) {
		pos += 1
	}
	return pos
}

@(private = "file")
has_keyword_at :: proc "contextless" (source: string, pos: int, keyword: string) -> bool {
	if pos + len(keyword) > len(source) {
		return false
	}
	if source[pos:pos + len(keyword)] != keyword {
		return false
	}
	if pos + len(keyword) == len(source) {
		return true
	}
	next := source[pos + len(keyword)]
	return is_structural_whitespace(next) || next == '{' || next == '$'
}

// validate_source_bytes ensures the entire message contains well-formed UTF-8
// with no forbidden control or hidden characters. Structural newlines and tabs
// are allowed only when allow_structural_whitespace is true.
@(private = "file")
validate_source_bytes :: proc "contextless" (source: string, allow_structural_whitespace: bool) -> (bad_offset: int, ok: bool) {
	raw := transmute([]u8)source
	offset := 0
	for offset < len(raw) {
		if allow_structural_whitespace && (raw[offset] == '\n' || raw[offset] == '\r' || raw[offset] == '\t') {
			offset += 1
			continue
		}
		character, length, valid := text_encoding.character_decode(raw, offset)
		if !valid || length == 0 || text_encoding.character_hidden(character) {
			return offset, false
		}
		offset += length
	}
	return 0, true
}

// read_identifier parses an ASCII MF2 identifier starting at start.
@(private = "file")
read_identifier :: proc "contextless" (source: string, start: int, limit: int) -> (span: Text_Span, next_pos: int, ok: bool) {
	if start >= limit || !is_identifier_start(source[start]) {
		return {}, start, false
	}
	pos := start + 1
	for pos < limit && is_identifier_continue(source[pos]) {
		pos += 1
	}
	length := pos - start
	if length == 0 || length > MESSAGE_IDENTIFIER_MAX_BYTES {
		return {}, start, false
	}
	return Text_Span{offset = u16(start), length = u16(length)}, pos, true
}

// read_unquoted_literal parses an unquoted nmtoken or numeric literal.
@(private = "file")
read_unquoted_literal :: proc "contextless" (source: string, start: int, limit: int) -> (span: Text_Span, next_pos: int, ok: bool) {
	if start >= limit || !is_unquoted_literal_byte(source[start]) {
		return {}, start, false
	}
	pos := start
	for pos < limit && is_unquoted_literal_byte(source[pos]) {
		pos += 1
	}
	length := pos - start
	if length == 0 || length > MESSAGE_IDENTIFIER_MAX_BYTES {
		return {}, start, false
	}
	return Text_Span{offset = u16(start), length = u16(length)}, pos, true
}

// read_quoted_literal parses |...| with escape checking (\|, \\, \{, \}) and
// strict UTF-8 validation.
@(private = "file")
read_quoted_literal :: proc "contextless" (source: string, open_pipe_pos: int, limit: int) -> (span: Text_Span, next_pos: int, status: Message_Status) {
	raw := transmute([]u8)source
	pos := open_pipe_pos + 1
	content_start := pos
	for pos < limit {
		byte_val := raw[pos]
		if byte_val == '\\' {
			if pos + 1 >= limit {
				return {}, pos, .Invalid_Escape
			}
			escaped := raw[pos + 1]
			if escaped != '\\' && escaped != '|' && escaped != '{' && escaped != '}' {
				return {}, pos, .Invalid_Escape
			}
			pos += 2
			continue
		}
		if byte_val == '|' {
			return Text_Span{offset = u16(content_start), length = u16(pos - content_start)}, pos + 1, .Ok
		}
		character, length, valid := text_encoding.character_decode(raw, pos)
		if !valid || length == 0 || text_encoding.character_hidden(character) {
			return {}, pos, .Invalid_Utf8
		}
		pos += length
	}
	return {}, open_pipe_pos, .Unterminated_Expression
}

// unescaped_quoted_equal compares two literal spans after resolving valid
// escape sequences inside quoted literals.
@(private = "file")
unescaped_literal_equal :: proc "contextless" (source: string, first_kind: Variant_Key_Kind, first_span: Text_Span, second_kind: Variant_Key_Kind, second_span: Text_Span) -> bool {
	if first_kind == .Wildcard || second_kind == .Wildcard {
		return first_kind == .Wildcard && second_kind == .Wildcard
	}
	first_text := span_text(source, first_span)
	second_text := span_text(source, second_span)
	first_pos := 0
	second_pos := 0
	for {
		first_done := first_pos >= len(first_text)
		second_done := second_pos >= len(second_text)
		if first_done || second_done {
			return first_done && second_done
		}
		first_byte := first_text[first_pos]
		if first_kind == .Quoted_Literal && first_byte == '\\' && first_pos + 1 < len(first_text) {
			first_pos += 1
			first_byte = first_text[first_pos]
		}
		second_byte := second_text[second_pos]
		if second_kind == .Quoted_Literal && second_byte == '\\' && second_pos + 1 < len(second_text) {
			second_pos += 1
			second_byte = second_text[second_pos]
		}
		if first_byte != second_byte {
			return false
		}
		first_pos += 1
		second_pos += 1
	}
}

// unescaped_literal_equals_string checks whether a literal span (unquoted or
// quoted with escapes) equals target byte-for-byte.
@(private = "file")
unescaped_literal_equals_string :: proc "contextless" (source: string, kind: Operand_Kind, span: Text_Span, target: string) -> bool {
	text := span_text(source, span)
	src_pos := 0
	target_pos := 0
	for {
		src_done := src_pos >= len(text)
		target_done := target_pos >= len(target)
		if src_done || target_done {
			return src_done && target_done
		}
		src_byte := text[src_pos]
		if kind == .Quoted_Literal && src_byte == '\\' && src_pos + 1 < len(text) {
			src_pos += 1
			src_byte = text[src_pos]
		}
		if src_byte != target[target_pos] {
			return false
		}
		src_pos += 1
		target_pos += 1
	}
}

// write_unescaped_literal appends an unquoted or quoted literal into cursor.
@(private = "file")
write_unescaped_literal :: proc "contextless" (cursor: ^Output_Cursor, source: string, kind: Operand_Kind, span: Text_Span) {
	text := span_text(source, span)
	pos := 0
	for pos < len(text) {
		byte_val := text[pos]
		if kind == .Quoted_Literal && byte_val == '\\' && pos + 1 < len(text) {
			pos += 1
			byte_val = text[pos]
		}
		output_append_byte(cursor, byte_val)
		pos += 1
	}
}

// parse_signed_decimal parses a base-10 signed 64-bit integer without wrapping.
@(private = "file")
parse_signed_decimal :: proc "contextless" (text: string) -> (value: i64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	negative := false
	pos := 0
	if text[0] == '-' {
		negative = true
		pos = 1
	}
	if pos >= len(text) {
		return 0, false
	}
	limit: u64 = negative ? (u64(max(i64)) + 1) : u64(max(i64))
	accumulator: u64 = 0
	for ; pos < len(text); pos += 1 {
		ch := text[pos]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		digit := u64(ch - '0')
		if accumulator > (limit - digit) / 10 {
			return 0, false
		}
		accumulator = accumulator * 10 + digit
	}
	if negative {
		if accumulator == u64(max(i64)) + 1 {
			return min(i64), true
		}
		return -i64(accumulator), true
	}
	return i64(accumulator), true
}

// parse_unsigned_decimal parses a base-10 unsigned 64-bit integer without wrapping.
@(private = "file")
parse_unsigned_decimal :: proc "contextless" (text: string) -> (value: u64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	accumulator: u64 = 0
	for pos in 0 ..< len(text) {
		ch := text[pos]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		digit := u64(ch - '0')
		if accumulator > (max(u64) - digit) / 10 {
			return 0, false
		}
		accumulator = accumulator * 10 + digit
	}
	return accumulator, true
}

// literal_to_numeric_value converts a literal span into Integer or Unsigned.
@(private = "file")
literal_to_numeric_value :: proc "contextless" (source: string, kind: Operand_Kind, span: Text_Span) -> (value: Message_Value, ok: bool) {
	buffer: [MESSAGE_IDENTIFIER_MAX_BYTES]u8
	cursor := Output_Cursor{destination = buffer[:]}
	write_unescaped_literal(&cursor, source, kind, span)
	if cursor.overflow || cursor.position == 0 {
		return nil, false
	}
	text := string(buffer[:cursor.position])
	if text[0] == '-' {
		signed_val, signed_ok := parse_signed_decimal(text)
		if !signed_ok {
			return nil, false
		}
		return Integer(signed_val), true
	}
	if signed_val, signed_ok := parse_signed_decimal(text); signed_ok {
		return Integer(signed_val), true
	}
	unsigned_val, unsigned_ok := parse_unsigned_decimal(text)
	if !unsigned_ok {
		return nil, false
	}
	return Unsigned(unsigned_val), true
}

// validate_function_option checks an option name and static value against the
// built-in function specification.
@(private = "file")
validate_function_option :: proc "contextless" (source: string, function: Message_Function, option: Message_Option) -> Message_Status {
	option_name := span_text(source, option.name)
	switch function {
	case .None, .String:
		return .Invalid_Option
	case .Integer, .Number:
		switch option_name {
		case "select":
			if option.value_kind != .Variable {
				if !unescaped_literal_equals_string(source, option.value_kind, option.value, "plural") &&
					!unescaped_literal_equals_string(source, option.value_kind, option.value, "exact") {
					return .Invalid_Option
				}
			}
			return .Ok
		case "useGrouping":
			if option.value_kind != .Variable {
				if !unescaped_literal_equals_string(source, option.value_kind, option.value, "auto") &&
					!unescaped_literal_equals_string(source, option.value_kind, option.value, "always") &&
					!unescaped_literal_equals_string(source, option.value_kind, option.value, "never") {
					return .Invalid_Option
				}
			}
			return .Ok
		case "minimumIntegerDigits":
			if option.value_kind != .Variable {
				numeric_val, num_ok := literal_to_numeric_value(source, option.value_kind, option.value)
				if !num_ok {
					return .Invalid_Option
				}
				switch v in numeric_val {
				case Integer:
					if v < 1 || v > MESSAGE_MIN_INTEGER_DIGITS_LIMIT {
						return .Invalid_Option
					}
				case Unsigned:
					if v < 1 || v > MESSAGE_MIN_INTEGER_DIGITS_LIMIT {
						return .Invalid_Option
					}
				case Text:
					return .Invalid_Option
				}
			}
			return .Ok
		}
		return .Invalid_Option
	}
	return .Invalid_Option
}

// parse_expression parses one {...} expression starting at open_brace_pos.
@(private = "file")
parse_expression :: proc "contextless" (source: string, open_brace_pos: int, limit: int, options_out: []Message_Option) -> (expr: Message_Expression, next_pos: int, error_offset: int, status: Message_Status) {
	pos := open_brace_pos + 1
	for pos < limit && is_structural_whitespace(source[pos]) {
		pos += 1
	}
	if pos >= limit {
		return {}, pos, open_brace_pos, .Unterminated_Expression
	}
	if source[pos] == '{' {
		return {}, pos, pos, .Nesting_Too_Deep
	}
	if source[pos] == '}' {
		return {}, pos, pos, .Syntax_Error
	}

	// Parse operand: $variable, |quoted|, or unquoted literal.
	switch source[pos] {
	case '$':
		name_span, after_name, name_ok := read_identifier(source, pos + 1, limit)
		if !name_ok {
			return {}, pos, pos, .Syntax_Error
		}
		expr.operand_kind = .Variable
		expr.operand = name_span
		pos = after_name
	case '|':
		quoted_span, after_quoted, quoted_status := read_quoted_literal(source, pos, limit)
		if quoted_status != .Ok {
			return {}, pos, pos, quoted_status
		}
		expr.operand_kind = .Quoted_Literal
		expr.operand = quoted_span
		pos = after_quoted
	case ':':
		return {}, pos, pos, .Syntax_Error
	case:
		lit_span, after_lit, lit_ok := read_unquoted_literal(source, pos, limit)
		if !lit_ok {
			return {}, pos, pos, .Syntax_Error
		}
		expr.operand_kind = .Unquoted_Literal
		expr.operand = lit_span
		pos = after_lit
	}

	after_operand := pos
	for pos < limit && is_structural_whitespace(source[pos]) {
		pos += 1
	}
	if pos >= limit {
		return {}, pos, open_brace_pos, .Unterminated_Expression
	}
	if source[pos] == '{' {
		return {}, pos, pos, .Nesting_Too_Deep
	}

	// Optional :function annotation and options.
	if source[pos] == ':' {
		if pos == after_operand {
			return {}, pos, pos, .Syntax_Error
		}
		func_start := pos + 1
		func_span, after_func, func_ok := read_identifier(source, func_start, limit)
		if !func_ok {
			return {}, pos, pos, .Syntax_Error
		}
		// Namespaced function names like :foo:bar are not in the built-in set.
		if after_func < limit && source[after_func] == ':' {
			return {}, after_func, pos, .Unknown_Function
		}
		func_name := span_text(source, func_span)
		switch func_name {
		case "integer":
			expr.function = .Integer
		case "number":
			expr.function = .Number
		case "string":
			expr.function = .String
		case:
			return {}, pos, pos, .Unknown_Function
		}
		pos = after_func

		for {
			before_ws := pos
			for pos < limit && is_structural_whitespace(source[pos]) {
				pos += 1
			}
			if pos >= limit {
				return {}, pos, open_brace_pos, .Unterminated_Expression
			}
			if source[pos] == '}' {
				break
			}
			if source[pos] == '{' {
				return {}, pos, pos, .Nesting_Too_Deep
			}
			if pos == before_ws {
				return {}, pos, pos, .Syntax_Error
			}

			opt_name_span, after_opt_name, opt_name_ok := read_identifier(source, pos, limit)
			if !opt_name_ok {
				return {}, pos, pos, .Syntax_Error
			}
			pos = after_opt_name
			for pos < limit && is_horizontal_whitespace(source[pos]) {
				pos += 1
			}
			if pos >= limit || source[pos] != '=' {
				return {}, pos, pos, .Syntax_Error
			}
			pos += 1
			for pos < limit && is_horizontal_whitespace(source[pos]) {
				pos += 1
			}
			if pos >= limit {
				return {}, pos, open_brace_pos, .Unterminated_Expression
			}

			option: Message_Option
			option.name = opt_name_span
			switch source[pos] {
			case '$':
				val_span, after_val, val_ok := read_identifier(source, pos + 1, limit)
				if !val_ok {
					return {}, pos, pos, .Syntax_Error
				}
				option.value_kind = .Variable
				option.value = val_span
				pos = after_val
			case '|':
				val_span, after_val, val_status := read_quoted_literal(source, pos, limit)
				if val_status != .Ok {
					return {}, pos, pos, val_status
				}
				option.value_kind = .Quoted_Literal
				option.value = val_span
				pos = after_val
			case:
				val_span, after_val, val_ok := read_unquoted_literal(source, pos, limit)
				if !val_ok {
					return {}, pos, pos, .Syntax_Error
				}
				option.value_kind = .Unquoted_Literal
				option.value = val_span
				pos = after_val
			}

			if int(expr.option_count) >= MESSAGE_MAX_OPTIONS || int(expr.option_count) >= len(options_out) {
				return {}, pos, int(opt_name_span.offset), .Too_Many_Options
			}
			options_out[expr.option_count] = option
			expr.option_count += 1
		}

		// Validate option uniqueness and semantics after checking option count bounds.
		for opt_index in 0 ..< int(expr.option_count) {
			option := options_out[opt_index]
			opt_name := span_text(source, option.name)
			for earlier_index in 0 ..< opt_index {
				if span_text(source, options_out[earlier_index].name) == opt_name {
					return {}, pos, int(option.name.offset), .Invalid_Option
				}
			}
			if opt_status := validate_function_option(source, expr.function, option); opt_status != .Ok {
				return {}, pos, int(option.name.offset), opt_status
			}
		}
	}

	if pos >= limit {
		return {}, pos, open_brace_pos, .Unterminated_Expression
	}
	if source[pos] == '{' {
		return {}, pos, pos, .Nesting_Too_Deep
	}
	if source[pos] != '}' {
		return {}, pos, pos, .Syntax_Error
	}
	return expr, pos + 1, 0, .Ok
}

// scan_pattern_span validates the syntax, escapes, UTF-8, expressions, and
// part count of a simple pattern or a {{ ... }} quoted pattern.
@(private = "file")
scan_pattern_span :: proc "contextless" (source: string, start: int, limit: int, is_quoted: bool) -> (pattern_span: Text_Span, after_pos: int, error_offset: int, status: Message_Status) {
	raw := transmute([]u8)source
	pos := start
	part_count := 0
	in_text := false
	inline_options: [MESSAGE_MAX_OPTIONS]Message_Option

	for pos < limit {
		ch := raw[pos]
		if ch == '\\' {
			if pos + 1 >= limit {
				return {}, pos, pos, .Invalid_Escape
			}
			next := raw[pos + 1]
			if next != '{' && next != '}' && next != '\\' && next != '|' {
				return {}, pos, pos, .Invalid_Escape
			}
			if !in_text {
				in_text = true
				part_count += 1
				if part_count > MESSAGE_MAX_PARTS {
					return {}, pos, pos, .Too_Many_Parts
				}
			}
			pos += 2
			continue
		}
		if ch == '{' {
			in_text = false
			part_count += 1
			if part_count > MESSAGE_MAX_PARTS {
				return {}, pos, pos, .Too_Many_Parts
			}
			_, next_pos, expr_err, expr_status := parse_expression(source, pos, limit, inline_options[:])
			if expr_status != .Ok {
				return {}, next_pos, expr_err, expr_status
			}
			pos = next_pos
			continue
		}
		if ch == '}' {
			if is_quoted && pos + 1 < limit && raw[pos + 1] == '}' {
				return Text_Span{offset = u16(start), length = u16(pos - start)}, pos + 2, 0, .Ok
			}
			return {}, pos, pos, .Unexpected_Close_Brace
		}
		character, length, valid := text_encoding.character_decode(raw, pos)
		if !valid || length == 0 || text_encoding.character_hidden(character) {
			return {}, pos, pos, .Invalid_Utf8
		}
		if !in_text {
			in_text = true
			part_count += 1
			if part_count > MESSAGE_MAX_PARTS {
				return {}, pos, pos, .Too_Many_Parts
			}
		}
		pos += length
	}

	if is_quoted {
		return {}, limit, start, .Unterminated_Expression
	}
	return Text_Span{offset = u16(start), length = u16(limit - start)}, limit, 0, .Ok
}

// message_parse parses and validates an MF2 message into a compact stack record.
// Refuses patterns past MESSAGE_PATTERN_MAX_BYTES, invalid UTF-8 or control
// characters, syntax errors, unknown functions, invalid options, duplicate
// declarations, missing catch-all * variant, duplicate variant keys, and depth
// or count overflows.
message_parse :: proc "contextless" (source: string) -> (parsed: Parsed_Message, status: Message_Status, error_offset: int) {
	if len(source) > MESSAGE_PATTERN_MAX_BYTES {
		return {}, .Pattern_Too_Long, MESSAGE_PATTERN_MAX_BYTES
	}
	parsed.source = source

	first_non_space := skip_structural_whitespace(source, 0)
	is_complex := false
	if first_non_space < len(source) {
		if source[first_non_space] == '.' {
			is_complex = true
		} else if first_non_space + 1 < len(source) && source[first_non_space] == '{' && source[first_non_space + 1] == '{' {
			is_complex = true
		}
	}

	if !is_complex {
		if bad_off, valid := validate_source_bytes(source, false); !valid {
			return {}, .Invalid_Utf8, bad_off
		}
		pattern_span, _, err_off, scan_status := scan_pattern_span(source, 0, len(source), false)
		if scan_status != .Ok {
			return {}, scan_status, err_off
		}
		parsed.kind = .Simple
		parsed.simple_pattern = pattern_span
		return parsed, .Ok, 0
	}

	if bad_off, valid := validate_source_bytes(source, true); !valid {
		return {}, .Invalid_Utf8, bad_off
	}

	pos := first_non_space
	limit := len(source)

	// Parse zero or more .input and .local declarations.
	for pos < limit {
		is_input := has_keyword_at(source, pos, ".input")
		is_local := has_keyword_at(source, pos, ".local")
		if !is_input && !is_local {
			break
		}
		if int(parsed.declaration_count) >= MESSAGE_MAX_DECLARATIONS {
			return {}, .Too_Many_Declarations, pos
		}

		decl: Message_Declaration
		decl_options: [MESSAGE_MAX_OPTIONS]Message_Option

		if is_input {
			decl.kind = .Input
			pos = skip_structural_whitespace(source, pos + len(".input"))
			if pos >= limit || source[pos] != '{' {
				return {}, .Syntax_Error, pos
			}
			expr, after_expr, expr_err, expr_status := parse_expression(source, pos, limit, decl_options[:])
			if expr_status != .Ok {
				return {}, expr_status, expr_err
			}
			if expr.operand_kind != .Variable {
				return {}, .Syntax_Error, pos
			}
			decl.variable_name = expr.operand
			decl.expression = expr
			decl.nesting_depth = 0
			pos = after_expr
		} else {
			decl.kind = .Local
			pos = skip_structural_whitespace(source, pos + len(".local"))
			if pos >= limit || source[pos] != '$' {
				return {}, .Syntax_Error, pos
			}
			var_span, after_var, var_ok := read_identifier(source, pos + 1, limit)
			if !var_ok {
				return {}, .Syntax_Error, pos
			}
			pos = skip_structural_whitespace(source, after_var)
			if pos >= limit || source[pos] != '=' {
				return {}, .Syntax_Error, pos
			}
			pos = skip_structural_whitespace(source, pos + 1)
			if pos >= limit || source[pos] != '{' {
				return {}, .Syntax_Error, pos
			}
			expr, after_expr, expr_err, expr_status := parse_expression(source, pos, limit, decl_options[:])
			if expr_status != .Ok {
				return {}, expr_status, expr_err
			}
			decl.variable_name = var_span
			decl.expression = expr
			depth: u8 = 1
			if expr.operand_kind == .Variable {
				operand_name := span_text(source, expr.operand)
				for earlier_index in 0 ..< int(parsed.declaration_count) {
					earlier := parsed.declarations[earlier_index]
					if span_text(source, earlier.variable_name) == operand_name {
						depth = earlier.nesting_depth + 1
						break
					}
				}
			}
			if int(depth) > MESSAGE_MAX_NESTING_DEPTH {
				return {}, .Nesting_Too_Deep, pos
			}
			decl.nesting_depth = depth
			pos = after_expr
		}

		// Refuse duplicate declarations of the same variable name.
		new_var_name := span_text(source, decl.variable_name)
		for earlier_index in 0 ..< int(parsed.declaration_count) {
			if span_text(source, parsed.declarations[earlier_index].variable_name) == new_var_name {
				return {}, .Duplicate_Declaration, int(decl.variable_name.offset)
			}
		}

		// Copy declaration options into the flat option pool.
		if int(parsed.declaration_option_count) + int(decl.expression.option_count) > MESSAGE_MAX_DECLARATION_OPTIONS {
			return {}, .Too_Many_Options, pos
		}
		decl.expression.option_start = parsed.declaration_option_count
		for opt_index in 0 ..< int(decl.expression.option_count) {
			parsed.declaration_options[parsed.declaration_option_count] = decl_options[opt_index]
			parsed.declaration_option_count += 1
		}

		parsed.declarations[parsed.declaration_count] = decl
		parsed.declaration_count += 1
		pos = skip_structural_whitespace(source, pos)
	}

	if pos >= limit {
		return {}, .Syntax_Error, pos
	}

	// Body is either a quoted pattern {{...}} or a .match statement.
	if pos + 1 < limit && source[pos] == '{' && source[pos + 1] == '{' {
		pattern_span, after_pattern, err_off, scan_status := scan_pattern_span(source, pos + 2, limit, true)
		if scan_status != .Ok {
			return {}, scan_status, err_off
		}
		pos = skip_structural_whitespace(source, after_pattern)
		if pos != limit {
			return {}, .Syntax_Error, pos
		}
		parsed.kind = .Complex_Pattern
		parsed.simple_pattern = pattern_span
		return parsed, .Ok, 0
	}

	if !has_keyword_at(source, pos, ".match") {
		return {}, .Syntax_Error, pos
	}
	parsed.kind = .Complex_Matcher
	pos = skip_structural_whitespace(source, pos + len(".match"))

	// Read selector variables ($var ...).
	for pos < limit && source[pos] == '$' {
		if int(parsed.selector_count) >= MESSAGE_MAX_SELECTORS {
			return {}, .Too_Many_Selectors, pos
		}
		sel_span, after_sel, sel_ok := read_identifier(source, pos + 1, limit)
		if !sel_ok {
			return {}, .Syntax_Error, pos
		}
		parsed.selectors[parsed.selector_count] = sel_span
		parsed.selector_count += 1
		pos = skip_structural_whitespace(source, after_sel)
	}
	if parsed.selector_count == 0 {
		return {}, .Syntax_Error, pos
	}

	// Read variants until end of message.
	has_catch_all := false
	for pos < limit {
		if int(parsed.variant_count) >= MESSAGE_MAX_VARIANTS {
			return {}, .Too_Many_Variants, pos
		}
		variant: Message_Variant
		key_count := 0
		all_wildcards := true

		for pos < limit {
			if pos + 1 < limit && source[pos] == '{' && source[pos + 1] == '{' {
				break
			}
			if key_count >= int(parsed.selector_count) {
				return {}, .Variant_Key_Mismatch, pos
			}
			key: Variant_Key
			switch source[pos] {
			case '*':
				if pos + 1 < limit && !is_structural_whitespace(source[pos + 1]) && source[pos + 1] != '{' {
					return {}, .Syntax_Error, pos
				}
				key.kind = .Wildcard
				key.text = Text_Span{offset = u16(pos), length = 1}
				pos += 1
			case '|':
				all_wildcards = false
				quoted_span, after_quoted, quoted_status := read_quoted_literal(source, pos, limit)
				if quoted_status != .Ok {
					return {}, quoted_status, pos
				}
				key.kind = .Quoted_Literal
				key.text = quoted_span
				pos = after_quoted
			case:
				all_wildcards = false
				lit_span, after_lit, lit_ok := read_unquoted_literal(source, pos, limit)
				if !lit_ok {
					return {}, .Syntax_Error, pos
				}
				key.kind = .Unquoted_Literal
				key.text = lit_span
				pos = after_lit
			}
			variant.keys[key_count] = key
			key_count += 1
			pos = skip_structural_whitespace(source, pos)
		}

		if key_count != int(parsed.selector_count) {
			return {}, .Variant_Key_Mismatch, pos
		}
		if pos + 1 >= limit || source[pos] != '{' || source[pos + 1] != '{' {
			return {}, .Syntax_Error, pos
		}

		// Check duplicate variant key tuples.
		for earlier_index in 0 ..< int(parsed.variant_count) {
			earlier := parsed.variants[earlier_index]
			same_tuple := true
			for sel_index in 0 ..< int(parsed.selector_count) {
				if !unescaped_literal_equal(
					source,
					earlier.keys[sel_index].kind,
					earlier.keys[sel_index].text,
					variant.keys[sel_index].kind,
					variant.keys[sel_index].text,
				) {
					same_tuple = false
					break
				}
			}
			if same_tuple {
				return {}, .Duplicate_Variant_Key, int(variant.keys[0].text.offset)
			}
		}

		pattern_span, after_pattern, err_off, scan_status := scan_pattern_span(source, pos + 2, limit, true)
		if scan_status != .Ok {
			return {}, scan_status, err_off
		}
		variant.pattern = pattern_span
		parsed.variants[parsed.variant_count] = variant
		parsed.variant_count += 1
		if all_wildcards {
			has_catch_all = true
		}
		pos = skip_structural_whitespace(source, after_pattern)
	}

	if !has_catch_all {
		return {}, .Missing_Fallback_Variant, len(source)
	}
	return parsed, .Ok, 0
}

// lookup_binding searches evaluated declarations first, then runtime arguments.
@(private = "file")
lookup_variable :: proc "contextless" (name: string, bindings: []Resolved_Binding, arguments: []Message_Argument) -> (binding: Resolved_Binding, found: bool) {
	for item in bindings {
		if item.name == name {
			return item, true
		}
	}
	for arg in arguments {
		if arg.name == name {
			if arg.value == nil {
				return {}, false
			}
			return Resolved_Binding {
				name                   = name,
				value                  = arg.value,
				function               = .None,
				select_mode            = .Plural,
				grouping_mode          = .Auto,
				minimum_integer_digits = 1,
			}, true
		}
	}
	return {}, false
}

// resolve_option_string reads a static or variable option value as a string.
@(private = "file")
resolve_option_string :: proc "contextless" (source: string, option: Message_Option, bindings: []Resolved_Binding, arguments: []Message_Argument, scratch: []u8) -> (text: string, status: Message_Status) {
	switch option.value_kind {
	case .Variable:
		var_name := span_text(source, option.value)
		found_binding, found := lookup_variable(var_name, bindings, arguments)
		if !found {
			return "", .Missing_Variable
		}
		switch v in found_binding.value {
		case Text:
			return string(v), .Ok
		case Integer, Unsigned:
			return "", .Invalid_Option
		}
		return "", .Invalid_Option
	case .Unquoted_Literal, .Quoted_Literal:
		cursor := Output_Cursor{destination = scratch}
		write_unescaped_literal(&cursor, source, option.value_kind, option.value)
		if cursor.overflow {
			return "", .Invalid_Option
		}
		return string(scratch[:cursor.position]), .Ok
	}
	return "", .Invalid_Option
}

// resolve_option_integer reads a static or variable option value as an integer.
@(private = "file")
resolve_option_integer :: proc "contextless" (source: string, option: Message_Option, bindings: []Resolved_Binding, arguments: []Message_Argument) -> (value: i64, status: Message_Status) {
	switch option.value_kind {
	case .Variable:
		var_name := span_text(source, option.value)
		found_binding, found := lookup_variable(var_name, bindings, arguments)
		if !found {
			return 0, .Missing_Variable
		}
		switch v in found_binding.value {
		case Integer:
			return i64(v), .Ok
		case Unsigned:
			if u64(v) > u64(max(i64)) {
				return 0, .Invalid_Option
			}
			return i64(v), .Ok
		case Text:
			return 0, .Invalid_Option
		}
		return 0, .Invalid_Option
	case .Unquoted_Literal, .Quoted_Literal:
		numeric, num_ok := literal_to_numeric_value(source, option.value_kind, option.value)
		if !num_ok {
			return 0, .Invalid_Option
		}
		switch v in numeric {
		case Integer:
			return i64(v), .Ok
		case Unsigned:
			if u64(v) > u64(max(i64)) {
				return 0, .Invalid_Option
			}
			return i64(v), .Ok
		case Text:
			return 0, .Invalid_Option
		}
		return 0, .Invalid_Option
	}
	return 0, .Invalid_Option
}

// resolve_expression computes the value, function, and formatting options of
// one MF2 expression against active bindings and runtime arguments.
@(private = "file")
resolve_expression :: proc "contextless" (
	source: string,
	expr: Message_Expression,
	options: []Message_Option,
	bindings: []Resolved_Binding,
	arguments: []Message_Argument,
	literal_scratch: []u8,
) -> (resolved: Resolved_Binding, status: Message_Status) {
	resolved.select_mode = .Plural
	resolved.grouping_mode = .Auto
	resolved.minimum_integer_digits = 1

	switch expr.operand_kind {
	case .Variable:
		var_name := span_text(source, expr.operand)
		found_binding, found := lookup_variable(var_name, bindings, arguments)
		if !found {
			return {}, .Missing_Variable
		}
		resolved = found_binding
	case .Unquoted_Literal, .Quoted_Literal:
		switch expr.function {
		case .Integer, .Number:
			numeric, num_ok := literal_to_numeric_value(source, expr.operand_kind, expr.operand)
			if !num_ok {
				return {}, .Type_Mismatch
			}
			resolved.value = numeric
		case .None, .String:
			cursor := Output_Cursor{destination = literal_scratch}
			write_unescaped_literal(&cursor, source, expr.operand_kind, expr.operand)
			if cursor.overflow {
				return {}, .Pattern_Too_Long
			}
			resolved.value = Text(string(literal_scratch[:cursor.position]))
		}
	}

	if expr.function != .None {
		resolved.function = expr.function
		resolved.select_mode = .Plural
		resolved.grouping_mode = .Auto
		resolved.minimum_integer_digits = 1
	}

	// Enforce function type compatibility.
	switch resolved.function {
	case .None, .String:
	case .Integer, .Number:
		switch v in resolved.value {
		case Integer, Unsigned:
		case Text:
			_ = v
			return {}, .Type_Mismatch
		}
	}

	// Resolve options attached to this expression.
	scratch: [MESSAGE_IDENTIFIER_MAX_BYTES]u8
	for opt in options {
		opt_name := span_text(source, opt.name)
		switch opt_name {
		case "select":
			opt_text, opt_status := resolve_option_string(source, opt, bindings, arguments, scratch[:])
			if opt_status != .Ok {
				return {}, opt_status
			}
			switch opt_text {
			case "plural":
				resolved.select_mode = .Plural
			case "exact":
				resolved.select_mode = .Exact
			case:
				return {}, .Invalid_Option
			}
		case "useGrouping":
			opt_text, opt_status := resolve_option_string(source, opt, bindings, arguments, scratch[:])
			if opt_status != .Ok {
				return {}, opt_status
			}
			switch opt_text {
			case "auto":
				resolved.grouping_mode = .Auto
			case "always":
				resolved.grouping_mode = .Always
			case "never":
				resolved.grouping_mode = .Never
			case:
				return {}, .Invalid_Option
			}
		case "minimumIntegerDigits":
			opt_int, opt_status := resolve_option_integer(source, opt, bindings, arguments)
			if opt_status != .Ok {
				return {}, opt_status
			}
			if opt_int < 1 || opt_int > MESSAGE_MIN_INTEGER_DIGITS_LIMIT {
				return {}, .Invalid_Option
			}
			resolved.minimum_integer_digits = u8(opt_int)
		case:
			return {}, .Invalid_Option
		}
	}

	return resolved, .Ok
}

// format_unsigned_digits writes an unsigned 64-bit integer into digits_out in
// most-significant-first order, padded to at least minimum_digits.
@(private = "file")
format_unsigned_digits :: proc "contextless" (value: u64, minimum_digits: int, digits_out: []u8) -> int {
	reversed: [32]u8
	count := 0
	remaining := value
	if remaining == 0 {
		reversed[0] = '0'
		count = 1
	} else {
		for remaining > 0 {
			reversed[count] = u8('0' + remaining % 10)
			count += 1
			remaining /= 10
		}
	}
	for count < minimum_digits && count < len(reversed) {
		reversed[count] = '0'
		count += 1
	}
	for index in 0 ..< count {
		digits_out[index] = reversed[count - 1 - index]
	}
	return count
}

// format_binding_value writes a resolved binding's value into cursor according
// to its function, locale, and options.
@(private = "file")
format_binding_value :: proc "contextless" (cursor: ^Output_Cursor, binding: Resolved_Binding, locale_tag: string) {
	switch v in binding.value {
	case Text:
		output_append_string(cursor, string(v))
	case Integer:
		negative := i64(v) < 0
		magnitude := integer_magnitude(i64(v))
		format_magnitude(cursor, negative, magnitude, binding, locale_tag)
	case Unsigned:
		format_magnitude(cursor, false, u64(v), binding, locale_tag)
	}
}

@(private = "file")
format_magnitude :: proc "contextless" (cursor: ^Output_Cursor, negative: bool, magnitude: u64, binding: Resolved_Binding, locale_tag: string) {
	digits: [32]u8
	min_digits := int(binding.minimum_integer_digits)
	if min_digits < 1 {
		min_digits = 1
	}
	digit_count := format_unsigned_digits(magnitude, min_digits, digits[:])
	if negative {
		output_append_byte(cursor, '-')
	}
	use_grouping := false
	if binding.function == .Integer || binding.function == .Number {
		switch binding.grouping_mode {
		case .Auto, .Always:
			use_grouping = digit_count >= 4
		case .Never:
			use_grouping = false
		}
	}
	separator := use_grouping ? locale_group_separator(locale_tag) : ""
	for index in 0 ..< digit_count {
		remaining_from_right := digit_count - index
		if use_grouping && index > 0 && remaining_from_right % 3 == 0 {
			output_append_string(cursor, separator)
		}
		output_append_byte(cursor, digits[index])
	}
}

// variant_key_match_rank scores one selector against one variant key:
// 0 = exact match, 1 = CLDR plural category match, 2 = wildcard *, -1 = no match.
@(private = "file")
variant_key_match_rank :: proc "contextless" (source: string, key: Variant_Key, selector: Resolved_Binding, locale_tag: string) -> int {
	if key.kind == .Wildcard {
		return 2
	}
	key_operand_kind: Operand_Kind = key.kind == .Quoted_Literal ? .Quoted_Literal : .Unquoted_Literal

	// Unescape key bytes into a small stack buffer for comparison.
	key_buffer: [MESSAGE_IDENTIFIER_MAX_BYTES]u8
	key_cursor := Output_Cursor{destination = key_buffer[:]}
	write_unescaped_literal(&key_cursor, source, key_operand_kind, key.text)
	if key_cursor.overflow {
		return -1
	}
	key_text := string(key_buffer[:key_cursor.position])

	switch v in selector.value {
	case Text:
		if key_text == string(v) {
			return 0
		}
		return -1
	case Integer:
		// Exact numeric key match has highest priority.
		if parsed_int, ok := parse_signed_decimal(key_text); ok && parsed_int == i64(v) {
			return 0
		}
		// Plural category match applies unless :string or select=exact.
		if selector.function != .String && selector.select_mode != .Exact {
			if key_category, cat_ok := plural_category_from_name(key_text); cat_ok {
				if plural_category_for_integer(locale_tag, i64(v)) == key_category {
					return 1
				}
			}
		}
		return -1
	case Unsigned:
		if parsed_uint, ok := parse_unsigned_decimal(key_text); ok && parsed_uint == u64(v) {
			return 0
		}
		if selector.function != .String && selector.select_mode != .Exact {
			if key_category, cat_ok := plural_category_from_name(key_text); cat_ok {
				if plural_category_for_unsigned(locale_tag, u64(v)) == key_category {
					return 1
				}
			}
		}
		return -1
	}
	return -1
}

// message_evaluate renders a previously parsed MF2 message under locale_tag
// with arguments into destination. Returns Buffer_Too_Small without claiming
// partial bytes when destination cannot hold the complete rendered text.
message_evaluate :: proc "contextless" (
	parsed: ^Parsed_Message,
	locale_tag: string,
	arguments: []Message_Argument,
	destination: []u8,
) -> (written: int, status: Message_Status) {
	if parsed == nil {
		return 0, .Syntax_Error
	}
	if language_tag.canonical_check(locale_tag) != .None {
		return 0, .Invalid_Locale
	}
	if len(arguments) > MESSAGE_MAX_ARGUMENTS {
		return 0, .Too_Many_Declarations
	}
	// Validate arguments upfront: no duplicate names and valid UTF-8 on text.
	for arg, index in arguments {
		if len(arg.name) == 0 || len(arg.name) > MESSAGE_IDENTIFIER_MAX_BYTES {
			return 0, .Syntax_Error
		}
		for earlier in 0 ..< index {
			if arguments[earlier].name == arg.name {
				return 0, .Duplicate_Declaration
			}
		}
		if text_val, is_text := arg.value.(Text); is_text {
			raw := transmute([]u8)string(text_val)
			if !text_encoding.text_valid(raw) {
				return 0, .Invalid_Utf8
			}
			for place := 0; place < len(raw); {
				character, length, _ := text_encoding.character_decode(raw, place)
				if length == 0 || text_encoding.character_hidden(character) {
					return 0, .Invalid_Utf8
				}
				place += length
			}
		}
	}

	source := parsed.source
	bindings: [MESSAGE_MAX_DECLARATIONS]Resolved_Binding
	binding_count := 0
	literal_storage: [MESSAGE_MAX_DECLARATIONS][MESSAGE_IDENTIFIER_MAX_BYTES]u8

	for decl_index in 0 ..< int(parsed.declaration_count) {
		decl := parsed.declarations[decl_index]
		opt_start := int(decl.expression.option_start)
		opt_end := opt_start + int(decl.expression.option_count)
		decl_opts := parsed.declaration_options[opt_start:opt_end]

		resolved, res_status := resolve_expression(
			source,
			decl.expression,
			decl_opts,
			bindings[:binding_count],
			arguments,
			literal_storage[decl_index][:],
		)
		if res_status != .Ok {
			return 0, res_status
		}
		resolved.name = span_text(source, decl.variable_name)
		bindings[binding_count] = resolved
		binding_count += 1
	}

	// Select winning pattern span.
	chosen_pattern: Text_Span
	switch parsed.kind {
	case .Simple, .Complex_Pattern:
		chosen_pattern = parsed.simple_pattern
	case .Complex_Matcher:
		selector_bindings: [MESSAGE_MAX_SELECTORS]Resolved_Binding
		sel_count := int(parsed.selector_count)
		for sel_index in 0 ..< sel_count {
			sel_name := span_text(source, parsed.selectors[sel_index])
			found_binding, found := lookup_variable(sel_name, bindings[:binding_count], arguments)
			if !found {
				return 0, .Missing_Variable
			}
			selector_bindings[sel_index] = found_binding
		}

		best_variant := -1
		best_ranks: [MESSAGE_MAX_SELECTORS]int
		for var_index in 0 ..< int(parsed.variant_count) {
			variant := parsed.variants[var_index]
			ranks: [MESSAGE_MAX_SELECTORS]int
			matched := true
			for sel_index in 0 ..< sel_count {
				rank := variant_key_match_rank(source, variant.keys[sel_index], selector_bindings[sel_index], locale_tag)
				if rank < 0 {
					matched = false
					break
				}
				ranks[sel_index] = rank
			}
			if !matched {
				continue
			}
			if best_variant < 0 {
				best_variant = var_index
				best_ranks = ranks
				continue
			}
			better := false
			for sel_index in 0 ..< sel_count {
				if ranks[sel_index] < best_ranks[sel_index] {
					better = true
					break
				}
				if ranks[sel_index] > best_ranks[sel_index] {
					break
				}
			}
			if better {
				best_variant = var_index
				best_ranks = ranks
			}
		}
		if best_variant < 0 {
			return 0, .Missing_Fallback_Variant
		}
		chosen_pattern = parsed.variants[best_variant].pattern
	}

	// Stream-render the chosen pattern into destination.
	cursor := Output_Cursor{destination = destination}
	pattern_start := int(chosen_pattern.offset)
	pattern_end := pattern_start + int(chosen_pattern.length)
	pos := pattern_start
	inline_options: [MESSAGE_MAX_OPTIONS]Message_Option
	inline_literal_scratch: [MESSAGE_PATTERN_MAX_BYTES]u8

	for pos < pattern_end {
		ch := source[pos]
		if ch == '\\' {
			output_append_byte(&cursor, source[pos + 1])
			pos += 2
			continue
		}
		if ch == '{' {
			expr, next_pos, _, expr_status := parse_expression(source, pos, pattern_end, inline_options[:])
			if expr_status != .Ok {
				return 0, expr_status
			}
			resolved, res_status := resolve_expression(
				source,
				expr,
				inline_options[:expr.option_count],
				bindings[:binding_count],
				arguments,
				inline_literal_scratch[:],
			)
			if res_status != .Ok {
				return 0, res_status
			}
			format_binding_value(&cursor, resolved, locale_tag)
			if cursor.overflow {
				return 0, .Buffer_Too_Small
			}
			pos = next_pos
			continue
		}
		output_append_byte(&cursor, ch)
		if cursor.overflow {
			return 0, .Buffer_Too_Small
		}
		pos += 1
	}

	if cursor.overflow {
		return 0, .Buffer_Too_Small
	}
	return cursor.position, .Ok
}

// message_format parses and evaluates an MF2 message in a single call.
message_format :: proc "contextless" (
	source: string,
	locale_tag: string,
	arguments: []Message_Argument,
	destination: []u8,
) -> (written: int, status: Message_Status) {
	parsed, parse_status, _ := message_parse(source)
	if parse_status != .Ok {
		return 0, parse_status
	}
	return message_evaluate(&parsed, locale_tag, arguments, destination)
}
