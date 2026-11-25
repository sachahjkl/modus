// Canonical, idempotent Lex source formatter (src/md/features/lex_tools.md).
//
// Freestanding, zero heap allocation, caller-owned output buffer. Uses the
// single Lex scanner in modus:console_language so token boundaries match
// lex_parser and the site highlighter, while preserving every comment, string
// literal (including escapes and `${...}` interpolations), hash literal, and
// numeric unit suffix.
package lex_tools

import "modus:console_language"
import "modus:lex_parser"

// Plan value: 2-space indentation matches the project's .lex files and docs/LEX.md.
DEFAULT_INDENT_SPACES :: 2

// Plan value: maximum spaces per indent level so a caller option cannot
// expand a small input into runaway indentation.
MAX_INDENT_SPACES :: 16

// Plan value: 100-byte single-line width target keeps typical records on one
// line while wrapping wide blocks cleanly in standard editors.
DEFAULT_MAX_LINE_WIDTH :: 100

// Format property: matches lex_parser.DECLARATION_PARSE_DEPTH_LIMIT so any
// valid declaration formats without scope stack overflow.
FORMAT_DEPTH_LIMIT :: lex_parser.DECLARATION_PARSE_DEPTH_LIMIT

// Closed set of formatter refusal outcomes.
Format_Error :: enum u8 {
	None                   = 0,
	Buffer_Too_Small       = 1,
	Text_Too_Long          = 2,
	Text_Without_End_Quote = 3,
	Unknown_Token          = 4,
	Unmatched_Close        = 5,
	Unclosed_Delimiter     = 6,
	Nesting_Too_Deep       = 7,
}

// Optional formatting parameters. Zero fields select defaults.
Format_Options :: struct {
	indent_spaces:  int,
	max_line_width: int,
}

// format_error_name gives a short plain-English description of a Format_Error.
format_error_name :: proc "contextless" (err: Format_Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Buffer_Too_Small:
		return "output buffer is too small"
	case .Text_Too_Long:
		return "source exceeds the declaration size limit"
	case .Text_Without_End_Quote:
		return "string literal has no closing quote"
	case .Unknown_Token:
		return "source contains an unrecognized character"
	case .Unmatched_Close:
		return "closing delimiter has no matching opener"
	case .Unclosed_Delimiter:
		return "opening delimiter has no matching closer"
	case .Nesting_Too_Deep:
		return "nesting depth exceeds the formatter limit"
	}
	return "no error"
}

// lex_format formats `source` into `out` using default canonical options.
// On any error, returns (0, err). Strictly idempotent on valid Lex input.
lex_format :: proc "contextless" (source: string, out: []u8) -> (written: int, err: Format_Error) {
	return lex_format_with_options(source, out, {})
}

