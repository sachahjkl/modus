// Static Lex linter (src/md/features/lex_tools.md).
//
// Freestanding, zero heap allocation, caller-owned diagnostic buffer. Runs a
// streaming token pass (malformed tokens, empty input, empty pipe targets,
// redundant parentheses) and an AST pass via modus:lex_parser (duplicate record
// fields, parse errors, empty records/lists, shadowed and unused `let` bindings).
package lex_tools

import "modus:console_language"
import "modus:lex_parser"

// Inline capacity: fast-path AST buffer for lex_lint on small declarations
// (~12.5 KiB on the stack). Larger files use lex_lint_with_storage with
// caller-allocated Tree_Storage (the next tier).
LINT_INLINE_NODE_CAPACITY :: 512

// Inline capacity: integer constant side table paired with LINT_INLINE_NODE_CAPACITY.
LINT_INLINE_INT_CONST_CAPACITY :: 64

// Format/safety bound: matches lex_parser.DECLARATION_PARSE_DEPTH_LIMIT so
// any parsed AST walks without stack overflow.
LINT_WALK_DEPTH_LIMIT :: lex_parser.DECLARATION_PARSE_DEPTH_LIMIT

// Plan value: maximum simultaneously active lexical bindings tracked in nested
// `let`, function, comprehension, and `match` scopes during one AST walk.
LINT_SCOPE_BINDING_CAPACITY :: 256

// Closed set of static lint diagnostic kinds.
Lint_Kind :: enum u8 {
	None                   = 0,
	Malformed_Token        = 1,
	Parse_Error            = 2,
	Duplicate_Record_Field = 3,
	Shadowed_Binding       = 4,
	Unused_Binding         = 5,
	Redundant_Parentheses  = 6,
	Empty_Record           = 7,
	Empty_List             = 8,
	Empty_Pipe_Target      = 9,
	Empty_Expression       = 10,
}

// Closed set of lint diagnostic severities.
Lint_Severity :: enum u8 {
	Error   = 0,
	Warning = 1,
}

// One static diagnostic at a source position.
Lint_Diagnostic :: struct {
	kind:     Lint_Kind,
	severity: Lint_Severity,
	place:    lex_parser.Place,
	end:      u32,
	name:     string,
}

// lint_kind_name gives the stable machine-readable name of a Lint_Kind.
lint_kind_name :: proc "contextless" (kind: Lint_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Malformed_Token:
		return "malformed_token"
	case .Parse_Error:
		return "parse_error"
	case .Duplicate_Record_Field:
		return "duplicate_record_field"
	case .Shadowed_Binding:
		return "shadowed_binding"
	case .Unused_Binding:
		return "unused_binding"
	case .Redundant_Parentheses:
		return "redundant_parentheses"
	case .Empty_Record:
		return "empty_record"
	case .Empty_List:
		return "empty_list"
	case .Empty_Pipe_Target:
		return "empty_pipe_target"
	case .Empty_Expression:
		return "empty_expression"
	}
	return "none"
}

// lint_severity_name gives the stable label of a Lint_Severity.
lint_severity_name :: proc "contextless" (severity: Lint_Severity) -> string {
	switch severity {
	case .Error:
		return "error"
	case .Warning:
		return "warning"
	}
	return "error"
}

// lint_diagnostic_message writes a plain-English diagnostic sentence into `buf`
// and returns the written slice (docs/WRITING.md).
lint_diagnostic_message :: proc "contextless" (diag: Lint_Diagnostic, buf: []u8) -> string {
	w := Msg_Writer{out = buf}
	switch diag.kind {
	case .None:
		return ""
	case .Malformed_Token:
		msg_write(&w, "malformed token")
		if len(diag.name) > 0 {
			msg_write(&w, ": ")
			msg_write(&w, diag.name)
		}
	case .Parse_Error:
		msg_write(&w, "syntax does not match the Lex grammar")
	case .Duplicate_Record_Field:
		msg_write(&w, "record defines field ")
		msg_write_quoted(&w, diag.name)
		msg_write(&w, " more than once")
	case .Shadowed_Binding:
		msg_write(&w, "let binding ")
		msg_write_quoted(&w, diag.name)
		msg_write(&w, " shadows an outer binding")
	case .Unused_Binding:
		msg_write(&w, "let binding ")
		msg_write_quoted(&w, diag.name)
		msg_write(&w, " is never used")
	case .Redundant_Parentheses:
		msg_write(&w, "parentheses around this expression are redundant")
	case .Empty_Record:
		msg_write(&w, "record literal has no fields")
	case .Empty_List:
		msg_write(&w, "list literal has no items")
	case .Empty_Pipe_Target:
		msg_write(&w, "pipe operator has no callable target")
	case .Empty_Expression:
		msg_write(&w, "source contains no Lex expression")
	}
	return string(buf[:w.pos])
}

