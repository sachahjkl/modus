// The words of the language of the console, and what each part of a line
// is (docs/CONSOLE.md, section 7). The parser of the console reads its
// names, numbers and texts with token_next and the procedures under it, so
// the colors of a line and the parser agree on where a token starts and
// ends: there is one scanner.
//
// The package has no state, calls no allocator and makes no kernel call:
// each procedure reads a text and writes into memory of the caller. It
// reads a line that is not finished: a text with no end quote, a name the
// input still types, any byte. It never stops at a fault: a byte that the
// language does not take is one token of the kind Unknown.
package console_language

import terminal "modus:support/terminal"

// The kinds of tokens. The parser reads the operators one byte at a time;
// the arrow '->' is a token of the signatures, not of an expression. The
// pipe operator '|>' never reaches the parser: pipe.odin writes the line in
// its nested form first.
Token_Kind :: enum u8 {
	None            = 0, // The end of the text.
	Name            = 1, // A letter or '_', then letters, digits, '_' and '.': monitor.count, r.x.
	Number          = 2, // Digits.
	Text            = 3, // A text in double quotes, with its two quotes.
	Text_Unfinished = 4, // A quote and the rest of the line: no end quote yet.
	Operator        = 5, // One byte of OPERATOR_BYTES: an operator of two bytes, as "<=", is two tokens.
	Arrow           = 6, // '->'.
	Unknown         = 7, // One byte of no other token. A '|' with no '>' after it is one.
	Pipe            = 8, // '|>': the value on its left is the first argument of the call on its right.
	Member          = 9, // A '.', then a name: a member of an enum, `.french`, which the parameter that receives it names.
	Function_Arrow  = 10, // '=>': between the parameters of a function and its body.
}

// A token: its kind and its bytes, text[start:end].
Token :: struct {
	kind:  Token_Kind, // What the bytes are.
	start: int, // The first byte.
	end:   int, // The byte after the last.
}

OPERATOR_BYTES :: "+-*/%=(),:.{}[]<>!" // The bytes that are an operator alone. "<", ">" and "!" are the parts of the operators of a condition: <, <=, >, >=, !=. "[" and "]" hold a list.

// A line that is finished: no name is still being typed.
NO_CARET :: -1

// name_first says if a byte can start a name: a letter or '_'.
name_first :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
}

// digit says if a byte is a decimal digit.
digit :: proc "contextless" (character: u8) -> bool {
	return character >= '0' && character <= '9'
}

// operator_byte says if a byte is one of OPERATOR_BYTES.
operator_byte :: proc "contextless" (character: u8) -> bool {
	operators := OPERATOR_BYTES
	for index in 0 ..< len(operators) {
		if operators[index] == character {
			return true
		}
	}
	return false
}

// space_end gives the first byte at or after position that is not a space
// and not in a comment: "//" outside a text, to the end of its line. So a
// comment gives no token, and the parser and the nested form never see one.
space_end :: proc "contextless" (text: string, position: int) -> int {
	place := clamp(position, 0, len(text))
	for place < len(text) {
		if text[place] == ' ' {
			place += 1
		} else if comment_starts(text, place) {
			place = comment_end(text, place)
		} else {
			break
		}
	}
	return place
}

// comment_starts says if a comment starts at a byte: "//". A '/' with a
// space after it, as in "a / / b", is an operator.
comment_starts :: proc "contextless" (text: string, place: int) -> bool {
	return place >= 0 && place + 1 < len(text) && text[place] == '/' && text[place + 1] == '/'
}

// comment_end gives the end of the comment that starts at start: the end
// of its line, before its '\n', or the end of the text.
comment_end :: proc "contextless" (text: string, start: int) -> int {
	place := clamp(start, 0, len(text))
	for place < len(text) && text[place] != '\n' {
		place += 1
	}
	return place
}

// name_end gives the end of the name that starts at start, or start when no
// name starts there.
name_end :: proc "contextless" (text: string, start: int) -> int {
	place := clamp(start, 0, len(text))
	if place == len(text) || !name_first(text[place]) {
		return place
	}
	place += 1
	for place < len(text) && (name_first(text[place]) || digit(text[place]) || text[place] == '.') {
		place += 1
	}
	return place
}

