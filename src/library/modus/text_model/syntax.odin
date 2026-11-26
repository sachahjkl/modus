package text_model

// Lightweight, zero-allocation syntax highlighting for the editor and the
// store explorer inspector (src/md/features/editor.md).
//
// Multi-line state (block comments, nested block comments in Odin, Odin raw
// backtick strings, and wrapped-row string continuations) is precomputed into
// one Syntax_Carry byte per display row when the text changes — never in a
// frame. During a frame, syntax_highlight_row scans only the visible display
// row (at most 80 cells), keeping frame cost O(visible cells).

import "modus:graphics"

// Supported languages for syntax highlighting, chosen from the object name.
Syntax_Language :: enum u8 {
	Plain = 0,
	C     = 1,
	Lex   = 2,
	Odin  = 3,
}

// Per-row multi-line carry state recorded at the start of each display row.
//   bits 0..5: block comment nesting depth (0..63; 0/1 for C and Lex, nested in Odin)
//   bit  6:    inside an Odin multi-line raw backtick string
//   bit  7:    wrapped display row continuing a double-quoted string on the same line
Syntax_Carry :: u8

SYNTAX_CARRY_DEPTH_MASK :: Syntax_Carry(0x3F)
SYNTAX_CARRY_DEPTH_MAX  :: Syntax_Carry(0x3F)
SYNTAX_CARRY_BACKTICK   :: Syntax_Carry(0x40)
SYNTAX_CARRY_STRING     :: Syntax_Carry(0x80)

// Caller-supplied growth callback for the per-row carry array, matching Row_Grow.
Syntax_Grow :: #type proc "contextless" (user_data: rawptr, current: []Syntax_Carry, minimum_rows: int) -> (grown: []Syntax_Carry, ok: bool)

// Precomputed per-row syntax carry state parallel to Layout.rows.
// Inline capacity matches ROW_CAPACITY (32 KiB inline tier) and grows onto
// external_carries via the caller's arena callback past that threshold.
Syntax_States :: struct {
	carries:          []Syntax_Carry,
	inline_carries:   [ROW_CAPACITY]Syntax_Carry,
	external_carries: []Syntax_Carry,
	grow:             Syntax_Grow,
	grow_data:        rawptr,
	row_count:        int,
	tier_moves:       u64,
}

// syntax_init_buffer attaches a caller-supplied carry buffer and growth callback.
syntax_init_buffer :: proc "contextless" (states: ^Syntax_States, buffer: []Syntax_Carry, grow: Syntax_Grow = nil, grow_data: rawptr = nil) {
	states.external_carries = buffer
	states.carries = len(buffer) > 0 ? buffer : states.inline_carries[:]
	states.grow = grow
	states.grow_data = grow_data
	states.row_count = 0
	states.tier_moves = 0
}

@(private = "file")
syntax_storage :: proc "contextless" (states: ^Syntax_States) -> []Syntax_Carry {
	if len(states.external_carries) > 0 {
		return states.external_carries
	}
	return states.inline_carries[:]
}

@(private = "file")
syntax_ensure_capacity :: proc "contextless" (states: ^Syntax_States, needed: int, used: int) -> bool {
	if needed < 0 {
		return false
	}
	storage := syntax_storage(states)
	if needed <= len(storage) {
		states.carries = storage
		return true
	}
	if states.grow == nil {
		return false
	}
	grown, ok := states.grow(states.grow_data, storage, needed)
	if !ok || len(grown) < needed {
		return false
	}
	same_base := len(storage) > 0 && raw_data(grown) == raw_data(storage)
	if !same_base && used > 0 {
		copy(grown[:used], storage[:used])
	}
	states.external_carries = grown
	states.carries = grown
	states.tier_moves += 1
	return true
}

@(private = "file")
has_suffix_bytes :: proc "contextless" (s, suffix: string) -> bool {
	if len(s) < len(suffix) {
		return false
	}
	base := len(s) - len(suffix)
	for i in 0 ..< len(suffix) {
		if s[base + i] != suffix[i] {
			return false
		}
	}
	return true
}