// lex_lint checks `source` using an inline stack AST workspace for small files
// and writes diagnostics into `out`. For large declarations (> 512 AST nodes),
// call lex_lint_with_storage with caller-owned Tree_Storage.
lex_lint :: proc "contextless" (source: string, out: []Lint_Diagnostic) -> (count: int, truncated: bool) {
	nodes: [LINT_INLINE_NODE_CAPACITY]lex_parser.Ast_Node
	extra: [LINT_INLINE_NODE_CAPACITY]lex_parser.Node_Index
	scratch: [LINT_INLINE_NODE_CAPACITY]lex_parser.Node_Index
	ints: [LINT_INLINE_INT_CONST_CAPACITY]i64
	storage := lex_parser.Tree_Storage{
		nodes            = nodes[:],
		extra_children   = extra[:],
		scratch_children = scratch[:],
		int_consts       = ints[:],
	}
	return lex_lint_with_storage(source, storage, out)
}

// lex_lint_with_storage runs token-level and AST-level lint passes using
// caller-supplied `storage`, writing diagnostics into `out`.
lex_lint_with_storage :: proc "contextless" (
	source: string,
	storage: lex_parser.Tree_Storage,
	out: []Lint_Diagnostic,
) -> (count: int, truncated: bool) {
	sink := Lint_Sink{out = out}

	// Pass 1: streaming token scan (works regardless of AST buffer size).
	token_count := lint_scan_tokens(source, &sink)
	if token_count == 0 {
		lint_emit(&sink, {
			kind     = .Empty_Expression,
			severity = .Warning,
			place    = {line = 1, column = 1, offset = 0},
			end      = u32(min(len(source), lex_parser.DECLARATION_TEXT_BYTES_MOST)),
		})
		return sink.count, sink.truncated
	}

	// Pass 2: full AST parse and semantic walk.
	tree: lex_parser.Syntax_Tree
	lex_parser.parse_declaration(source, storage, &tree)

	if tree.refusal.refusal != .None {
		lint_report_parse_refusal(source, tree.refusal, &sink)
		return sink.count, sink.truncated
	}

	if tree.root != lex_parser.NO_NODE {
		walker := Lint_Walker{
			tree = &tree,
			sink = &sink,
		}
		lint_walk_node(&walker, tree.root, 0)
	}

	return sink.count, sink.truncated
}

// ---- Diagnostic sink and message writer.

@(private = "file")
Lint_Sink :: struct {
	out:       []Lint_Diagnostic,
	count:     int,
	truncated: bool,
}

@(private = "file")
lint_emit :: proc "contextless" (sink: ^Lint_Sink, diag: Lint_Diagnostic) {
	if sink.count >= len(sink.out) {
		sink.truncated = true
		return
	}
	sink.out[sink.count] = diag
	sink.count += 1
}

@(private = "file")
lint_has_at_offset :: proc "contextless" (sink: ^Lint_Sink, kind: Lint_Kind, offset: u32) -> bool {
	for i in 0 ..< sink.count {
		if sink.out[i].kind == kind && sink.out[i].place.offset == offset {
			return true
		}
	}
	return false
}

@(private = "file")
Msg_Writer :: struct {
	out: []u8,
	pos: int,
}

@(private = "file")
msg_write :: proc "contextless" (w: ^Msg_Writer, text: string) {
	avail := len(w.out) - w.pos
	if avail <= 0 || len(text) == 0 {
		return
	}
	n := min(len(text), avail)
	copy(w.out[w.pos:w.pos + n], text[:n])
	w.pos += n
}

@(private = "file")
msg_write_quoted :: proc "contextless" (w: ^Msg_Writer, name: string) {
	msg_write(w, "'")
	msg_write(w, name)
	msg_write(w, "'")
}