// number_end gives the end of the digits that start at start.
number_end :: proc "contextless" (text: string, start: int) -> int {
	place := clamp(start, 0, len(text))
	for place < len(text) && digit(text[place]) {
		place += 1
	}
	return place
}

// text_end gives the end of the text whose quote is at start: after its end
// quote, or the end of the line with finished false.
text_end :: proc "contextless" (text: string, start: int) -> (end: int, finished: bool) {
	place := clamp(start, 0, len(text)) + 1
	for place < len(text) {
		if text[place] == '"' {
			return place + 1, true
		}
		place += 1
	}
	return len(text), false
}

// token_next gives the token at or after position, after its spaces. At
// the end of the text: the kind None, with start and end at the end.
token_next :: proc "contextless" (text: string, position: int) -> Token {
	start := space_end(text, position)
	if start >= len(text) {
		return {kind = .None, start = len(text), end = len(text)}
	}
	character := text[start]
	switch {
	case name_first(character):
		return {kind = .Name, start = start, end = name_end(text, start)}
	case digit(character):
		return {kind = .Number, start = start, end = number_end(text, start)}
	case character == '"':
		end, finished := text_end(text, start)
		return {kind = finished ? .Text : .Text_Unfinished, start = start, end = end}
	case character == '-' && start + 1 < len(text) && text[start + 1] == '>':
		return {kind = .Arrow, start = start, end = start + 2}
	case character == '|' && start + 1 < len(text) && text[start + 1] == '>':
		return {kind = .Pipe, start = start, end = start + 2}
	case character == '=' && start + 1 < len(text) && text[start + 1] == '>':
		return {kind = .Function_Arrow, start = start, end = start + 2}
	case character == '.' && start + 1 < len(text) && name_first(text[start + 1]):
		// The name of a member holds no '.': `.a.b` is a member and a '.'.
		end := start + 1
		for end < len(text) && (name_first(text[end]) || digit(text[end])) {
			end += 1
		}
		return {kind = .Member, start = start, end = end}
	case operator_byte(character):
		return {kind = .Operator, start = start, end = start + 1}
	}
	return {kind = .Unknown, start = start, end = start + 1}
}

// ---- What each part of a line is.

// What a name is for the console that shows the line.
Name_Role :: enum u8 {
	Unknown  = 0, // The console knows no such name.
	Function = 1, // A command, or an export of a module or of a service.
	Record   = 2, // A command that makes a record: its name is a type.
	Module   = 3, // A module or a service.
	Variable = 4, // A variable of the console.
	Stream   = 5, // A typed name of a record output, "owner.output": the owner, then the record output.
}

// The console gives the roles of its names. The package keeps no table of
// names: the names change with each module that the console loads.
Name_Lookup :: struct {
	data:    rawptr, // The state of the console.
	role_of: proc "contextless" (data: rawptr, name: string) -> Name_Role, // Gives the role of a name.
	// Gives the number from 0 of the first argument of a command from which
	// each argument is the name of a field (columns(t, a, b): 1), or -1.
	field_names_from: proc "contextless" (data: rawptr, command: string) -> int,
}

// role_of gives the role of a name through a lookup. A lookup with no
// procedure knows no name.
role_of :: proc "contextless" (lookup: Name_Lookup, name: string) -> Name_Role {
	return lookup.role_of == nil ? .Unknown : lookup.role_of(lookup.data, name)
}

// field_names_from gives the first argument of a command that is a name of
// a field, or -1: a lookup with no procedure knows none.
field_names_from :: proc "contextless" (lookup: Name_Lookup, command: string) -> int {
	return lookup.field_names_from == nil ? -1 : lookup.field_names_from(lookup.data, command)
}

// The calls that line_runs follows inside each other, at most: past them
// a name has its role, with no field.
CALL_DEPTH_MOST :: 16

// One call that line_runs is inside of.
@(private = "file")
Open_Call :: struct {
	names_from: int, // The first argument that is a name of a field, or -1.
	argument:   int, // The argument that the scanner is in, from 0; after a "|>", from 1.
}

