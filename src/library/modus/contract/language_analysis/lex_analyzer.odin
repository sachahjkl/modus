// Freestanding zero-allocation Lex analyzer producing MODLAEF1 snapshots
// directly into a caller-supplied flat buffer (src/md/features/language_analysis.md).
//
// Self-contained inside modus:contract/language_analysis so contract packages
// import no support packages.
package language_analysis

// Inline capacity bounds sized for interactive Lex project and plan files.
LEX_ANALYZE_DIAGNOSTICS_LIMIT :: 64
LEX_ANALYZE_TOKENS_LIMIT :: 512
LEX_ANALYZE_COMPLETIONS_LIMIT :: 64
LEX_ANALYZE_DEFINITIONS_LIMIT :: 64
LEX_ANALYZE_HOVERS_LIMIT :: 64
LEX_ANALYZE_BINDINGS_LIMIT :: 64
LEX_ANALYZE_DELIM_DEPTH_LIMIT :: 64
LEX_ANALYZE_STRING_POOL_BYTES :: 8192

// Caller-owned scratch workspace so lex_analyze_into_snapshot allocates zero
// heap memory and keeps stack frames small for freestanding modules.
Lex_Analyzer_Workspace :: struct {
	diagnostics:      [LEX_ANALYZE_DIAGNOSTICS_LIMIT]Diagnostic_Row,
	diagnostic_count: int,
	tokens:           [LEX_ANALYZE_TOKENS_LIMIT]Semantic_Token_Row,
	token_count:      int,
	completions:      [LEX_ANALYZE_COMPLETIONS_LIMIT]Completion_Row,
	completion_count: int,
	definitions:      [LEX_ANALYZE_DEFINITIONS_LIMIT]Definition_Span,
	definition_count: int,
	hovers:           [LEX_ANALYZE_HOVERS_LIMIT]Hover_Entry,
	hover_count:      int,
	bindings:         [LEX_ANALYZE_BINDINGS_LIMIT]Lex_Binding_Record,
	binding_count:    int,
	delim_stack:      [LEX_ANALYZE_DELIM_DEPTH_LIMIT]Lex_Delimiter_Frame,
	delim_depth:      int,
	strings:          [LEX_ANALYZE_STRING_POOL_BYTES]u8,
	string_used:      int,
}

@(private = "file")
Lex_Binding_Record :: struct {
	name_start: u32,
	name_end:   u32,
	pool_off:   u32,
	pool_len:   u32,
}

@(private = "file")
Lex_Delimiter_Frame :: struct {
	open_char: u8,
	offset:    u32,
	line:      u32,
	column:    u32,
}

@(private = "file")
pool_append :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, text: string) -> (off: u32, length: u32, ok: bool) {
	if len(text) == 0 {
		return u32(ws.string_used), 0, true
	}
	if len(text) > len(ws.strings) - ws.string_used {
		return 0, 0, false
	}
	off = u32(ws.string_used)
	length = u32(len(text))
	for index in 0 ..< len(text) {
		ws.strings[ws.string_used + index] = text[index]
	}
	ws.string_used += len(text)
	return off, length, true
}

@(private = "file")
push_token :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, start, length: u32, kind: Semantic_Token_Kind) -> bool {
	if ws.token_count >= len(ws.tokens) {
		return false
	}
	ws.tokens[ws.token_count] = {
		start_offset = start,
		length       = length,
		kind_word    = u32(kind),
	}
	ws.token_count += 1
	return true
}

@(private = "file")
push_diagnostic :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, start, end, line, column: u32, severity: Analysis_Diagnostic_Severity, message: string) -> bool {
	if ws.diagnostic_count >= len(ws.diagnostics) {
		return false
	}
	off, count, ok := pool_append(ws, message)
	if !ok {
		return false
	}
	ws.diagnostics[ws.diagnostic_count] = {
		start_offset   = start,
		end_offset     = end,
		line           = line,
		column         = column,
		severity_word  = u32(severity),
		message_offset = off,
		message_bytes  = count,
	}
	ws.diagnostic_count += 1
	return true
}

@(private = "file")
push_completion :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, kind: Completion_Kind, label, detail: string) -> bool {
	if ws.completion_count >= len(ws.completions) {
		return false
	}
	l_off, l_len, l_ok := pool_append(ws, label)
	d_off, d_len, d_ok := pool_append(ws, detail)
	if !l_ok || !d_ok {
		return false
	}
	ws.completions[ws.completion_count] = {
		kind_word     = u32(kind),
		label_offset  = l_off,
		label_bytes   = l_len,
		detail_offset = d_off,
		detail_bytes  = d_len,
	}
	ws.completion_count += 1
	return true
}