// ---- Pass 1: streaming token scan.

@(private = "file")
lint_is_word_keyword :: proc "contextless" (text: string) -> bool {
	switch text {
	case "let", "in", "with", "if", "then", "else", "match", "for":
		return true
	}
	return false
}

// lint_scan_tokens checks malformed tokens, bad hashes, empty pipe targets,
// and redundant parentheses in one streaming pass over `source`.
@(private = "file")
lint_scan_tokens :: proc "contextless" (source: string, sink: ^Lint_Sink) -> int {
	pos := 0
	count := 0
	prev := console_language.Token{kind = .None}

	for {
		tok := console_language.token_next(source, pos, multiline = true)
		if tok.kind == .None {
			if prev.kind == .Pipe {
				lint_emit(sink, {
					kind     = .Empty_Pipe_Target,
					severity = .Error,
					place    = lex_parser.place_of_offset(source, prev.start),
					end      = u32(prev.end),
				})
			}
			break
		}

		count += 1
		tok_text := source[tok.start:tok.end]

		// Check empty or non-callable pipe target right after `|>`.
		if prev.kind == .Pipe {
			bad_target := false
			switch tok.kind {
			case .Name:
				if lint_is_word_keyword(tok_text) || tok_text == "_" {
					bad_target = true
				}
			case .None, .Number, .Text, .Text_Unfinished, .Operator, .Arrow,
			     .Unknown, .Pipe, .Member, .Function_Arrow, .Hash:
				bad_target = true
			}
			if bad_target {
				lint_emit(sink, {
					kind     = .Empty_Pipe_Target,
					severity = .Error,
					place    = lex_parser.place_of_offset(source, prev.start),
					end      = u32(prev.end),
				})
			}
		}

		switch tok.kind {
		case .Text_Unfinished:
			lint_emit(sink, {
				kind     = .Malformed_Token,
				severity = .Error,
				place    = lex_parser.place_of_offset(source, tok.start),
				end      = u32(tok.end),
				name     = "unclosed string",
			})
		case .Unknown:
			lint_emit(sink, {
				kind     = .Malformed_Token,
				severity = .Error,
				place    = lex_parser.place_of_offset(source, tok.start),
				end      = u32(tok.end),
				name     = tok_text,
			})
		case .Hash:
			if _, ok := console_language.hash_value(source, tok.start, tok.end); !ok {
				lint_emit(sink, {
					kind     = .Malformed_Token,
					severity = .Error,
					place    = lex_parser.place_of_offset(source, tok.start),
					end      = u32(tok.end),
					name     = tok_text,
				})
			}
		case .Operator:
			if tok_text == "(" {
				lint_check_redundant_paren(source, prev, tok, sink)
			}
		case .None, .Name, .Number, .Text, .Arrow, .Pipe, .Member, .Function_Arrow:
		}

		prev = tok
		pos = tok.end
	}
	return count
}