// run_add writes the run text[start:end] of a kind after count runs. A
// part longer than 255 bytes is several runs; a run cannot start after the
// byte 255 (a row has RUN_LIMIT bytes); the kind None is no run. It gives
// the new count; runs that do not fit are not written.
run_add :: proc "contextless" (runs: []terminal.Code_Run, count: int, start, end: int, kind: terminal.Code_Kind) -> int {
	if kind == .None {
		return count
	}
	written := count
	place := start
	for place < end && written < len(runs) && place <= 255 {
		length := min(end - place, 255)
		runs[written] = {start = u8(place), length = u8(length), kind = u8(kind)}
		written += 1
		place += length
	}
	return written
}

// comparison_starts says if a token is the first byte of an operator of a
// condition: "=", "<", ">", or "!" before "=".
comparison_starts :: proc "contextless" (text: string, token: Token) -> bool {
	if token.kind != .Operator {
		return false
	}
	switch text[token.start] {
	case '=', '<', '>':
		return true
	case '!':
		return token.end < len(text) && text[token.end] == '='
	}
	return false
}

// line_runs writes the runs of an expression of the console: text[first:]
// is the expression (text[:first] is a prompt, with no run). caret is the
// place of the caret in text, or NO_CARET for a line that is finished. It
// gives the count of runs written; when runs is full, the rest of the line
// has no run, and its text is whole.
//
// A name that is a command or a module has its color at once, while the
// input types it. A name that is nothing that the console knows is marked
// Unknown only after the input typed a byte after it: a name that ends at
// the caret or at the end of the line is still being typed, and has no
// run. A text with no end quote is Text_Unfinished, not an error.
//
// In a condition (`level = Warning`), a name that the console does not
// know before an operator is a field, and after an operator a member of
// the enum of a status: both are names of a description, which the
// console checks when the line runs, and have the color of a parameter.
line_runs :: proc "contextless" (text: string, first: int, caret: int, lookup: Name_Lookup, runs: []terminal.Code_Run) -> int {
	count := 0
	position := clamp(first, 0, len(text))
	first_token := true
	assignment_operator := -1 // The '=' after the name of a variable, at the start of the line.
	after_comparison := false // The token before is the last byte of an operator of a condition.
	// The calls that the scanner is inside of, for the arguments that are
	// names of fields: columns(t, slot, name).
	calls: [CALL_DEPTH_MOST]Open_Call
	depth := 0
	pending_call := Open_Call{names_from = -1}
	pending := false // The token before is the name of a call, whose "(" comes now.
	after_pipe := false // The token before is "|>".
	for count < len(runs) {
		token := token_next(text, position)
		// The comment before the token, which gives no token: in the color
		// of the words of a row, the color of a comment.
		count = comment_runs(text, position, token.start, runs, count)
		if token.kind == .None {
			break
		}
		position = token.end
		comparison_before := after_comparison
		// The calls: a "(" after a name opens one, "," moves to the next
		// argument, ")" closes it.
		if token.kind == .Operator {
			switch text[token.start] {
			case '(':
				call := pending ? pending_call : Open_Call{names_from = -1}
				if depth < CALL_DEPTH_MOST {
					calls[depth] = call
				}
				depth += 1
			case ')':
				depth = max(depth - 1, 0)
			case ',':
				if depth > 0 && depth <= CALL_DEPTH_MOST {
					calls[depth - 1].argument += 1
				}
			}
		}
		pipe_before := after_pipe
		after_pipe = token.kind == .Pipe
		pending = false
		if token.kind == .Name {
			next := token_next(text, token.end)
			if next.kind == .Operator && text[next.start] == '(' {
				pending = true
				pending_call = {names_from = field_names_from(lookup, text[token.start:token.end]), argument = pipe_before ? 1 : 0}
			} else if depth > 0 && depth <= CALL_DEPTH_MOST && calls[depth - 1].names_from >= 0 && calls[depth - 1].argument >= calls[depth - 1].names_from {
				// A name of a field, which the console checks against the
				// record of the table when the line runs.
				if !(caret != NO_CARET && (token.end == caret || token.end == len(text))) {
					count = run_add(runs, count, token.start, token.end, .Parameter)
				}
				first_token = false
				after_comparison = false
				continue
			}
		}
		// The last byte of an operator of a condition: "=" ends "=", "!=",
		// "<=" and ">="; "<" and ">" end themselves when no "=" follows.
		after_comparison = false
		if token.kind == .Operator && token.start != assignment_operator {
			switch text[token.start] {
			case '=':
				after_comparison = true
			case '<', '>':
				after_comparison = token.end >= len(text) || text[token.end] != '='
			}
		}
		switch token.kind {
		case .None:
		case .Name:
			being_typed := caret != NO_CARET && (token.end == caret || token.end == len(text))
			// The words of Lex have the color of an operator, and the names
			// of the bindings of a let the color of a variable.
			if word_of_lex(text, token) {
				if !being_typed {
					count = run_add(runs, count, token.start, token.end, .Operator)
				}
				break
			}
			if bound_by_let(text, token) || bound_by_function(text, token) {
				count = run_add(runs, count, token.start, token.end, .Variable)
				break
			}
			assigned := false
			next := token_next(text, token.end)
			if first_token {
				assigned = next.kind == .Operator && text[next.start] == '='
				if assigned {
					assignment_operator = next.start
				}
			}
			name := text[token.start:token.end]
			in_condition := !assigned && (comparison_before || (next.start != assignment_operator && comparison_starts(text, next)))
			if in_condition && role_of(lookup, name) == .Unknown {
				if !being_typed {
					count = run_add(runs, count, token.start, token.end, .Parameter)
				}
				break
			}
			count = name_runs(text, token, being_typed, assigned, lookup, runs, count)
		case .Number:
			count = run_add(runs, count, token.start, token.end, .Number)
		case .Text:
			count = run_add(runs, count, token.start, token.end, .Text)
		case .Text_Unfinished:
			count = run_add(runs, count, token.start, token.end, .Text_Unfinished)
		case .Operator, .Pipe, .Function_Arrow:
			count = run_add(runs, count, token.start, token.end, .Operator)
		case .Arrow:
			count = run_add(runs, count, token.start, token.end, .Arrow)
		case .Unknown:
			count = run_add(runs, count, token.start, token.end, .Unknown)
		case .Member:
			// A name of a description, as a member of a status in a
			// condition: the console checks it when the line runs.
			count = run_add(runs, count, token.start, token.end, .Parameter)
		}
		first_token = false
	}
	return count
}