// lex_format_with_options formats `source` into `out` with explicit options.
lex_format_with_options :: proc "contextless" (
	source: string,
	out: []u8,
	options: Format_Options,
) -> (written: int, err: Format_Error) {
	if len(source) > lex_parser.DECLARATION_TEXT_BYTES_MOST {
		return 0, .Text_Too_Long
	}
	indent_spaces := options.indent_spaces > 0 ? clamp(options.indent_spaces, 1, MAX_INDENT_SPACES) : DEFAULT_INDENT_SPACES
	max_line_width := options.max_line_width > 0 ? options.max_line_width : DEFAULT_MAX_LINE_WIDTH

	writer := Fmt_Writer{
		out = out,
	}
	scopes: [FORMAT_DEPTH_LIMIT]Fmt_Scope
	scope_depth := 0

	pos := 0
	has_emitted := false
	at_line_start := true
	force_newline := false
	just_opened_block := false
	prev_code := Fmt_Item{kind = .End}
	prev_was_unary := false

	for {
		item, next_pos := fmt_next_item(source, pos)
		if item.kind == .End {
			break
		}
		if item.kind == .Error_Quote {
			return 0, .Text_Without_End_Quote
		}
		if item.kind == .Error_Unknown {
			return 0, .Unknown_Token
		}

		// Peek ahead one item so inline trailing comments after `{`, `[`, or `,`
		// stay on the same line before the forced newline.
		peek_item, _ := fmt_next_item(source, next_pos)

		if item.kind == .Comment {
			comment_text := source[item.start:item.end]
			if !has_emitted {
				fmt_write_string(&writer, comment_text)
				has_emitted = true
				at_line_start = false
				force_newline = true
			} else if item.newlines_before == 0 && !force_newline && !at_line_start {
				fmt_write_byte(&writer, ' ')
				fmt_write_string(&writer, comment_text)
				at_line_start = false
				force_newline = true
			} else {
				if item.newlines_before >= 2 && !just_opened_block {
					fmt_write_byte(&writer, '\n')
				}
				fmt_write_byte(&writer, '\n')
				indent := fmt_indent_level(scopes[:scope_depth])
				fmt_write_indent(&writer, indent * indent_spaces)
				fmt_write_string(&writer, comment_text)
				at_line_start = false
				force_newline = true
			}
			just_opened_block = false
			if writer.overflow {
				return 0, .Buffer_Too_Small
			}
			pos = next_pos
			continue
		}

		item_text := source[item.start:item.end]

		// Pop `let` binding scopes before closing delimiters or matching `in`.
		if item.kind == .Name && item_text == "in" {
			if scope_depth > 0 && scopes[scope_depth - 1].kind == .Let_Bindings {
				scope_depth -= 1
			}
		}

		is_close := item.kind == .Close_Brace || item.kind == .Close_Bracket || item.kind == .Close_Paren
		closing_multiline := false
		if is_close {
			for scope_depth > 0 && scopes[scope_depth - 1].kind == .Let_Bindings {
				scope_depth -= 1
			}
			expected_scope := fmt_scope_for_close(item.kind)
			if scope_depth == 0 || scopes[scope_depth - 1].kind != expected_scope {
				return 0, .Unmatched_Close
			}
			closing_multiline = scopes[scope_depth - 1].multiline
			scope_depth -= 1
		}

		// Decide whether this code item begins a new line.
		starts_new_line := false
		if !has_emitted {
			starts_new_line = false
		} else if force_newline {
			starts_new_line = true
		} else if closing_multiline {
			starts_new_line = true
		} else if item.newlines_before > 0 {
			// Collapse empty blocks `{ \n }` / `[ \n ]` / `( \n )` onto one line.
			if is_close && (prev_code.kind == .Open_Brace || prev_code.kind == .Open_Bracket || prev_code.kind == .Open_Paren) {
				starts_new_line = false
			} else {
				starts_new_line = true
			}
		}

		if starts_new_line {
			if item.newlines_before >= 2 && !just_opened_block && !is_close {
				fmt_write_byte(&writer, '\n')
			}
			fmt_write_byte(&writer, '\n')
			indent := fmt_indent_level(scopes[:scope_depth])
			if item.kind == .Operator && item_text == "|>" {
				indent += 1
			}
			fmt_write_indent(&writer, indent * indent_spaces)
			at_line_start = true
			force_newline = false
		} else if has_emitted && !at_line_start {
			prev_text := prev_code.kind != .End ? source[prev_code.start:prev_code.end] : ""
			if fmt_needs_space(prev_code, prev_text, prev_was_unary, item, item_text) {
				fmt_write_byte(&writer, ' ')
			}
		}

		// Write the token itself.
		fmt_write_string(&writer, item_text)
		has_emitted = true
		at_line_start = false
		just_opened_block = false

		// Track unary operator state for the next token (`!` or unary `-`).
		if item.kind == .Operator && item_text == "!" {
			prev_was_unary = true
		} else if item.kind == .Operator && item_text == "-" {
			prev_text := prev_code.kind != .End ? source[prev_code.start:prev_code.end] : ""
			prev_was_unary = !fmt_is_expr_ender(prev_code, prev_text)
		} else {
			prev_was_unary = false
		}

		// Update scope stack on openers and `let`.
		switch item.kind {
		case .Open_Brace:
			is_empty, is_multiline, _, inspect_err := fmt_inspect_block(source, next_pos, .Close_Brace, max_line_width)
			if inspect_err != .None {
				return 0, inspect_err
			}
			if scope_depth >= FORMAT_DEPTH_LIMIT {
				return 0, .Nesting_Too_Deep
			}
			scopes[scope_depth] = {kind = .Brace, multiline = !is_empty && is_multiline}
			scope_depth += 1
			if !is_empty && is_multiline {
				just_opened_block = true
				if !(peek_item.kind == .Comment && peek_item.newlines_before == 0) {
					force_newline = true
				}
			}
		case .Open_Bracket:
			is_empty, is_multiline, _, inspect_err := fmt_inspect_block(source, next_pos, .Close_Bracket, max_line_width)
			if inspect_err != .None {
				return 0, inspect_err
			}
			if scope_depth >= FORMAT_DEPTH_LIMIT {
				return 0, .Nesting_Too_Deep
			}
			scopes[scope_depth] = {kind = .Bracket, multiline = !is_empty && is_multiline}
			scope_depth += 1
			if !is_empty && is_multiline {
				just_opened_block = true
				if !(peek_item.kind == .Comment && peek_item.newlines_before == 0) {
					force_newline = true
				}
			}
		case .Open_Paren:
			is_empty, _, has_break, inspect_err := fmt_inspect_block(source, next_pos, .Close_Paren, max_line_width)
			if inspect_err != .None {
				return 0, inspect_err
			}
			if scope_depth >= FORMAT_DEPTH_LIMIT {
				return 0, .Nesting_Too_Deep
			}
			// Parentheses preserve explicit newlines or comments but do not auto-wrap
			// on width so function signatures and conditions stay predictable.
			paren_multi := !is_empty && has_break
			scopes[scope_depth] = {kind = .Paren, multiline = paren_multi}
			scope_depth += 1
			if paren_multi {
				just_opened_block = true
			}
		case .Name:
			if item_text == "let" {
				if scope_depth >= FORMAT_DEPTH_LIMIT {
					return 0, .Nesting_Too_Deep
				}
				scopes[scope_depth] = {kind = .Let_Bindings, multiline = true}
				scope_depth += 1
			}
		case .Comma:
			// Inside a multi-line `{ ... }` or `[ ... ]` block, put each element on its own line.
			if scope_depth > 0 {
				top := scopes[scope_depth - 1]
				if (top.kind == .Brace || top.kind == .Bracket) && top.multiline {
					if !(peek_item.kind == .Comment && peek_item.newlines_before == 0) {
						force_newline = true
					}
				}
			}
		case .End, .Comment, .Number, .Text, .Hash, .Member, .Operator,
		     .Close_Brace, .Close_Bracket, .Close_Paren, .Colon,
		     .Error_Quote, .Error_Unknown:
		}

		prev_code = item
		if writer.overflow {
			return 0, .Buffer_Too_Small
		}
		pos = next_pos
	}

	// Trailing unclosed `let` scopes are allowed (console `let x = 1` form),
	// whereas unclosed `{`, `[`, or `(` are refused.
	for scope_depth > 0 && scopes[scope_depth - 1].kind == .Let_Bindings {
		scope_depth -= 1
	}
	if scope_depth > 0 {
		return 0, .Unclosed_Delimiter
	}

	if has_emitted {
		fmt_write_byte(&writer, '\n')
		if writer.overflow {
			return 0, .Buffer_Too_Small
		}
	}
	return writer.pos, .None
}