// lint_check_redundant_paren flags unambiguously redundant grouping parens:
// double parens `((expr))` and single-atom non-call, non-lambda `(atom)`.
@(private = "file")
lint_check_redundant_paren :: proc "contextless" (
	source: string,
	prev: console_language.Token,
	open_tok: console_language.Token,
	sink: ^Lint_Sink,
) {
	// Skip function call argument lists: `f(...)`, `f(1)(...)`, `fns[0](...)`.
	if prev.kind == .Name {
		prev_text := source[prev.start:prev.end]
		if !lint_is_word_keyword(prev_text) {
			return
		}
	} else if prev.kind == .Operator {
		prev_text := source[prev.start:prev.end]
		if prev_text == ")" || prev_text == "]" {
			return
		}
	}

	// Find the matching `)` and inspect what sits inside.
	p := open_tok.end
	depth := 1
	inner_tokens := 0
	first_inner := console_language.Token{kind = .None}
	first_was_open_paren := false
	first_paren_matched_at_end := false
	close_tok := console_language.Token{kind = .None}

	for {
		t := console_language.token_next(source, p, multiline = true)
		if t.kind == .None || t.kind == .Text_Unfinished {
			return
		}
		t_text := source[t.start:t.end]
		if t.kind == .Operator && t_text == ")" {
			depth -= 1
			if depth == 0 {
				close_tok = t
				break
			}
			// If the very first inner `(` closed back to depth 1, record whether
			// the immediately following token is our outer `)`.
			if depth == 1 && first_was_open_paren && inner_tokens == 0 {
				after_inner := console_language.token_next(source, t.end, multiline = true)
				if after_inner.kind == .Operator && source[after_inner.start:after_inner.end] == ")" {
					first_paren_matched_at_end = true
				}
			}
			if depth == 1 {
				inner_tokens += 1
			}
			p = t.end
			continue
		}

		if depth == 1 && inner_tokens == 0 {
			first_inner = t
			if t.kind == .Operator && t_text == "(" {
				first_was_open_paren = true
			}
		}
		if t.kind == .Operator && t_text == "(" {
			depth += 1
		} else if depth == 1 {
			inner_tokens += 1
		}
		p = t.end
	}

	// Skip lambda parameter lists `(x) => ...` or `() => ...`.
	after_close := console_language.token_next(source, close_tok.end, multiline = true)
	if after_close.kind == .Function_Arrow {
		return
	}

	// Case 1: Double parentheses `((...))`.
	if first_was_open_paren && first_paren_matched_at_end && inner_tokens == 1 {
		lint_emit(sink, {
			kind     = .Redundant_Parentheses,
			severity = .Warning,
			place    = lex_parser.place_of_offset(source, open_tok.start),
			end      = u32(close_tok.end),
		})
		return
	}

	// Case 2: Single atomic value `(x)`, `(42)`, `("hi")`, `(true)`, `(.dark)`, `(blake3:...)`.
	if inner_tokens == 1 {
		switch first_inner.kind {
		case .Number, .Text, .Hash, .Member:
			lint_emit(sink, {
				kind     = .Redundant_Parentheses,
				severity = .Warning,
				place    = lex_parser.place_of_offset(source, open_tok.start),
				end      = u32(close_tok.end),
			})
		case .Name:
			first_text := source[first_inner.start:first_inner.end]
			if !lint_is_word_keyword(first_text) && first_text != "_" {
				lint_emit(sink, {
					kind     = .Redundant_Parentheses,
					severity = .Warning,
					place    = lex_parser.place_of_offset(source, open_tok.start),
					end      = u32(close_tok.end),
				})
			}
		case .None, .Text_Unfinished, .Operator, .Arrow, .Unknown, .Pipe, .Function_Arrow:
		}
	}
}

// ---- Pass 2: parse refusal mapping and AST scope walker.

@(private = "file")
lint_report_parse_refusal :: proc "contextless" (
	source: string,
	refusal: lex_parser.Refusal_Record,
	sink: ^Lint_Sink,
) {
	switch refusal.refusal {
	case .None, .Nodes_Full:
		// Nodes_Full means the inline buffer was exceeded; token-pass diagnostics
		// were already collected. Callers needing full AST analysis pass larger
		// Tree_Storage to lex_lint_with_storage.
		return
	case .Literal_Field_Twice:
		start := int(refusal.place.offset)
		end := console_language.name_end(source, start)
		lint_emit(sink, {
			kind     = .Duplicate_Record_Field,
			severity = .Error,
			place    = refusal.place,
			end      = u32(end),
			name     = source[start:end],
		})
	case .Pipe_No_Left, .Pipe_Line_End, .Pipe_Not_A_Call:
		if !lint_has_at_offset(sink, .Empty_Pipe_Target, refusal.place.offset) {
			lint_emit(sink, {
				kind     = .Empty_Pipe_Target,
				severity = .Error,
				place    = refusal.place,
				end      = refusal.place.offset,
			})
		}
	case .Text_Without_End_Quote, .Hash_Not_Valid, .Lone_Bar:
		if !lint_has_at_offset(sink, .Malformed_Token, refusal.place.offset) {
			lint_emit(sink, {
				kind     = .Malformed_Token,
				severity = .Error,
				place    = refusal.place,
				end      = refusal.place.offset,
			})
		}
	case .Text_Too_Long, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large,
	     .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments,
	     .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing,
	     .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing,
	     .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing,
	     .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name,
	     .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters,
	     .List_Close_Missing, .If_Then_Missing, .If_Else_Missing, .Nesting_Too_Deep,
	     .Thin_Arrow, .Placeholder_Not_Whole, .Placeholder_Twice, .Placeholder_Nested,
	     .Placeholder_Without_Pipe, .Escape_Not_Valid, .Interpolation_Close_Missing,
	     .Pattern_Field_Missing, .Pattern_Close_Missing, .Pattern_Field_Twice,
	     .Pattern_Rest_Not_Last, .Pattern_At_Missing_Brace, .Literal_Path_Conflict,
	     .Comp_Bind_Missing, .Comp_In_Missing, .Comp_Colon_Missing, .Comp_Equal_Missing,
	     .Match_Open_Missing, .Match_Empty, .Match_Arrow_Missing, .Match_Close_Missing,
	     .Match_Pattern_Expected, .Match_Duplicate_Bind, .Param_Kind_Unknown,
	     .Param_Unit_Not_Valid:
		// Avoid emitting a secondary syntax error on a byte already flagged as malformed.
		if !lint_has_at_offset(sink, .Malformed_Token, refusal.place.offset) {
			lint_emit(sink, {
				kind     = .Parse_Error,
				severity = .Error,
				place    = refusal.place,
				end      = refusal.place.offset,
			})
		}
	}
}