// syntax_language_of_path selects the syntax language from an object path or name.
syntax_language_of_path :: proc "contextless" (path: string) -> Syntax_Language {
	if has_suffix_bytes(path, ".c") || has_suffix_bytes(path, ".h") {
		return .C
	}
	if has_suffix_bytes(path, ".lex") || has_suffix_bytes(path, ".recipe") {
		return .Lex
	}
	if has_suffix_bytes(path, ".odin") {
		return .Odin
	}
	return .Plain
}

// syntax_row_carry returns the precomputed carry at the start of display row `row`.
syntax_row_carry :: proc "contextless" (states: ^Syntax_States, row: int) -> Syntax_Carry {
	if states == nil || row < 0 || row >= states.row_count || row >= len(states.carries) {
		return 0
	}
	return states.carries[row]
}

@(private = "file")
is_ascii_alpha :: proc "contextless" (b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}

@(private = "file")
is_ascii_digit :: proc "contextless" (b: u8) -> bool {
	return b >= '0' && b <= '9'
}

@(private = "file")
is_ident_continue :: proc "contextless" (b: u8) -> bool {
	return is_ascii_alpha(b) || is_ascii_digit(b)
}

@(private = "file")
is_hex_digit :: proc "contextless" (b: u8) -> bool {
	return is_ascii_digit(b) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

@(private = "file")
bytes_equal_word :: proc "contextless" (slice: []u8, word: string) -> bool {
	if len(slice) != len(word) {
		return false
	}
	for i in 0 ..< len(word) {
		if slice[i] != word[i] {
			return false
		}
	}
	return true
}

@(private = "file")
word_in_list :: proc "contextless" (slice: []u8, words: []string) -> bool {
	for w in words {
		if bytes_equal_word(slice, w) {
			return true
		}
	}
	return false
}

@(private = "file")
c_keywords := [?]string {
	"auto", "break", "case", "const", "continue", "default", "do", "else",
	"enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
	"return", "sizeof", "static", "struct", "switch", "typedef", "union",
	"volatile", "while", "_Static_assert", "_Alignof", "_Alignas",
}

@(private = "file")
c_types := [?]string {
	"void", "char", "short", "int", "long", "float", "double", "signed",
	"unsigned", "bool", "_Bool", "size_t", "ssize_t", "ptrdiff_t",
	"intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t",
	"uint8_t", "uint16_t", "uint32_t", "uint64_t",
}

@(private = "file")
c_literals := [?]string{"NULL", "true", "false"}

@(private = "file")
lex_keywords := [?]string {
	"let", "in", "with", "if", "then", "else", "and", "or", "not",
	"project", "plan", "recipe", "module", "store", "here", "catalog",
	"where", "columns", "sort", "filter", "map", "first", "count",
}

@(private = "file")
lex_literals := [?]string{"true", "false", "B", "KiB", "MiB", "GiB", "ns", "us", "ms", "s"}

@(private = "file")
odin_keywords := [?]string {
	"package", "import", "proc", "struct", "enum", "union", "bit_set",
	"map", "distinct", "if", "else", "when", "for", "in", "not_in",
	"switch", "case", "return", "defer", "break", "continue", "fallthrough",
	"or_return", "or_else", "or_break", "or_continue", "cast", "transmute",
	"auto_cast", "context", "using", "foreign", "where", "do", "dynamic",
	"matrix", "bit_field", "asm",
}

@(private = "file")
odin_types := [?]string {
	"bool", "b8", "b16", "b32", "b64",
	"i8", "i16", "i32", "i64", "i128", "int",
	"u8", "u16", "u32", "u64", "u128", "uint", "uintptr",
	"f16", "f32", "f64", "rune", "byte", "string", "cstring",
	"rawptr", "any", "typeid",
}

@(private = "file")
odin_literals := [?]string{"nil", "true", "false"}

@(private = "file")
classify_identifier :: proc "contextless" (lang: Syntax_Language, word: []u8, next_non_space: u8) -> graphics.Code_Class {
	switch lang {
	case .Plain:
		return .None
	case .C:
		if word_in_list(word, c_keywords[:]) {
			return .Keyword
		}
		if word_in_list(word, c_types[:]) {
			return .Type
		}
		if word_in_list(word, c_literals[:]) {
			return .Literal
		}
		if next_non_space == '(' {
			return .Name
		}
		return .None
	case .Lex:
		if word_in_list(word, lex_keywords[:]) {
			return .Keyword
		}
		if word_in_list(word, lex_literals[:]) {
			return .Literal
		}
		if next_non_space == '(' {
			return .Name
		}
		return .None
	case .Odin:
		if word_in_list(word, odin_keywords[:]) {
			return .Keyword
		}
		if word_in_list(word, odin_types[:]) {
			return .Type
		}
		if word_in_list(word, odin_literals[:]) {
			return .Literal
		}
		if next_non_space == '(' {
			return .Name
		}
		return .None
	}
	return .None
}

@(private = "file")
fill_classes :: proc "contextless" (out: []graphics.Code_Class, from, to: int, class: graphics.Code_Class) {
	if len(out) == 0 {
		return
	}
	hi := min(to, len(out))
	for i := from; i < hi; i += 1 {
		out[i] = class
	}
}

@(private = "file")
peek_next_non_space :: proc "contextless" (bytes: []u8, from: int) -> u8 {
	for i := from; i < len(bytes); i += 1 {
		if bytes[i] != ' ' && bytes[i] != '\t' {
			return bytes[i]
		}
	}
	return 0
}

// syntax_scan_segment scans bytes[0..len(bytes)] in language `lang` starting
// from `start_carry`. When `out` is non-empty it writes one graphics.Code_Class
// per byte. Returns the carry at the end of the segment (before any newline).
@(private = "file")
syntax_scan_segment :: proc "contextless" (
	lang: Syntax_Language,
	bytes: []u8,
	start_carry: Syntax_Carry,
	is_line_start: bool,
	out: []graphics.Code_Class,
) -> Syntax_Carry {
	n := len(bytes)
	if len(out) > 0 {
		fill_classes(out, 0, n, .None)
	}
	if lang == .Plain || n == 0 {
		return 0
	}

	depth := start_carry & SYNTAX_CARRY_DEPTH_MASK
	in_backtick := (start_carry & SYNTAX_CARRY_BACKTICK) != 0
	in_string := (start_carry & SYNTAX_CARRY_STRING) != 0
	i := 0

	// C preprocessor directive on a fresh logical line outside block comments.
	if lang == .C && is_line_start && depth == 0 && !in_string {
		p := 0
		for p < n && (bytes[p] == ' ' || bytes[p] == '\t') {
			p += 1
		}
		if p < n && bytes[p] == '#' {
			// Highlight `#directive` up to any inline comment.
			j := p + 1
			for j < n {
				if j + 1 < n && bytes[j] == '/' && (bytes[j + 1] == '/' || bytes[j + 1] == '*') {
					break
				}
				j += 1
			}
			fill_classes(out, p, j, .Directive)
			i = j
		}
	}

	for i < n {
		// 1. Inside an Odin multi-line raw backtick string.
		if in_backtick {
			start := i
			for i < n {
				b := bytes[i]
				i += 1
				if b == '`' {
					in_backtick = false
					break
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 2. Inside a wrapped double-quoted string continuation on the same line.
		if in_string {
			start := i
			for i < n {
				b := bytes[i]
				if b == '\\' && i + 1 < n {
					i += 2
					continue
				}
				i += 1
				if b == '"' {
					in_string = false
					break
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 3. Inside a block comment (`/* ... */`, nested in Odin).
		if depth > 0 {
			start := i
			for i < n && depth > 0 {
				if i + 1 < n && bytes[i] == '/' && bytes[i + 1] == '*' && lang == .Odin {
					if depth < SYNTAX_CARRY_DEPTH_MAX {
						depth += 1
					}
					i += 2
					continue
				}
				if i + 1 < n && bytes[i] == '*' && bytes[i + 1] == '/' {
					depth -= 1
					i += 2
					continue
				}
				i += 1
			}
			fill_classes(out, start, i, .Comment)
			continue
		}

		b := bytes[i]
		if b == ' ' || b == '\t' {
			i += 1
			continue
		}

		// 4. Line comment `// ...` to end of segment.
		if b == '/' && i + 1 < n && bytes[i + 1] == '/' {
			fill_classes(out, i, n, .Comment)
			i = n
			break
		}

		// 5. Block comment start `/*`.
		if b == '/' && i + 1 < n && bytes[i + 1] == '*' {
			start := i
			depth = 1
			i += 2
			for i < n && depth > 0 {
				if i + 1 < n && bytes[i] == '/' && bytes[i + 1] == '*' && lang == .Odin {
					if depth < SYNTAX_CARRY_DEPTH_MAX {
						depth += 1
					}
					i += 2
					continue
				}
				if i + 1 < n && bytes[i] == '*' && bytes[i + 1] == '/' {
					depth -= 1
					i += 2
					continue
				}
				i += 1
			}
			fill_classes(out, start, i, .Comment)
			continue
		}

		// 6. Odin raw backtick string.
		if lang == .Odin && b == '`' {
			start := i
			i += 1
			in_backtick = true
			for i < n {
				ch := bytes[i]
				i += 1
				if ch == '`' {
					in_backtick = false
					break
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 7. Double-quoted string literal `"..."`.
		if b == '"' {
			start := i
			i += 1
			in_string = true
			for i < n {
				ch := bytes[i]
				if ch == '\\' && i + 1 < n {
					i += 2
					continue
				}
				i += 1
				if ch == '"' {
					in_string = false
					break
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 8. Single-quoted character literal (C and Odin).
		if (lang == .C || lang == .Odin) && b == '\'' {
			start := i
			i += 1
			for i < n {
				ch := bytes[i]
				if ch == '\\' && i + 1 < n {
					i += 2
					continue
				}
				i += 1
				if ch == '\'' {
					break
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 9. Odin directives `#...` and attributes `@(...)` / `@name`.
		if lang == .Odin && (b == '#' || b == '@') {
			start := i
			i += 1
			if b == '@' && i < n && bytes[i] == '(' {
				i += 1
				for i < n && bytes[i] != ')' {
					i += 1
				}
				if i < n && bytes[i] == ')' {
					i += 1
				}
			} else {
				for i < n && is_ident_continue(bytes[i]) {
					i += 1
				}
			}
			fill_classes(out, start, i, .Directive)
			continue
		}

		// 10. Dotted enum choices (`.dark`, `.vector`, `.read`) in Lex and Odin
		//     when not preceded by an identifier or closing delimiter.
		if (lang == .Lex || lang == .Odin) && b == '.' && i + 1 < n && is_ascii_alpha(bytes[i + 1]) {
			prev := i > 0 ? bytes[i - 1] : 0
			if !is_ident_continue(prev) && prev != ')' && prev != ']' && prev != '}' {
				start := i
				i += 1
				for i < n && is_ident_continue(bytes[i]) {
					i += 1
				}
				fill_classes(out, start, i, .Literal)
				continue
			}
		}

		// 11. Numeric literals (`0x...`, `0b...`, decimals, underscores, floats).
		if is_ascii_digit(b) {
			start := i
			i += 1
			if b == '0' && i < n && (bytes[i] == 'x' || bytes[i] == 'X' || bytes[i] == 'b' || bytes[i] == 'B' || bytes[i] == 'o' || bytes[i] == 'O') {
				i += 1
				for i < n && (is_hex_digit(bytes[i]) || bytes[i] == '_') {
					i += 1
				}
			} else {
				for i < n && (is_ascii_digit(bytes[i]) || bytes[i] == '_' || (bytes[i] == '.' && i + 1 < n && is_ascii_digit(bytes[i + 1]))) {
					i += 1
				}
				if lang == .C {
					for i < n && (bytes[i] == 'u' || bytes[i] == 'U' || bytes[i] == 'l' || bytes[i] == 'L' || bytes[i] == 'f' || bytes[i] == 'F') {
						i += 1
					}
				}
			}
			fill_classes(out, start, i, .Literal)
			continue
		}

		// 12. Identifiers, keywords, types, function names, and Lex `blake3:` / `sha256:` hashes.
		if is_ascii_alpha(b) {
			start := i
			i += 1
			for i < n && is_ident_continue(bytes[i]) {
				i += 1
			}
			word := bytes[start:i]
			if lang == .Lex && i < n && bytes[i] == ':' && (bytes_equal_word(word, "blake3") || bytes_equal_word(word, "sha256")) {
				i += 1
				for i < n && is_hex_digit(bytes[i]) {
					i += 1
				}
				fill_classes(out, start, i, .Literal)
				continue
			}
			next_ns := peek_next_non_space(bytes, i)
			cls := classify_identifier(lang, word, next_ns)
			fill_classes(out, start, i, cls)
			continue
		}

		// 13. Operators and punctuation.
		if b >= 0x21 && b <= 0x7E {
			fill_classes(out, i, i + 1, .Punctuation)
		}
		i += 1
	}

	carry := depth & SYNTAX_CARRY_DEPTH_MASK
	if in_backtick {
		carry |= SYNTAX_CARRY_BACKTICK
	}
	if in_string {
		carry |= SYNTAX_CARRY_STRING
	}
	return carry
}

// syntax_highlight_row classifies each byte of one visible display row into
// graphics.Code_Class using its precomputed start carry. Returns the carry
// after the row.
syntax_highlight_row :: proc "contextless" (
	lang: Syntax_Language,
	row_bytes: []u8,
	start_carry: Syntax_Carry,
	is_line_start: bool,
	out_classes: []graphics.Code_Class,
) -> Syntax_Carry {
	return syntax_scan_segment(lang, row_bytes, start_carry, is_line_start, out_classes)
}

// syntax_compute computes the starting Syntax_Carry for every display row in
// `layout` after a text or layout change (never called during a frame).
syntax_compute :: proc "contextless" (states: ^Syntax_States, layout: ^Layout, text: ^Text, lang: Syntax_Language) -> bool {
	if states == nil || layout == nil || text == nil {
		return false
	}
	count := layout.row_count
	if count <= 0 {
		states.row_count = 0
		return true
	}
	if lang == .Plain {
		states.row_count = 0
		return true
	}
	if !syntax_ensure_capacity(states, count, 0) {
		states.row_count = 0
		return false
	}
	states.row_count = count
	carry := Syntax_Carry(0)
	// Row scan buffer: at most 4 * COLUMNS_LIMIT bytes for the widest allowed row,
	// scanned in bounded slices so stack usage stays tiny (512 bytes).
	chunk: [512]u8
	for row in 0 ..< count {
		first_of_line := row_first_of_line(layout, row)
		if first_of_line {
			// Single-line double-quoted strings do not cross a newline boundary.
			carry &~= SYNTAX_CARRY_STRING
		}
		states.carries[row] = carry
		start := int(layout.rows[row].start)
		end := row_bytes_end(layout, text, row)
		pos := start
		seg_line_start := first_of_line
		for pos < end {
			take := min(end - pos, len(chunk))
			for k in 0 ..< take {
				chunk[k] = byte_at(text, pos + k)
			}
			carry = syntax_scan_segment(lang, chunk[:take], carry, seg_line_start, nil)
			pos += take
			seg_line_start = false
		}
	}
	return true
}