// ---- Formatter internals.

@(private = "file")
Fmt_Item_Kind :: enum u8 {
	End           = 0,
	Comment       = 1,
	Name          = 2,
	Number        = 3,
	Text          = 4,
	Hash          = 5,
	Member        = 6,
	Operator      = 7,
	Open_Brace    = 8,
	Close_Brace   = 9,
	Open_Bracket  = 10,
	Close_Bracket = 11,
	Open_Paren    = 12,
	Close_Paren   = 13,
	Comma         = 14,
	Colon         = 15,
	Error_Quote   = 16,
	Error_Unknown = 17,
}

@(private = "file")
Fmt_Item :: struct {
	kind:            Fmt_Item_Kind,
	start:           int,
	end:             int,
	newlines_before: int,
}

@(private = "file")
Fmt_Scope_Kind :: enum u8 {
	Brace        = 0,
	Bracket      = 1,
	Paren        = 2,
	Let_Bindings = 3,
}

@(private = "file")
Fmt_Scope :: struct {
	kind:      Fmt_Scope_Kind,
	multiline: bool,
}

@(private = "file")
Fmt_Writer :: struct {
	out:      []u8,
	pos:      int,
	overflow: bool,
}

@(private = "file")
fmt_write_byte :: proc "contextless" (w: ^Fmt_Writer, b: u8) {
	if w.overflow || w.pos >= len(w.out) {
		w.overflow = true
		return
	}
	w.out[w.pos] = b
	w.pos += 1
}

@(private = "file")
fmt_write_string :: proc "contextless" (w: ^Fmt_Writer, s: string) {
	if w.overflow || len(s) > len(w.out) - w.pos {
		w.overflow = true
		return
	}
	copy(w.out[w.pos:], s)
	w.pos += len(s)
}

@(private = "file")
fmt_write_indent :: proc "contextless" (w: ^Fmt_Writer, spaces: int) {
	if w.overflow || spaces <= 0 {
		return
	}
	if spaces > len(w.out) - w.pos {
		w.overflow = true
		return
	}
	for i in 0 ..< spaces {
		w.out[w.pos + i] = ' '
	}
	w.pos += spaces
}