@(private = "file")
Lint_Binding :: struct {
	name:         string,
	place:        lex_parser.Place,
	end:          u32,
	used:         bool,
	check_unused: bool,
}

@(private = "file")
Lint_Walker :: struct {
	tree:        ^lex_parser.Syntax_Tree,
	sink:        ^Lint_Sink,
	bindings:    [LINT_SCOPE_BINDING_CAPACITY]Lint_Binding,
	bind_count:  int,
}

@(private = "file")
lint_root_ident :: proc "contextless" (name: string) -> string {
	for i in 0 ..< len(name) {
		if name[i] == '.' {
			return name[:i]
		}
	}
	return name
}

@(private = "file")
lint_scope_contains :: proc "contextless" (w: ^Lint_Walker, upto: int, name: string) -> bool {
	limit := min(upto, w.bind_count)
	for i := limit - 1; i >= 0; i -= 1 {
		if w.bindings[i].name == name {
			return true
		}
	}
	return false
}

@(private = "file")
lint_scope_push :: proc "contextless" (
	w: ^Lint_Walker,
	outer_mark: int,
	name: string,
	place: lex_parser.Place,
	end: u32,
	check_unused: bool,
	check_shadow: bool,
) {
	if len(name) == 0 || name == "_" {
		return
	}
	if check_shadow && lint_scope_contains(w, outer_mark, name) {
		lint_emit(w.sink, {
			kind     = .Shadowed_Binding,
			severity = .Warning,
			place    = place,
			end      = end,
			name     = name,
		})
	}
	if w.bind_count < LINT_SCOPE_BINDING_CAPACITY {
		w.bindings[w.bind_count] = {
			name         = name,
			place        = place,
			end          = end,
			used         = false,
			check_unused = check_unused,
		}
		w.bind_count += 1
	}
}

@(private = "file")
lint_scope_pop :: proc "contextless" (w: ^Lint_Walker, mark: int) {
	for i in mark ..< w.bind_count {
		b := w.bindings[i]
		if b.check_unused && !b.used {
			lint_emit(w.sink, {
				kind     = .Unused_Binding,
				severity = .Warning,
				place    = b.place,
				end      = b.end,
				name     = b.name,
			})
		}
	}
	w.bind_count = mark
}

@(private = "file")
lint_mark_used :: proc "contextless" (w: ^Lint_Walker, raw_name: string) {
	root := lint_root_ident(raw_name)
	if len(root) == 0 {
		return
	}
	for i := w.bind_count - 1; i >= 0; i -= 1 {
		if w.bindings[i].name == root {
			w.bindings[i].used = true
			return
		}
	}
}