// comment_runs writes a run of the kind Words for each comment between two
// tokens, text[from:to], which holds only spaces and comments.
comment_runs :: proc "contextless" (text: string, from, to: int, runs: []terminal.Code_Run, count: int) -> int {
	written := count
	place := clamp(from, 0, len(text))
	for place < min(to, len(text)) {
		if comment_starts(text, place) {
			end := comment_end(text, place)
			written = run_add(runs, written, place, end, .Words)
			place = end
		} else {
			place += 1
		}
	}
	return written
}

// word_of_lex says if a token is a word of Lex: `let`, `in`, `with`, or the
// placeholder `_`.
word_of_lex :: proc "contextless" (text: string, token: Token) -> bool {
	return word_is(text, token, "let") || word_is(text, token, "in") || word_is(text, token, "with") || word_is(text, token, "_")
}

// bound_by_let says if a name, before its first '.', is the name of a
// binding of a let of the line: a name after `let`, or after a ',' of the
// bindings of a let, with a single '=' after it. The line is short, so the
// colors read it again for each name.
bound_by_let :: proc "contextless" (text: string, token: Token) -> bool {
	name := text[token.start:token.end]
	for place in 0 ..< len(name) {
		if name[place] == '.' {
			name = name[:place]
			break
		}
	}
	// The depth of the groups where each open let reads its bindings.
	let_depths: [CALL_DEPTH_MOST]int
	lets := 0
	depth := 0
	before := Token{}
	for scanned := token_next(text, 0); scanned.kind != .None; scanned = token_next(text, scanned.end) {
		defer {
			before = scanned
		}
		switch {
		case opens(text, scanned):
			depth += 1
		case closes(text, scanned):
			depth -= 1
		case word_is(text, scanned, "let"):
			if lets < len(let_depths) {
				let_depths[lets] = depth
			}
			lets += 1
		case word_is(text, scanned, "in") && lets > 0:
			lets -= 1
		case scanned.kind == .Name && lets > 0 && lets <= len(let_depths) && let_depths[lets - 1] == depth && text[scanned.start:scanned.end] == name:
			opens_binding := word_is(text, before, "let") || before.kind == .Operator && text[before.start] == ','
			equal := token_next(text, scanned.end)
			if opens_binding && equal.kind == .Operator && text[equal.start] == '=' && !(equal.end < len(text) && text[equal.end] == '=') {
				return true
			}
		}
	}
	return false
}