@(private = "file")
fmt_indent_level :: proc "contextless" (scopes: []Fmt_Scope) -> int {
	level := 0
	for s in scopes {
		if s.multiline {
			level += 1
		}
	}
	return level
}

@(private = "file")
fmt_scope_for_close :: proc "contextless" (kind: Fmt_Item_Kind) -> Fmt_Scope_Kind {
	switch kind {
	case .Close_Brace:
		return .Brace
	case .Close_Bracket:
		return .Bracket
	case .Close_Paren:
		return .Paren
	case .End, .Comment, .Name, .Number, .Text, .Hash, .Member, .Operator,
	     .Open_Brace, .Open_Bracket, .Open_Paren, .Comma, .Colon,
	     .Error_Quote, .Error_Unknown:
		return .Paren
	}
	return .Paren
}

// fmt_next_item scans the next comment or Lex token starting at `pos`,
// counting line feeds skipped before it and coalescing adjacent `<=`, `>=`, `!=`.
@(private = "file")
fmt_next_item :: proc "contextless" (source: string, pos: int) -> (item: Fmt_Item, next_pos: int) {
	p := clamp(pos, 0, len(source))
	nl := 0
	for p < len(source) {
		ch := source[p]
		if ch == ' ' || ch == '\t' || ch == '\r' {
			p += 1
		} else if ch == '\n' {
			nl += 1
			p += 1
		} else {
			break
		}
	}
	if p >= len(source) {
		return {kind = .End, start = p, end = p, newlines_before = nl}, p
	}
	if console_language.comment_starts(source, p) {
		cend := console_language.comment_end(source, p)
		trimmed := cend
		for trimmed > p && (source[trimmed - 1] == ' ' || source[trimmed - 1] == '\t' || source[trimmed - 1] == '\r') {
			trimmed -= 1
		}
		return {kind = .Comment, start = p, end = trimmed, newlines_before = nl}, cend
	}

	tok := console_language.token_next(source, p, multiline = true)
	switch tok.kind {
	case .None:
		return {kind = .End, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Text_Unfinished:
		return {kind = .Error_Quote, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Unknown:
		return {kind = .Error_Unknown, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Name:
		return {kind = .Name, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Number:
		return {kind = .Number, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Text:
		return {kind = .Text, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Hash:
		return {kind = .Hash, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Member:
		return {kind = .Member, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Pipe, .Function_Arrow, .Arrow:
		return {kind = .Operator, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	case .Operator:
		if tok.end - tok.start == 1 {
			ch := source[tok.start]
			// Coalesce 2-byte comparison operators that console_language emits as two 1-byte tokens.
			if (ch == '<' || ch == '>' || ch == '!') && tok.end < len(source) && source[tok.end] == '=' {
				return {kind = .Operator, start = tok.start, end = tok.end + 1, newlines_before = nl}, tok.end + 1
			}
			switch ch {
			case '{':
				return {kind = .Open_Brace, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case '}':
				return {kind = .Close_Brace, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case '[':
				return {kind = .Open_Bracket, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case ']':
				return {kind = .Close_Bracket, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case '(':
				return {kind = .Open_Paren, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case ')':
				return {kind = .Close_Paren, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case ',':
				return {kind = .Comma, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			case ':':
				return {kind = .Colon, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
			}
		}
		return {kind = .Operator, start = tok.start, end = tok.end, newlines_before = nl}, tok.end
	}
	return {kind = .Error_Unknown, start = p, end = p + 1, newlines_before = nl}, p + 1
}

// fmt_inspect_block scans ahead from just after `{`, `[`, or `(` to its
// matching closer to decide emptiness and multi-line layout deterministically.
// `has_break` reports a newline or comment at top level of this block (`depth == 1`
// or immediately before its matching closer), so a nested multi-line record inside
// a single-line call `f("a", plan { ... })` does not break the outer `)` on pass 2.
@(private = "file")
fmt_inspect_block :: proc "contextless" (
	source: string,
	open_end: int,
	close_kind: Fmt_Item_Kind,
	max_width: int,
) -> (is_empty: bool, is_multiline: bool, has_break: bool, err: Format_Error) {
	p := open_end
	depth := 1
	item_count := 0
	has_comment := false
	has_newline := false
	top_break := false
	// Width estimate depends strictly on token lengths and canonical spacing
	// (never on input whitespace), preserving idempotency across passes.
	est_width := 2

	for {
		it, next_p := fmt_next_item(source, p)
		switch it.kind {
		case .End:
			return false, false, false, .Unclosed_Delimiter
		case .Error_Quote:
			return false, false, false, .Text_Without_End_Quote
		case .Error_Unknown:
			return false, false, false, .Unknown_Token
		case .Comment:
			has_comment = true
			has_newline = true
			if depth == 1 {
				top_break = true
			}
			item_count += 1
		case .Open_Brace, .Open_Bracket, .Open_Paren:
			if it.newlines_before > 0 {
				has_newline = true
				if depth == 1 {
					top_break = true
				}
			}
			depth += 1
			if depth > FORMAT_DEPTH_LIMIT {
				return false, false, false, .Nesting_Too_Deep
			}
			item_count += 1
			est_width += 2
		case .Close_Brace, .Close_Bracket, .Close_Paren:
			if it.newlines_before > 0 {
				has_newline = true
			}
			depth -= 1
			if depth == 0 {
				if it.kind != close_kind {
					return false, false, false, .Unmatched_Close
				}
				if item_count == 0 {
					return true, false, false, .None
				}
				if it.newlines_before > 0 {
					top_break = true
				}
				explicit_break := has_comment || has_newline
				return false, explicit_break || est_width > max_width, top_break, .None
			}
			item_count += 1
			est_width += 2
		case .Name, .Number, .Text, .Hash, .Member, .Operator, .Comma, .Colon:
			if it.newlines_before > 0 {
				has_newline = true
				if depth == 1 {
					top_break = true
				}
			}
			item_count += 1
			est_width += (it.end - it.start) + 1
		}
		p = next_p
	}
}

// fmt_is_spacing_keyword reports whether a `.Name` token is a structural
// keyword that takes spaces around it rather than acting as a value atom.
@(private = "file")
fmt_is_spacing_keyword :: proc "contextless" (text: string) -> bool {
	switch text {
	case "let", "in", "with", "if", "then", "else", "match", "for":
		return true
	}
	return false
}

// fmt_is_expr_ender reports whether a preceding token can end a value
// expression (so a following `-` is binary subtraction rather than unary negation).
@(private = "file")
fmt_is_expr_ender :: proc "contextless" (item: Fmt_Item, text: string) -> bool {
	switch item.kind {
	case .Number, .Text, .Hash, .Member, .Close_Paren, .Close_Bracket, .Close_Brace:
		return true
	case .Name:
		return !fmt_is_spacing_keyword(text)
	case .End, .Comment, .Operator, .Open_Brace, .Open_Bracket, .Open_Paren,
	     .Comma, .Colon, .Error_Quote, .Error_Unknown:
		return false
	}
	return false
}

// fmt_needs_space decides canonical single-line spacing between two adjacent
// code tokens on the same line.
@(private = "file")
fmt_needs_space :: proc "contextless" (
	prev: Fmt_Item,
	prev_text: string,
	prev_was_unary: bool,
	curr: Fmt_Item,
	curr_text: string,
) -> bool {
	if curr.kind == .Comma || curr.kind == .Colon {
		return false
	}
	if curr.kind == .Close_Paren || curr.kind == .Close_Bracket {
		return false
	}
	if curr.kind == .Close_Brace {
		return prev.kind != .Open_Brace
	}
	if prev.kind == .Open_Paren || prev.kind == .Open_Bracket {
		return false
	}
	if prev.kind == .Open_Brace {
		return curr.kind != .Close_Brace
	}
	if prev_was_unary {
		return false
	}
	if curr.kind == .Open_Paren {
		if prev.kind == .Name && !fmt_is_spacing_keyword(prev_text) {
			return false
		}
		if prev.kind == .Close_Paren || prev.kind == .Close_Bracket {
			return false
		}
		return true
	}
	if curr.kind == .Open_Bracket {
		if prev.kind == .Name && !fmt_is_spacing_keyword(prev_text) {
			return false
		}
		if prev.kind == .Close_Paren || prev.kind == .Close_Bracket {
			return false
		}
		return true
	}
	if curr.kind == .Member {
		if prev.kind == .Close_Paren || prev.kind == .Close_Bracket || prev.kind == .Close_Brace {
			return false
		}
		if prev.kind == .Name && !fmt_is_spacing_keyword(prev_text) {
			return false
		}
		return true
	}
	if curr.kind == .Operator && curr_text == "." {
		return false
	}
	if prev.kind == .Operator && prev_text == "." {
		return false
	}
	return true
}