@(private = "file")
push_hover :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, start, end: u32, sig, summary: string) -> bool {
	if ws.hover_count >= len(ws.hovers) {
		return false
	}
	s_off, s_len, s_ok := pool_append(ws, sig)
	d_off, d_len, d_ok := pool_append(ws, summary)
	if !s_ok || !d_ok {
		return false
	}
	ws.hovers[ws.hover_count] = {
		start_offset     = start,
		end_offset       = end,
		signature_offset = s_off,
		signature_bytes  = s_len,
		summary_offset   = d_off,
		summary_bytes    = d_len,
	}
	ws.hover_count += 1
	return true
}

@(private = "file")
is_ident_start :: proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

@(private = "file")
is_ident_part :: proc "contextless" (ch: u8) -> bool {
	return is_ident_start(ch) || (ch >= '0' && ch <= '9')
}

@(private = "file")
is_hex_lower :: proc "contextless" (ch: u8) -> bool {
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
}

@(private = "file")
is_lex_keyword :: proc "contextless" (word: string) -> bool {
	switch word {
	case "let", "in", "with", "project", "plan", "recipe", "store", "here", "true", "false", "match", "if", "then", "else":
		return true
	}
	return false
}

@(private = "file")
is_lex_unit :: proc "contextless" (word: string) -> bool {
	switch word {
	case "B", "KiB", "MiB", "GiB", "TiB", "ns", "us", "ms", "s":
		return true
	}
	return false
}

@(private = "file")
builtin_hover_info :: proc "contextless" (word: string) -> (sig, summary: string, ok: bool) {
	switch word {
	case "here":
		return "here() -> Tree_Ref", "Canonical MODTREE2 BLAKE3 hash of the project source tree", true
	case "recipe":
		return "recipe(builder, arguments) -> Recipe_Ref", "Content-addressed build recipe declaration", true
	case "store":
		return "store(name, rights...) -> Store_Ref", "Least-privilege store grant declaration", true
	case "project":
		return "project { source, inputs, outputs, console }", "Declarative Lex project specification", true
	case "plan":
		return "plan { values, locks }", "Declarative system plan specification", true
	}
	return "", "", false
}

@(private = "file")
binding_find :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, source: string, word: string) -> (record: Lex_Binding_Record, found: bool) {
	for index := ws.binding_count - 1; index >= 0; index -= 1 {
		item := ws.bindings[index]
		if source[item.name_start:item.name_end] == word {
			return item, true
		}
	}
	return {}, false
}

@(private = "file")
next_non_space_byte :: proc "contextless" (source: string, from: int) -> (ch: u8, at: int, ok: bool) {
	pos := from
	for pos < len(source) {
		c := source[pos]
		if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
			return c, pos, true
		}
		pos += 1
	}
	return 0, pos, false
}