// function_head says if the '(' at open starts a function: its group
// closes, and "=>" follows its ')'. It gives the ')' and the byte after the
// "=>". The parameters are not checked: the parser refuses a parameter
// that is no name at its place.
function_head :: proc "contextless" (text: string, open: int) -> (close: int, arrow_end: int, found: bool) {
	first := token_next(text, open)
	if first.start != open || !(first.kind == .Operator && text[first.start] == '(') {
		return 0, 0, false
	}
	depth := 0
	for token := first; token.kind != .None; token = token_next(text, token.end) {
		if opens(text, token) {
			depth += 1
		} else if closes(text, token) {
			depth -= 1
			if depth == 0 {
				arrow := token_next(text, token.end)
				if arrow.kind != .Function_Arrow {
					return 0, 0, false
				}
				return token.start, arrow.end, true
			}
		}
	}
	return 0, 0, false
}

// function_body_end gives the end of the body of a function that starts at
// body_start, after its "=>": the ',' or the close of the group that holds
// the function, the `in` of a let around it, or the end of the line.
function_body_end :: proc "contextless" (text: string, body_start: int) -> int {
	depth := 0
	lets := 0
	for token := token_next(text, body_start); token.kind != .None; token = token_next(text, token.end) {
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			if depth == 0 {
				return token.start
			}
			depth -= 1
		case depth == 0 && word_is(text, token, "let"):
			lets += 1
		case depth == 0 && word_is(text, token, "in"):
			if lets == 0 {
				return token.start
			}
			lets -= 1
		case depth == 0 && lets == 0 && token.kind == .Operator && text[token.start] == ',':
			return token.start
		}
	}
	return len(text)
}

// bound_by_function says if a name, before its first '.', is a parameter
// of a function of the line: in the parentheses of its head, or in its
// body. The line is short, so the colors read it again for each name.
bound_by_function :: proc "contextless" (text: string, token: Token) -> bool {
	name := text[token.start:token.end]
	for place in 0 ..< len(name) {
		if name[place] == '.' {
			name = name[:place]
			break
		}
	}
	for open := token_next(text, 0); open.kind != .None; open = token_next(text, open.end) {
		if !(open.kind == .Operator && text[open.start] == '(') {
			continue
		}
		close, arrow_end, found := function_head(text, open.start)
		if !found {
			continue
		}
		in_head := token.start > open.start && token.start < close
		in_body := token.start >= arrow_end && token.start < function_body_end(text, arrow_end)
		if !in_head && !in_body {
			continue
		}
		parameters: [HEAD_PARAMETERS_READ]Token
		for parameter in parameters[:head_parameters(text, open.end, close, parameters[:])] {
			if text[parameter.start:parameter.end] == name && (in_body || parameter.start == token.start) {
				return true
			}
		}
	}
	return false
}

// The parameters of a head that the colors and the completion read: those
// of a function, 12, and room for a head that the parser refuses.
HEAD_PARAMETERS_READ :: 16

// head_parameters writes into tokens the parameters of a function head
// whose parentheses hold text[first:close]: each name with no '.' alone
// between the '(' or a ',' and a ',' or the ')', as the parser reads them.
// A name in a group or before a '(' is no parameter.
head_parameters :: proc "contextless" (text: string, first, close: int, tokens: []Token) -> int {
	count := 0
	depth := 0
	alone := true // The token before is the '(' or a ',' at the level of the head.
	for token := token_next(text, first); token.kind != .None && token.start < close; token = token_next(text, token.end) {
		switch {
		case opens(text, token):
			depth += 1
			alone = false
		case closes(text, token):
			depth -= 1
			alone = false
		case depth == 0 && token.kind == .Operator && text[token.start] == ',':
			alone = true
		case:
			next := token_next(text, token.end)
			ends := next.start >= close || next.kind == .Operator && text[next.start] == ','
			dotted := false
			for character in text[token.start:token.end] {
				dotted ||= character == '.'
			}
			if depth == 0 && alone && token.kind == .Name && !dotted && ends && count < len(tokens) {
				tokens[count] = token
				count += 1
			}
			alone = false
		}
	}
	return count
}