// lint_push_pattern_bindings walks a destructuring or match pattern node,
// evaluating default expressions in the enclosing scope and pushing all
// introduced names onto the scope stack.
@(private = "file")
lint_push_pattern_bindings :: proc "contextless" (
	w: ^Lint_Walker,
	pat_idx: lex_parser.Node_Index,
	outer_mark: int,
	check_unused: bool,
	check_shadow: bool,
	depth: int,
) {
	if pat_idx == lex_parser.NO_NODE || depth > LINT_WALK_DEPTH_LIMIT {
		return
	}
	node := lex_parser.node_at(w.tree, pat_idx)
	if node == nil {
		return
	}
	switch node.kind {
	case .Parameter, .Match_Pat_Bind:
		def_expr := lex_parser.node_param_default(w.tree, pat_idx)
		if def_expr != lex_parser.NO_NODE {
			lint_walk_node(w, def_expr, depth + 1)
		}
		start, end := lex_parser.node_span(w.tree, pat_idx)
		lint_scope_push(w, outer_mark, w.tree.text[start:end], lex_parser.node_place(w.tree, pat_idx), u32(end), check_unused, check_shadow)
	case .Pattern_Field:
		def_expr := lex_parser.node_param_default(w.tree, pat_idx)
		if def_expr != lex_parser.NO_NODE {
			lint_walk_node(w, def_expr, depth + 1)
		}
		start, end := lex_parser.node_span(w.tree, pat_idx)
		lint_scope_push(w, outer_mark, w.tree.text[start:end], lex_parser.node_place(w.tree, pat_idx), u32(end), check_unused, check_shadow)
	case .Match_Pat_Field:
		sub := lex_parser.node_child(w.tree, pat_idx)
		if sub == lex_parser.NO_NODE {
			start, end := lex_parser.node_span(w.tree, pat_idx)
			lint_scope_push(w, outer_mark, w.tree.text[start:end], lex_parser.node_place(w.tree, pat_idx), u32(end), check_unused, check_shadow)
		} else {
			lint_push_pattern_bindings(w, sub, outer_mark, check_unused, check_shadow, depth + 1)
		}
	case .Pattern_Record:
		for child in lex_parser.node_children(w.tree, pat_idx) {
			lint_push_pattern_bindings(w, child, outer_mark, check_unused, check_shadow, depth + 1)
		}
	case .Integer, .Text, .Text_Interp, .Name, .Call, .Negate, .Logical_Not, .Binary,
	     .Condition, .Fact_Name, .Refused, .Field_Names, .Record_Literal, .Literal_Field,
	     .Named_Argument, .Let, .Let_Binding, .Member, .Function, .List_Literal, .Hash,
	     .Boolean, .If, .Field_Select, .Pipe, .Placeholder, .Record_Comp, .Match,
	     .Match_Arm, .Match_Pat_Wild:
	}
}