// lex_analyze_into_snapshot analyzes a Lex document and writes a complete
// MODLAEF1 snapshot into out using caller-owned workspace memory.
lex_analyze_into_snapshot :: proc "contextless" (ws: ^Lex_Analyzer_Workspace, source: string, generation: u64, out: []u8) -> (written: int, refusal: Analysis_Refusal) {
	if ws == nil {
		return 0, .Bad_Request
	}
	ws.diagnostic_count = 0
	ws.token_count = 0
	ws.completion_count = 0
	ws.definition_count = 0
	ws.hover_count = 0
	ws.binding_count = 0
	ws.delim_depth = 0
	ws.string_used = 0

	// Seed static Lex keyword completions so empty or partial buffers still offer completions.
	_ = push_completion(ws, .Keyword, "let", "Bind local pure values")
	_ = push_completion(ws, .Keyword, "project", "Declare a project specification")
	_ = push_completion(ws, .Keyword, "plan", "Declare a system plan")
	_ = push_completion(ws, .Command, "recipe", "Build recipe(builder, args)")
	_ = push_completion(ws, .Command, "here", "Current source MODTREE2 hash")
	_ = push_completion(ws, .Unit, "MiB", "Mebibyte size unit")

	in_let_header := false
	let_brace_depth := 0
	prev_was_number := false
	pos := 0
	line := u32(1)
	column := u32(1)

	for pos < len(source) {
		ch := source[pos]
		if ch == ' ' || ch == '\t' || ch == '\r' {
			pos += 1
			column += 1
			continue
		}
		if ch == '\n' {
			pos += 1
			line += 1
			column = 1
			prev_was_number = false
			continue
		}

		// Line comment: // ...
		if ch == '/' && pos + 1 < len(source) && source[pos + 1] == '/' {
			start := pos
			for pos < len(source) && source[pos] != '\n' {
				pos += 1
				column += 1
			}
			if !push_token(ws, u32(start), u32(pos - start), .Comment) {
				return 0, .Capacity_Exceeded
			}
			prev_was_number = false
			continue
		}

		// String literal: "..."
		if ch == '"' {
			start := pos
			start_line := line
			start_col := column
			pos += 1
			column += 1
			closed := false
			for pos < len(source) {
				c := source[pos]
				if c == '\\' && pos + 1 < len(source) {
					pos += 2
					column += 2
					continue
				}
				if c == '\n' {
					break
				}
				pos += 1
				column += 1
				if c == '"' {
					closed = true
					break
				}
			}
			if !push_token(ws, u32(start), u32(pos - start), .Text_Literal) {
				return 0, .Capacity_Exceeded
			}
			if !closed {
				if !push_diagnostic(ws, u32(start), u32(pos), start_line, start_col, .Error, "unterminated text literal") {
					return 0, .Capacity_Exceeded
				}
			}
			prev_was_number = false
			continue
		}

		// Dotted enum member: .identifier (when not immediately after identifier/number/closing bracket).
		if ch == '.' && pos + 1 < len(source) && is_ident_start(source[pos + 1]) {
			prev_is_expr := pos > 0 && (is_ident_part(source[pos - 1]) || source[pos - 1] == ')' || source[pos - 1] == ']')
			if !prev_is_expr {
				start := pos
				pos += 1
				column += 1
				for pos < len(source) && is_ident_part(source[pos]) {
					pos += 1
					column += 1
				}
				if !push_token(ws, u32(start), u32(pos - start), .Enum_Member) {
					return 0, .Capacity_Exceeded
				}
				prev_was_number = false
				continue
			}
		}

		// Number literal: digits (with optional decimal fraction).
		if ch >= '0' && ch <= '9' {
			start := pos
			for pos < len(source) && (source[pos] >= '0' && source[pos] <= '9') {
				pos += 1
				column += 1
			}
			if pos + 1 < len(source) && source[pos] == '.' && source[pos + 1] >= '0' && source[pos + 1] <= '9' {
				pos += 1
				column += 1
				for pos < len(source) && (source[pos] >= '0' && source[pos] <= '9') {
					pos += 1
					column += 1
				}
			}
			if !push_token(ws, u32(start), u32(pos - start), .Number) {
				return 0, .Capacity_Exceeded
			}
			prev_was_number = true
			continue
		}

		// Identifier, keyword, unit, or blake3:<64-hex> hash literal.
		if is_ident_start(ch) {
			start := pos
			start_line := line
			start_col := column
			for pos < len(source) && is_ident_part(source[pos]) {
				pos += 1
				column += 1
			}
			word := source[start:pos]

			// Check for blake3:<hex> hash literal.
			if word == "blake3" && pos < len(source) && source[pos] == ':' {
				pos += 1
				column += 1
				hex_start := pos
				for pos < len(source) && is_ident_part(source[pos]) {
					pos += 1
					column += 1
				}
				hex_text := source[hex_start:pos]
				valid_hex := len(hex_text) == 64
				if valid_hex {
					for i in 0 ..< len(hex_text) {
						if !is_hex_lower(hex_text[i]) {
							valid_hex = false
							break
						}
					}
				}
				if !push_token(ws, u32(start), u32(pos - start), .Hash_Literal) {
					return 0, .Capacity_Exceeded
				}
				if !valid_hex {
					if !push_diagnostic(ws, u32(start), u32(pos), start_line, start_col, .Error, "blake3 literal requires 64 lowercase hexadecimal digits") {
						return 0, .Capacity_Exceeded
					}
				}
				prev_was_number = false
				continue
			}

			if prev_was_number && is_lex_unit(word) {
				if !push_token(ws, u32(start), u32(pos - start), .Unit) {
					return 0, .Capacity_Exceeded
				}
				prev_was_number = false
				continue
			}
			prev_was_number = false

			if is_lex_keyword(word) {
				if word == "let" {
					in_let_header = true
					let_brace_depth = ws.delim_depth
				} else if word == "in" && in_let_header && ws.delim_depth == let_brace_depth {
					in_let_header = false
				}
				if !push_token(ws, u32(start), u32(pos - start), .Keyword) {
					return 0, .Capacity_Exceeded
				}
				if sig, summary, has_hover := builtin_hover_info(word); has_hover && ws.hover_count < len(ws.hovers) {
					_ = push_hover(ws, u32(start), u32(pos), sig, summary)
				}
				continue
			}

			// Detect a `let` binding declaration: identifier at let_brace_depth followed by `=`.
			next_ch, next_at, has_next := next_non_space_byte(source, pos)
			is_eq := has_next && next_ch == '=' && !(next_at + 1 < len(source) && (source[next_at + 1] == '=' || source[next_at + 1] == '>'))
			if in_let_header && ws.delim_depth == let_brace_depth && is_eq {
				if !push_token(ws, u32(start), u32(pos - start), .Binding) {
					return 0, .Capacity_Exceeded
				}
				if ws.binding_count < len(ws.bindings) {
					p_off, p_len, p_ok := pool_append(ws, word)
					if !p_ok {
						return 0, .Capacity_Exceeded
					}
					ws.bindings[ws.binding_count] = {
						name_start = u32(start),
						name_end   = u32(pos),
						pool_off   = p_off,
						pool_len   = p_len,
					}
					ws.binding_count += 1
					_ = push_completion(ws, .Binding, word, "Local let binding")
					_ = push_hover(ws, u32(start), u32(pos), word, "Local let binding")
				}
				continue
			}

			// Identifier reference: resolve against recorded let bindings for definition & hover.
			if !push_token(ws, u32(start), u32(pos - start), .Identifier) {
				return 0, .Capacity_Exceeded
			}
			if bound, found := binding_find(ws, source, word); found {
				if ws.definition_count < len(ws.definitions) {
					ws.definitions[ws.definition_count] = {
						use_start    = u32(start),
						use_end      = u32(pos),
						target_start = bound.name_start,
						target_end   = bound.name_end,
						name_offset  = bound.pool_off,
						name_bytes   = bound.pool_len,
					}
					ws.definition_count += 1
				}
				_ = push_hover(ws, u32(start), u32(pos), word, "Reference to local let binding")
			}
			continue
		}

		prev_was_number = false

		// Two-character operators: |>, =>, ??, ==, !=, <=, >=
		if pos + 1 < len(source) {
			next := source[pos + 1]
			if (ch == '|' && next == '>') || (ch == '=' && next == '>') || (ch == '?' && next == '?') ||
				(ch == '=' && next == '=') || (ch == '!' && next == '=') || (ch == '<' && next == '=') || (ch == '>' && next == '=') {
				if !push_token(ws, u32(pos), 2, .Operator) {
					return 0, .Capacity_Exceeded
				}
				pos += 2
				column += 2
				continue
			}
		}

		// Opening delimiters tracked for balance diagnostics.
		if ch == '{' || ch == '[' || ch == '(' {
			if ws.delim_depth >= len(ws.delim_stack) {
				return 0, .Capacity_Exceeded
			}
			ws.delim_stack[ws.delim_depth] = {
				open_char = ch,
				offset    = u32(pos),
				line      = line,
				column    = column,
			}
			ws.delim_depth += 1
			if !push_token(ws, u32(pos), 1, .Punctuation) {
				return 0, .Capacity_Exceeded
			}
			pos += 1
			column += 1
			continue
		}

		// Closing delimiters checked against top of stack.
		if ch == '}' || ch == ']' || ch == ')' {
			expected_open: u8 = ch == '}' ? '{' : (ch == ']' ? '[' : '(')
			if ws.delim_depth == 0 || ws.delim_stack[ws.delim_depth - 1].open_char != expected_open {
				if !push_diagnostic(ws, u32(pos), u32(pos + 1), line, column, .Error, "unmatched closing delimiter") {
					return 0, .Capacity_Exceeded
				}
			} else {
				ws.delim_depth -= 1
			}
			if !push_token(ws, u32(pos), 1, .Punctuation) {
				return 0, .Capacity_Exceeded
			}
			pos += 1
			column += 1
			continue
		}

		// Single-character operators and punctuation.
		if ch == '=' || ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '<' || ch == '>' {
			if !push_token(ws, u32(pos), 1, .Operator) {
				return 0, .Capacity_Exceeded
			}
		} else {
			if !push_token(ws, u32(pos), 1, .Punctuation) {
				return 0, .Capacity_Exceeded
			}
		}
		pos += 1
		column += 1
	}

	// Report any unclosed opening delimiters.
	for index := ws.delim_depth - 1; index >= 0; index -= 1 {
		frame := ws.delim_stack[index]
		if !push_diagnostic(ws, frame.offset, frame.offset + 1, frame.line, frame.column, .Error, "unclosed delimiter") {
			return 0, .Capacity_Exceeded
		}
	}

	tables := Snapshot_Tables{
		document_generation = generation,
		diagnostics         = ws.diagnostics[:ws.diagnostic_count],
		tokens              = ws.tokens[:ws.token_count],
		completions         = ws.completions[:ws.completion_count],
		definitions         = ws.definitions[:ws.definition_count],
		hovers              = ws.hovers[:ws.hover_count],
		strings             = ws.strings[:ws.string_used],
	}
	return snapshot_encode(tables, out)
}