// parameters_at writes into tokens the parameters of each function of the
// line whose body holds the byte place, the outer ones first, and gives
// their count: the names that a name typed there can read.
parameters_at :: proc "contextless" (text: string, place: int, tokens: []Token) -> int {
	count := 0
	for open := token_next(text, 0); open.kind != .None && open.start < place; open = token_next(text, open.end) {
		if !(open.kind == .Operator && text[open.start] == '(') {
			continue
		}
		close, arrow_end, found := function_head(text, open.start)
		if !found || place < arrow_end || place > function_body_end(text, arrow_end) {
			continue
		}
		count += head_parameters(text, open.end, close, tokens[count:])
	}
	return count
}

// in_comment says if a byte place of a line is in a comment: after its
// first '/', up to the end of its line. A place at the '/' itself is before
// the comment: a name that ends there is a name. The place is read with the
// scanner, so "//" in a text is no comment, as for the colors and the
// parser.
in_comment :: proc "contextless" (text: string, place: int) -> bool {
	position := 0
	for position <= len(text) {
		token := token_next(text, position)
		// The spaces and the comments between two tokens.
		for gap := position; gap < token.start; {
			if comment_starts(text, gap) {
				end := comment_end(text, gap)
				if place > gap && place <= end {
					return true
				}
				gap = end
			} else {
				gap += 1
			}
		}
		if token.kind == .None || token.start >= place {
			return false
		}
		position = token.end
	}
	return false
}

// The groups that the completion follows inside each other, at most.
GROUP_DEPTH_MOST :: 16

// What opens a group.
Group_Opener :: enum u8 {
	Parenthesis = 0, // '(': a call, or an expression or the parameters of a function.
	Brace       = 1, // '{': a record literal.
	Bracket     = 2, // '[': a list.
}

// One group open at a place of a line.
Open_Group :: struct {
	opener: Group_Opener,
	start:  int, // The byte of its '(', '{' or '['.
	commas: int, // The ',' of the group before the place.
}

// groups_at gives the groups open at a byte place of a line, read with the
// scanner: a byte of a text or of a comment opens nothing. found is false
// past GROUP_DEPTH_MOST groups.
groups_at :: proc "contextless" (text: string, place: int, groups: ^[GROUP_DEPTH_MOST]Open_Group) -> (depth: int, found: bool) {
	too_deep := 0
	limit := clamp(place, 0, len(text))
	for token := token_next(text, 0); token.kind != .None && token.start < limit; token = token_next(text, token.end) {
		switch {
		case opens(text, token):
			if depth == GROUP_DEPTH_MOST {
				too_deep += 1
				break
			}
			opener := Group_Opener.Parenthesis
			if text[token.start] == '{' {
				opener = .Brace
			} else if text[token.start] == '[' {
				opener = .Bracket
			}
			groups[depth] = {opener = opener, start = token.start}
			depth += 1
		case closes(text, token):
			if too_deep > 0 {
				too_deep -= 1
			} else if depth > 0 {
				depth -= 1
			}
		case token.kind == .Operator && text[token.start] == ',':
			if too_deep == 0 && depth > 0 {
				groups[depth - 1].commas += 1
			}
		}
	}
	return depth, too_deep == 0
}