@(private = "file")
lint_walk_node :: proc "contextless" (w: ^Lint_Walker, idx: lex_parser.Node_Index, depth: int) {
	if idx == lex_parser.NO_NODE || depth > LINT_WALK_DEPTH_LIMIT {
		return
	}
	node := lex_parser.node_at(w.tree, idx)
	if node == nil {
		return
	}

	switch node.kind {
	case .Integer, .Text, .Hash, .Boolean, .Member, .Placeholder, .Fact_Name,
	     .Field_Names, .Refused, .Match_Pat_Wild, .Match_Pat_Bind, .Parameter,
	     .Pattern_Field, .Match_Pat_Field, .Pattern_Record:
		return
	case .Name:
		lint_mark_used(w, lex_parser.node_text(w.tree, idx))
	case .Call:
		lint_mark_used(w, lex_parser.node_text(w.tree, idx))
		for arg in lex_parser.node_children(w.tree, idx) {
			lint_walk_node(w, arg, depth + 1)
		}
	case .Negate, .Logical_Not, .Field_Select, .Literal_Field, .Named_Argument, .Condition:
		lint_walk_node(w, lex_parser.node_child(w.tree, idx), depth + 1)
	case .Binary, .Pipe:
		left, right := lex_parser.node_binary_children(w.tree, idx)
		lint_walk_node(w, left, depth + 1)
		lint_walk_node(w, right, depth + 1)
	case .If, .Text_Interp:
		for child in lex_parser.node_children(w.tree, idx) {
			lint_walk_node(w, child, depth + 1)
		}
	case .Record_Literal:
		children := lex_parser.node_children(w.tree, idx)
		if len(children) == 0 {
			_, end := lex_parser.node_span(w.tree, idx)
			lint_emit(w.sink, {
				kind     = .Empty_Record,
				severity = .Warning,
				place    = lex_parser.node_place(w.tree, idx),
				end      = u32(end),
			})
			return
		}
		for child in children {
			lint_walk_node(w, child, depth + 1)
		}
	case .List_Literal:
		children := lex_parser.node_children(w.tree, idx)
		if len(children) == 0 {
			_, end := lex_parser.node_span(w.tree, idx)
			lint_emit(w.sink, {
				kind     = .Empty_List,
				severity = .Warning,
				place    = lex_parser.node_place(w.tree, idx),
				end      = u32(end),
			})
			return
		}
		for child in children {
			lint_walk_node(w, child, depth + 1)
		}
	case .Let:
		children := lex_parser.node_children(w.tree, idx)
		if len(children) == 0 {
			return
		}
		outer_mark := w.bind_count
		// Register every binding of this `let` before walking RHS expressions
		// and body, matching Lex's mutual `let` visibility.
		for child in children {
			cn := lex_parser.node_at(w.tree, child)
			if cn == nil || cn.kind != .Let_Binding {
				continue
			}
			if pat, is_pat := lex_parser.let_binding_pattern(w.tree, child); is_pat {
				lint_push_pattern_bindings(w, pat, outer_mark, true, true, depth + 1)
			} else {
				start, end := lex_parser.node_span(w.tree, child)
				lint_scope_push(w, outer_mark, w.tree.text[start:end], lex_parser.node_place(w.tree, child), u32(end), true, true)
			}
		}
		for child in children {
			cn := lex_parser.node_at(w.tree, child)
			if cn != nil && cn.kind == .Let_Binding {
				lint_walk_node(w, lex_parser.node_child(w.tree, child), depth + 1)
			} else {
				lint_walk_node(w, child, depth + 1)
			}
		}
		lint_scope_pop(w, outer_mark)
	case .Let_Binding:
		lint_walk_node(w, lex_parser.node_child(w.tree, idx), depth + 1)
	case .Function:
		children := lex_parser.node_children(w.tree, idx)
		if len(children) == 0 {
			return
		}
		outer_mark := w.bind_count
		param_count := len(children) - 1
		for i in 0 ..< param_count {
			lint_push_pattern_bindings(w, children[i], outer_mark, false, false, depth + 1)
		}
		lint_walk_node(w, children[param_count], depth + 1)
		lint_scope_pop(w, outer_mark)
	case .Record_Comp:
		children := lex_parser.node_children(w.tree, idx)
		has_cond := (node.sub & lex_parser.REC_COMP_HAS_COND) != 0
		need := has_cond ? 5 : 4
		if len(children) < need {
			return
		}
		// Walk iterator in enclosing scope, then bind pattern for condition/key/value.
		lint_walk_node(w, children[1], depth + 1)
		outer_mark := w.bind_count
		lint_push_pattern_bindings(w, children[0], outer_mark, false, false, depth + 1)
		if has_cond {
			lint_walk_node(w, children[2], depth + 1)
			lint_walk_node(w, children[3], depth + 1)
			lint_walk_node(w, children[4], depth + 1)
		} else {
			lint_walk_node(w, children[2], depth + 1)
			lint_walk_node(w, children[3], depth + 1)
		}
		lint_scope_pop(w, outer_mark)
	case .Match:
		children := lex_parser.node_children(w.tree, idx)
		if len(children) == 0 {
			return
		}
		lint_walk_node(w, children[0], depth + 1)
		for i in 1 ..< len(children) {
			lint_walk_node(w, children[i], depth + 1)
		}
	case .Match_Arm:
		children := lex_parser.node_children(w.tree, idx)
		has_guard := (node.sub & lex_parser.MATCH_ARM_HAS_GUARD) != 0
		need := has_guard ? 3 : 2
		if len(children) < need {
			return
		}
		outer_mark := w.bind_count
		lint_push_pattern_bindings(w, children[0], outer_mark, false, false, depth + 1)
		if has_guard {
			lint_walk_node(w, children[1], depth + 1)
			lint_walk_node(w, children[2], depth + 1)
		} else {
			lint_walk_node(w, children[1], depth + 1)
		}
		lint_scope_pop(w, outer_mark)
	}
}