// name_runs writes the runs of one name of a line. assigned: the name is
// the first of the line and '=' follows it: it names a variable.
name_runs :: proc "contextless" (text: string, token: Token, being_typed, assigned: bool, lookup: Name_Lookup, runs: []terminal.Code_Run, count: int) -> int {
	name := text[token.start:token.end]
	written := count
	last_dot := -1
	first_dot := -1
	for index in 0 ..< len(name) {
		if name[index] == '.' {
			last_dot = index
			if first_dot < 0 {
				first_dot = index
			}
		}
	}
	role := role_of(lookup, name)
	switch role {
	case .Function, .Record:
		kind := terminal.Code_Kind.Function
		if role == .Record {
			kind = .Type
		}
		if last_dot < 0 {
			return run_add(runs, written, token.start, token.end, kind)
		}
		// monitor.count: the module, the dot, the export.
		written = run_add(runs, written, token.start, token.start + last_dot, .Module)
		written = run_add(runs, written, token.start + last_dot, token.start + last_dot + 1, .Operator)
		return run_add(runs, written, token.start + last_dot + 1, token.end, kind)
	case .Module:
		return run_add(runs, written, token.start, token.end, .Module)
	case .Variable:
		return run_add(runs, written, token.start, token.end, .Variable)
	case .Stream:
		// server.requests: the owner, the dot, and the record output, which
		// is a value of the line as a variable is.
		if first_dot <= 0 {
			return run_add(runs, written, token.start, token.end, .Variable)
		}
		written = run_add(runs, written, token.start, token.start + first_dot, .Module)
		written = run_add(runs, written, token.start + first_dot, token.start + first_dot + 1, .Operator)
		return run_add(runs, written, token.start + first_dot + 1, token.end, .Variable)
	case .Unknown:
	}
	if assigned {
		return run_add(runs, written, token.start, token.end, .Variable)
	}
	if first_dot > 0 {
		owner := name[:first_dot]
		switch role_of(lookup, owner) {
		case .Unknown, .Function, .Record, .Stream:
			// No field and no export follows such a name: the whole token is unknown below.
		case .Variable:
			// variable.field: the console checks the field when the line runs.
			return run_add(runs, written, token.start, token.end, .Variable)
		case .Module:
			// A module and a name that is not one of its exports, or not yet.
			written = run_add(runs, written, token.start, token.start + first_dot, .Module)
			written = run_add(runs, written, token.start + first_dot, token.start + first_dot + 1, .Operator)
			if being_typed {
				return written
			}
			return run_add(runs, written, token.start + first_dot + 1, token.end, .Unknown)
		}
	}
	if being_typed {
		return written
	}
	return run_add(runs, written, token.start, token.end, .Unknown)
}

// The parts of a signature, for signature_runs.
Signature_Place :: enum u8 {
	Words      = 0, // Before the parameters: "export of monitor", "command", "3 lines ago".
	Parameters = 1, // In the parentheses of the parameters, before a ':'.
	Type       = 2, // After ':' or '->': a type, with what its parentheses hold.
}

// signature_runs writes the runs of what a row of the completion list says
// about its name, text[first:]: words, then a signature as the console
// writes it: "export of monitor (names: Table(Count_Name, Read)) ->
// Table(Count)". The words before the parameters are Words, and the word
// after "of" is the Module. In the parentheses, a name before ':' is a
// Parameter; after ':' or '->', each name is a Type, also in the
// parentheses of the type. It gives the count of runs written.
signature_runs :: proc "contextless" (text: string, first: int, runs: []terminal.Code_Run) -> int {
	count := 0
	position := clamp(first, 0, len(text))
	place := Signature_Place.Words
	in_parameters := false
	type_parentheses := 0 // The parentheses that the type at this place opened.
	after_of := false
	for count < len(runs) {
		token := token_next(text, position)
		if token.kind == .None {
			break
		}
		position = token.end
		bytes := text[token.start:token.end]
		kind := terminal.Code_Kind.Unknown
		switch token.kind {
		case .None:
		case .Name:
			switch place {
			case .Words:
				kind = .Words
				if after_of {
					kind = .Module
				}
			case .Parameters:
				next := token_next(text, token.end)
				if next.kind == .Operator && text[next.start] == ':' {
					kind = .Parameter
				} else {
					// A parameter with no name: its type.
					kind = .Type
					place = .Type
				}
			case .Type:
				kind = .Type
			}
		case .Number:
			kind = .Number
			if place == .Words {
				kind = .Words
			}
		case .Text:
			kind = .Text
		case .Text_Unfinished:
			kind = .Text_Unfinished
		case .Arrow:
			kind = .Arrow
			place = .Type
			type_parentheses = 0
		case .Operator:
			kind = .Operator
			switch bytes {
			case "(":
				if place == .Words && !in_parameters {
					in_parameters = true
					place = .Parameters
				} else {
					type_parentheses += 1
					place = .Type
				}
			case ")":
				if type_parentheses > 0 {
					type_parentheses -= 1
				} else if in_parameters {
					in_parameters = false
					place = .Words
				}
			case ",":
				if type_parentheses == 0 && in_parameters {
					place = .Parameters
				}
			case ":":
				place = .Type
				type_parentheses = 0
			case:
				if place == .Words {
					kind = .Words
				}
			}
		case .Member:
			kind = .Parameter
		case .Unknown, .Pipe, .Function_Arrow:
			if place == .Words {
				kind = .Words
			}
		}
		after_of = token.kind == .Name && bytes == "of" && place == .Words
		count = run_add(runs, count, token.start, token.end, kind)
	}
	return count
}

// ---- The integers of a line.
//
// An Integer of the console has 64 bits with a sign. An operation whose
// result does not fit gives ok false, and the console ends the line with an
// error: a result that wrapped is a wrong number that looks right.

INTEGER_LEAST :: min(i64) // The least Integer of a line.
INTEGER_MOST :: max(i64) // The largest Integer of a line.

// number_value gives the value of the decimal digits text[start:end]. ok is
// false when the number is larger than INTEGER_MOST, or when a byte is not a
// digit.
number_value :: proc "contextless" (text: string, start, end: int) -> (value: i64, ok: bool) {
	first := clamp(start, 0, len(text))
	last := clamp(end, first, len(text))
	for place in first ..< last {
		if !digit(text[place]) {
			return 0, false
		}
		digit_value := i64(text[place] - '0')
		if value > (INTEGER_MOST - digit_value) / 10 {
			return 0, false
		}
		value = value * 10 + digit_value
	}
	return value, true
}

// integer_add gives a + b. ok is false when the sum does not fit.
integer_add :: proc "contextless" (a, b: i64) -> (sum: i64, ok: bool) {
	if b > 0 && a > INTEGER_MOST - b || b < 0 && a < INTEGER_LEAST - b {
		return 0, false
	}
	return a + b, true
}

// integer_subtract gives a - b. ok is false when the difference does not fit.
integer_subtract :: proc "contextless" (a, b: i64) -> (difference: i64, ok: bool) {
	if b > 0 && a < INTEGER_LEAST + b || b < 0 && a > INTEGER_MOST + b {
		return 0, false
	}
	return a - b, true
}

// integer_multiply gives a * b. ok is false when the product does not fit.
integer_multiply :: proc "contextless" (a, b: i64) -> (product: i64, ok: bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	// The one product with -1 that does not fit; the division below
	// cannot take it.
	if a == -1 || b == -1 {
		other := a == -1 ? b : a
		if other == INTEGER_LEAST {
			return 0, false
		}
		return -other, true
	}
	if a > 0 {
		if b > 0 && a > INTEGER_MOST / b || b < 0 && b < INTEGER_LEAST / a {
			return 0, false
		}
	} else {
		if b > 0 && a < INTEGER_LEAST / b || b < 0 && a < INTEGER_MOST / b {
			return 0, false
		}
	}
	return a * b, true
}

// integer_negate gives -a. ok is false for INTEGER_LEAST: its opposite does
// not fit.
integer_negate :: proc "contextless" (a: i64) -> (opposite: i64, ok: bool) {
	if a == INTEGER_LEAST {
		return 0, false
	}
	return -a, true
}

// integer_divide gives a / b and a % b. ok is false when b is 0, and when
// the quotient does not fit (INTEGER_LEAST / -1). The caller tells the two
// apart with b.
integer_divide :: proc "contextless" (a, b: i64) -> (quotient, rest: i64, ok: bool) {
	if b == 0 {
		return 0, 0, false
	}
	// The processor refuses INTEGER_LEAST / -1: no division runs with -1.
	if b == -1 {
		opposite, fits := integer_negate(a)
		return opposite, 0, fits
	}
	return a / b, a % b, true
}
