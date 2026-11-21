package console_language

// The pipe operator of the console: `a |> f(b, c)` is `f(a, b, c)`, and
// `a |> f` is `f(a)`. The operator adds no meaning to a line: before any
// call, the console writes the line in its nested form here, and its parser
// reads that form as any other line, so a line with '|>' checks and runs as
// the same line with calls in calls (docs/CONSOLE.md, "The pipe operator").
//
// The operator has the lowest priority, below '+', '-' and `with`, and it
// chains from the left: `x |> h |> g(1)` is `g(h(x), 1)`. It stops at a ','
// and at the parentheses and the braces that hold it: `f(x |> g, 2)` is
// `f(g(x), 2)`. In a piece `name = value` of a call or of a record literal,
// it stops at the '=': `f(n = x |> g)` is `f(n = g(x))`. A segment that
// starts with `let` nests each value of a binding and the body.
//
// The placeholder `_` puts the value on the left in another place of the
// call on the right: `a |> f(b, _)` is `f(b, a)`
// (src/md/features/pipe_operator.md, "The placeholder `_`").
//
// This file finds each fault of the form of the operator, before any call,
// so that a line with such a fault runs nothing. It gives the console each
// stage of the line, with what is known of the value on its left, so that
// the console checks the names and the counts before the run too.

// The "|>" of one line. A line of the console has at most 200 bytes, and
// each "|>" with its name takes 3 bytes at least: 66 at most.
PIPE_STAGE_CAPACITY :: 128

// The groups that the pass over the placeholders keeps open at once: a
// group takes one byte at least, and a line of the history has 256 bytes at
// most.
PLACEHOLDER_GROUP_CAPACITY :: 256

// A fault of the form of the pipe operator.
Pipe_Refusal :: enum u8 {
	None                     = 0,
	No_Left_Value            = 1, // "|>" at the start of the line, or after "(", ",", "=" or an operator: no value on its left.
	Line_End                 = 2, // The line ends after "|>": no call on its right.
	Not_A_Call               = 3, // After "|>": no name, or a name and more after its call: a number, a text, "(", another "|>".
	Lone_Bar                 = 4, // A '|' with no '>' after it: no operator of the language.
	Unmatched_Close          = 5, // A ')' or a '}' that nothing opened, in a line with "|>": the parts of the operator have no border.
	Too_Many_Stages          = 6, // More "|>" than the memory of the stages holds.
	Too_Long                 = 7, // The nested form does not fit the memory that the caller gave.
	Placeholder_Not_Whole    = 8, // A '_' that is no whole argument of the call on the right: "f(_ + 1)", "f((_))", "f({a = _})". The call is at call_start.
	Placeholder_Twice        = 9, // Two '_' in one call on the right. The call is at call_start.
	Placeholder_Nested       = 10, // A '_' in a call inside the call on the right: the call on the right at call_start, the inner call at inner_start.
	Placeholder_Without_Pipe = 11, // A '_' with no "|>" before its call: on the left of "|>", or in a line with no "|>".
}

// What the console can know, before the run, of the value on the left of
// one "|>".
Pipe_Left_Form :: enum u8 {
	Other   = 0, // An expression: its kind is known when it runs.
	Integer = 1, // One integer literal that fits in an Integer.
	Text    = 2, // One text literal with its end quote.
	Name    = 3, // One name alone, at left_start:left_end: a variable, if one has the name.
	Call    = 4, // One call alone: the result of the command at left_start:left_end.
	Stage   = 5, // The result of the stage stage_before: the "|>" before this one.
}

// One "|>" of a line, and the call on its right. Each place is a byte of
// the line, not of its nested form.
Pipe_Stage :: struct {
	operator_start:       int, // The byte of '|' of "|>".
	name_start:           int, // The name of the command on the right ...
	name_end:             int, // ... and its end.
	argument_count:       int, // The arguments written in its parentheses, a '_' among them.
	arguments_start:      int, // The bytes inside its parentheses: from the byte after '(' ...
	arguments_end:        int, // ... to its ')'. A name with no parentheses has none.
	closed:               bool, // The call has its ')', or it is a name with no parentheses.
	left:                 Pipe_Left_Form, // What is known of the value on the left.
	left_start:           int, // Name and Call: the name ...
	left_end:             int, // ... and its end.
	stage_before:         int, // Stage: the index of the stage whose result is the value on the left.
	placeholder_start:    int, // The byte of its '_', or -1: with no '_', the value on the left is the first argument.
	placeholder_argument: int, // The argument of the '_', from 0, or -1.
	placeholder_named:    bool, // The '_' is the value of a named argument: its parameter is known when the call runs.
}

// The nested form of a line, or the fault of its form.
Pipe_Form :: struct {
	nested:      string, // The line with calls in calls: the line itself when it has no "|>".
	stage_count: int, // The stages written in the memory of the caller.
	refusal:     Pipe_Refusal,
	found_start: int, // The bytes of the line that the refusal names ...
	found_end:   int, // ... and their end.
	call_start:  int, // A refusal of a '_': the name of the call on the right ...
	call_end:    int, // ... and its end.
	inner_start: int, // Placeholder_Nested: the name of the call that holds the '_' ...
	inner_end:   int, // ... and its end.
}

// One '_' that the pass accepted: a whole argument of a call on the right
// of "|>".
Placeholder :: struct {
	call_name_start: int, // The name of the call on the right.
	start:           int, // The byte of the '_'.
	argument:        int, // Its argument, from 0.
	named:           bool, // It is the value of a named argument.
}

// The state of one writing of a nested form.
Pipe_Writer :: struct {
	text:              string,
	multiline:         bool,
	memory:            []u8,
	count:             int,
	stages:            []Pipe_Stage,
	stage_count:       int,
	refusal:           Pipe_Refusal,
	found_start:       int,
	found_end:         int,
	placeholders:      []Placeholder,
	placeholder_count: int,
}

// expression_start gives the first byte of the expression of a line: the
// byte after "name =" when the line keeps its value in a variable, else 0.
expression_start :: proc "contextless" (text: string) -> int {
	name := token_next(text, 0)
	if name.kind != .Name {
		return 0
	}
	equal := token_next(text, name.end)
	if equal.kind == .Operator && text[equal.start] == '=' && !(equal.end < len(text) && text[equal.end] == '=') {
		return equal.end
	}
	return 0
}

// pipe_before says if the token just before the byte place is "|>": the
// name at place is the call of a stage.
pipe_before :: proc "contextless" (text: string, place: int) -> bool {
	limit := clamp(place, 0, len(text))
	last := Token{}
	for token := token_next(text, 0); token.kind != .None && token.end <= limit; token = token_next(text, token.end) {
		last = token
	}
	return last.kind == .Pipe
}

// call_has_placeholder says if the call whose '(' is at open_place holds a
// top-level placeholder "_" inside its parentheses.
@(private)
call_has_placeholder :: proc "contextless" (text: string, open_place: int) -> bool {
	depth := 0
	for token := token_next(text, open_place + 1); token.kind != .None; token = token_next(text, token.end) {
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			if depth == 0 {
				return false
			}
			depth -= 1
		case depth == 0 && word_is(text, token, "_"):
			return true
		}
	}
	return false
}

// call_parameter_at_caret gives the name of the call open at caret_asked
// and the parameter index (from 0) that takes the argument at the caret.
// For a call on the right of "|>" that has no top-level "_", the value on
// the left takes parameter 0, so the argument at the caret takes parameter
// commas + 1. found is false in a comment, outside any call, inside a '('
// that no name precedes, or deeper than GROUP_DEPTH_MOST.
call_parameter_at_caret :: proc "contextless" (text: string, caret_asked: int) -> (name: string, parameter: int, found: bool) {
	caret := clamp(caret_asked, 0, len(text))
	if in_comment(text, caret) {
		return "", 0, false
	}
	groups: [GROUP_DEPTH_MOST]Open_Group
	depth, ok := groups_at(text, caret, &groups)
	if !ok || depth == 0 {
		return "", 0, false
	}
	call_depth := depth - 1
	for call_depth >= 0 && groups[call_depth].opener != .Parenthesis {
		call_depth -= 1
	}
	if call_depth < 0 {
		return "", 0, false
	}
	call := groups[call_depth]
	previous, before_name: Token
	for token := token_next(text, 0); token.kind != .None && token.end <= call.start; token = token_next(text, token.end) {
		before_name = previous
		previous = token
	}
	if previous.kind != .Name {
		return "", 0, false
	}
	parameter = call.commas
	if before_name.kind == .Pipe && !call_has_placeholder(text, call.start) {
		parameter += 1
	}
	return text[previous.start:previous.end], parameter, true
}

// word_is says if a token is a name with exactly the bytes of a word.
word_is :: proc "contextless" (text: string, token: Token, word: string) -> bool {
	return token.kind == .Name && text[token.start:token.end] == word
}

// opens and closes say if a token opens or closes a group: parentheses, the
// braces of a record literal and the brackets of a list.
@(private)
opens :: proc "contextless" (text: string, token: Token) -> bool {
	return token.kind == .Operator && (text[token.start] == '(' || text[token.start] == '{' || text[token.start] == '[')
}

@(private)
closes :: proc "contextless" (text: string, token: Token) -> bool {
	return token.kind == .Operator && (text[token.start] == ')' || text[token.start] == '}' || text[token.start] == ']')
}

// single_equal says if a token is "=" with no "=" after it: the "=" of a
// named argument, of a field, of a binding.
@(private)
single_equal :: proc "contextless" (text: string, token: Token) -> bool {
	return token.kind == .Operator && text[token.start] == '=' && !(token.end < len(text) && text[token.end] == '=')
}

// pipe_nested_form writes the line text in its nested form into memory,
// and each of its stages into stages. text[:first] is not an expression
// (the name and the '=' of a variable): it is copied as it is. A line with
// no "|>" is its own nested form, and nothing is written. A fault of the
// form gives a refusal and no nested form; the stages before the fault
// stay written.
pipe_nested_form :: proc "contextless" (text: string, first: int, memory: []u8, stages: []Pipe_Stage, multiline := false) -> (form: Pipe_Form) {
	start := clamp(first, 0, len(text))
	form.nested = text
	has_pipe := false
	depth := 0
	unmatched_close := -1
	for token := token_next(text, start, multiline); token.kind != .None; token = token_next(text, token.end, multiline) {
		switch token.kind {
		case .Pipe:
			has_pipe = true
		case .Unknown:
			// The one fault that a line with no "|>" has too: a '|'
			// alone says what was meant, before the parser reads it.
			if text[token.start] == '|' {
				form.nested = ""
				form.refusal, form.found_start, form.found_end = .Lone_Bar, token.start, token.end
				return form
			}
		case .Operator:
			if opens(text, token) {
				depth += 1
			} else if closes(text, token) {
				depth -= 1
				if depth < 0 && unmatched_close < 0 {
					unmatched_close = token.start
				}
			}
		case .None, .Name, .Number, .Text, .Text_Unfinished, .Arrow, .Member, .Function_Arrow, .Hash:
		}
	}
	// The placeholders, before any form is written: a '_' out of its place
	// fails the line before any call, also with no "|>".
	placeholders: [PIPE_STAGE_CAPACITY]Placeholder
	placeholder_count, placeholder_refusal := placeholders_find(text, start, placeholders[:], multiline)
	if placeholder_refusal.refusal != .None {
		placeholder_refusal.nested = ""
		return placeholder_refusal
	}
	if !has_pipe {
		return form
	}
	if unmatched_close >= 0 {
		form.nested = ""
		form.refusal, form.found_start, form.found_end = .Unmatched_Close, unmatched_close, len(text)
		return form
	}
	pipe_writer := Pipe_Writer {
		text              = text,
		multiline         = multiline,
		memory            = memory,
		stages            = stages,
		placeholders      = placeholders[:],
		placeholder_count = placeholder_count,
	}
	pipe_write(&pipe_writer, text[:start])
	pipe_segment_write(&pipe_writer, start, len(text))
	form.stage_count = pipe_writer.stage_count
	if pipe_writer.refusal != .None {
		form.nested = ""
		form.refusal, form.found_start, form.found_end = pipe_writer.refusal, pipe_writer.found_start, pipe_writer.found_end
		return form
	}
	form.nested = string(pipe_writer.memory[:pipe_writer.count])
	return form
}

// ---- The placeholders.

// The kinds of a group of the pass over the placeholders.
@(private)
Group_Kind :: enum u8 {
	Parentheses = 0, // "(" after no name: an expression in parentheses.
	Call        = 1, // A name and "(".
	Stage_Call  = 2, // A name after "|>", and "(": the call on the right of "|>".
	Braces      = 3, // "{": a record literal.
}

// One group that the pass keeps open, and the piece of its current
// argument: its tokens at the level of the group, and its '_'.
@(private)
Group :: struct {
	kind:              Group_Kind,
	name_start:        int,
	name_end:          int,
	argument:          int, // The argument of the piece, from 0.
	lets:              int, // The `let` of the piece whose `in` has not come: a ',' inside them is no border of a piece.
	piece_tokens:      int, // The tokens of the piece at the level of the group.
	first_is_name:     bool, // The first token of the piece is a name, not a '_'.
	named_prefix:      bool, // The second token of the piece is a single "=".
	placeholder:       int, // The byte of the first '_' of the piece at this level, or -1.
	placeholder_token: int, // The place of that '_' among the tokens of the piece, from 1.
	placeholders:      int, // The '_' accepted in this call.
}

// placeholders_find walks the tokens of the expression from start, keeps
// each group that is open, and gives each '_' to the innermost group that
// holds it. It gives the '_' accepted, or the first refusal.
@(private)
placeholders_find :: proc "contextless" (text: string, start: int, into: []Placeholder, multiline := false) -> (count: int, form: Pipe_Form) {
	groups: [PLACEHOLDER_GROUP_CAPACITY]Group
	depth := 0
	before, two_before: Token // The two tokens before this one.
	for token := token_next(text, start, multiline); token.kind != .None; token = token_next(text, token.end, multiline) {
		defer {
			two_before, before = before, token
		}
		top: ^Group = depth > 0 ? &groups[depth - 1] : nil
		switch {
		case opens(text, token):
			if top != nil {
				group_token_add(text, top, token)
			}
			if depth == len(groups) {
				form.refusal, form.found_start, form.found_end = .Too_Long, 0, len(text)
				return count, form
			}
			group := Group {
				kind        = .Braces,
				placeholder = -1,
			}
			if text[token.start] == '(' {
				group.kind = .Parentheses
				if before.kind == .Name && before.end <= token.start {
					group.kind = two_before.kind == .Pipe ? .Stage_Call : .Call
					group.name_start, group.name_end = before.start, before.end
				}
			}
			groups[depth] = group
			depth += 1
		case closes(text, token):
			if top == nil {
				continue
			}
			if !piece_end(text, groups[:depth], into, &count, &form) {
				return count, form
			}
			depth -= 1
		case token.kind == .Operator && text[token.start] == ',' && top != nil && top.lets == 0:
			if !piece_end(text, groups[:depth], into, &count, &form) {
				return count, form
			}
			top.argument += 1
			top.piece_tokens, top.first_is_name, top.named_prefix, top.placeholder, top.placeholder_token = 0, false, false, -1, 0
		case word_is(text, token, "_") && before.kind != .Pipe:
			if top == nil {
				form.refusal, form.found_start, form.found_end = .Placeholder_Without_Pipe, token.start, token.end
				return count, form
			}
			// A second '_' of the piece makes it no whole argument: the
			// count of its tokens says so.
			if top.placeholder < 0 {
				top.placeholder, top.placeholder_token = token.start, top.piece_tokens + 1
			}
			group_token_add(text, top, token)
		case:
			if top != nil {
				group_token_add(text, top, token)
			}
		}
	}
	// A group that the line does not close ends with the line.
	for depth > 0 {
		if !piece_end(text, groups[:depth], into, &count, &form) {
			return count, form
		}
		depth -= 1
	}
	return count, form
}

// group_token_add counts a token of the piece of a group at its level, and
// the `let` and `in` that hide the commas of their bindings.
@(private)
group_token_add :: proc "contextless" (text: string, group: ^Group, token: Token) {
	group.piece_tokens += 1
	switch group.piece_tokens {
	case 1:
		group.first_is_name = token.kind == .Name && !word_is(text, token, "_")
	case 2:
		group.named_prefix = single_equal(text, token)
	}
	if word_is(text, token, "let") {
		group.lets += 1
	} else if word_is(text, token, "in") && group.lets > 0 {
		group.lets -= 1
	}
}

// piece_end decides the '_' of the piece of the innermost group, when its
// piece ends: at a ',', at its close, at the end of the line.
@(private)
piece_end :: proc "contextless" (text: string, groups: []Group, into: []Placeholder, count: ^int, form: ^Pipe_Form) -> bool {
	group := &groups[len(groups) - 1]
	if group.placeholder < 0 {
		return true
	}
	place := group.placeholder
	group.placeholder = -1
	// Whole: the '_' alone, or the value of `name = _`.
	alone := group.piece_tokens == 1
	named := group.piece_tokens == 3 && group.placeholder_token == 3 && group.first_is_name && group.named_prefix
	whole := alone || named
	if group.kind == .Stage_Call {
		if !whole {
			form.refusal, form.found_start, form.found_end = .Placeholder_Not_Whole, place, place + 1
			form.call_start, form.call_end = group.name_start, group.name_end
			return false
		}
		group.placeholders += 1
		if group.placeholders > 1 {
			form.refusal, form.found_start, form.found_end = .Placeholder_Twice, place, place + 1
			form.call_start, form.call_end = group.name_start, group.name_end
			return false
		}
		if count^ < len(into) {
			into[count^] = {call_name_start = group.name_start, start = place, argument = group.argument, named = named}
			count^ += 1
		}
		return true
	}
	// Not the call on the right: a call on the right that holds the group
	// owns the place of the value, and this '_' is no whole argument of it.
	for index := len(groups) - 2; index >= 0; index -= 1 {
		holder := groups[index]
		if holder.kind != .Stage_Call {
			continue
		}
		form.found_start, form.found_end = place, place + 1
		form.call_start, form.call_end = holder.name_start, holder.name_end
		if group.kind == .Call {
			form.refusal = .Placeholder_Nested
			form.inner_start, form.inner_end = group.name_start, group.name_end
		} else {
			form.refusal = .Placeholder_Not_Whole
		}
		return false
	}
	form.refusal, form.found_start, form.found_end = .Placeholder_Without_Pipe, place, place + 1
	return false
}

// ---- The writing.

// pipe_refuse keeps the first fault: a later one changes nothing.
pipe_refuse :: proc "contextless" (pipe_writer: ^Pipe_Writer, refusal: Pipe_Refusal, start, end: int) {
	if pipe_writer.refusal == .None {
		pipe_writer.refusal, pipe_writer.found_start, pipe_writer.found_end = refusal, start, end
	}
}

// pipe_write adds bytes to the nested form.
pipe_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, bytes: string) {
	if pipe_writer.refusal != .None {
		return
	}
	if len(bytes) > len(pipe_writer.memory) - pipe_writer.count {
		pipe_refuse(pipe_writer, .Too_Long, 0, len(pipe_writer.text))
		return
	}
	copy(pipe_writer.memory[pipe_writer.count:], bytes)
	pipe_writer.count += len(bytes)
}

// pipe_trim gives text[start:end] without its spaces at both ends.
pipe_trim :: proc "contextless" (text: string, start, end: int, multiline := false) -> (first, last: int) {
	first = min(space_end(text, start, multiline), end)
	last = end
	for last > first {
		c := text[last - 1]
		if c == ' ' || (multiline && (c == '\t' || c == '\r' || c == '\n')) {
			last -= 1
		} else {
			break
		}
	}
	return first, last
}

// pipe_group_close gives the ')' or the '}' of the group that opens just
// before from, before limit. closed is false when the group does not close
// before limit: it then runs to limit.
pipe_group_close :: proc "contextless" (text: string, from, limit: int, multiline := false) -> (close: int, closed: bool) {
	depth := 1
	for token := token_next(text, from, multiline); token.kind != .None && token.start < limit; token = token_next(text, token.end, multiline) {
		if opens(text, token) {
			depth += 1
		} else if closes(text, token) {
			depth -= 1
			if depth == 0 {
				return token.start, true
			}
		}
	}
	return limit, false
}

// pipe_next_operator gives the first "|>" outside parentheses and braces in
// text[from:end], or end.
pipe_next_operator :: proc "contextless" (text: string, from, end: int, multiline := false) -> int {
	depth := 0
	for token := token_next(text, from, multiline); token.kind != .None && token.start < end; token = token_next(text, token.end, multiline) {
		switch {
		case token.kind == .Pipe:
			if depth == 0 {
				return token.start
			}
		case opens(text, token):
			depth += 1
		case closes(text, token):
			depth -= 1
		}
	}
	return end
}

// piece_comma says if a token is a ',' that ends a piece: outside
// parentheses and braces, and outside the bindings of a `let`.
@(private)
piece_comma :: proc "contextless" (text: string, token: Token, depth, lets: int) -> bool {
	return depth == 0 && lets == 0 && token.kind == .Operator && text[token.start] == ','
}

// pipe_argument_count gives the count of the arguments in text[start:end]:
// the ',' that end a piece, and one more; 0 when the bytes are spaces.
pipe_argument_count :: proc "contextless" (text: string, start, end: int, multiline := false) -> int {
	commas := 0
	depth := 0
	lets := 0
	written := false
	for token := token_next(text, start, multiline); token.kind != .None && token.start < end; token = token_next(text, token.end, multiline) {
		written = true
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			depth -= 1
		case depth == 0 && word_is(text, token, "let"):
			lets += 1
		case depth == 0 && word_is(text, token, "in") && lets > 0:
			lets -= 1
		case piece_comma(text, token, depth, lets):
			commas += 1
		}
	}
	return written ? commas + 1 : 0
}

// pipe_segment_write writes one segment: an expression with no ','
// outside parentheses, whose "|>" outside parentheses are its stages.
pipe_segment_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	if pipe_writer.refusal != .None {
		return
	}
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	// A `let` holds its own segments: the value of each binding, and the
	// body, which runs to the end of the segment.
	if first := token_next(text, start, multiline); first.start < end && word_is(text, first, "let") {
		pipe_let_write(pipe_writer, start, end)
		return
	}
	// An `if ... then ... else ...` holds three segments.
	if first := token_next(text, start, multiline); first.start < end && word_is(text, first, "if") {
		pipe_if_write(pipe_writer, start, end)
		return
	}
	// A function holds its body: the head as it is, then the body nested.
	if first := token_next(text, start, multiline); first.start < end {
		if _, arrow_end, found := function_head(text, first.start, multiline); found && arrow_end <= end {
			pipe_write(pipe_writer, text[start:arrow_end])
			pipe_segment_write(pipe_writer, arrow_end, end)
			return
		}
	}
	first_operator := pipe_next_operator(text, start, end, multiline)
	if first_operator == end {
		pipe_group_copy(pipe_writer, start, end)
		return
	}
	left_start, left_end := pipe_trim(text, start, first_operator, multiline)
	if left_start == left_end {
		pipe_refuse(pipe_writer, .No_Left_Value, first_operator, first_operator + 2)
		return
	}
	// Each stage is read before any is written: the nested form writes the
	// name of the last stage first.
	first_stage := pipe_writer.stage_count
	operator := first_operator
	for operator < end {
		part_start := operator + 2
		part_end := pipe_next_operator(text, part_start, end, multiline)
		if pipe_writer.stage_count == len(pipe_writer.stages) {
			pipe_refuse(pipe_writer, .Too_Many_Stages, operator, operator + 2)
			return
		}
		stage := Pipe_Stage {
			operator_start       = operator,
			placeholder_start    = -1,
			placeholder_argument = -1,
		}
		if !pipe_stage_read(pipe_writer, &stage, part_start, part_end) {
			return
		}
		if pipe_writer.stage_count == first_stage {
			pipe_left_read(text, &stage, left_start, left_end, multiline)
		} else {
			stage.left, stage.stage_before = .Stage, pipe_writer.stage_count - 1
		}
		pipe_writer.stages[pipe_writer.stage_count] = stage
		pipe_writer.stage_count += 1
		operator = part_end
	}
	last_stage := pipe_writer.stage_count
	// The spaces before the segment stay: after "name =" and after a ','.
	pipe_write(pipe_writer, text[start:left_start])
	// The groups of the arguments add stages after last_stage: a copy of
	// each stage of this segment keeps its places.
	for index := last_stage - 1; index >= first_stage; index -= 1 {
		stage := pipe_writer.stages[index]
		pipe_write(pipe_writer, text[stage.name_start:stage.name_end])
		pipe_write(pipe_writer, "(")
		// The arguments before the '_', then the value on the left.
		if stage.placeholder_start >= 0 {
			pipe_pieces_write(pipe_writer, stage.arguments_start, stage.placeholder_start)
		}
	}
	pipe_group_copy(pipe_writer, left_start, left_end)
	for index in first_stage ..< last_stage {
		stage := pipe_writer.stages[index]
		if stage.placeholder_start >= 0 {
			pipe_pieces_write(pipe_writer, stage.placeholder_start + 1, stage.arguments_end)
		} else if stage.argument_count > 0 {
			pipe_write(pipe_writer, ", ")
			pipe_pieces_write(pipe_writer, stage.arguments_start, stage.arguments_end)
		}
		// A call with no ')' stays without one: the parser then says that
		// it is missing, as for the same line with calls in calls.
		if stage.closed {
			pipe_write(pipe_writer, ")")
		}
	}
}

// pipe_if_write writes a segment that starts with `if`: condition, then
// branch, and else branch each nested independently.
@(private)
pipe_if_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	if_word := token_next(text, start, multiline)
	pipe_write(pipe_writer, text[start:if_word.end])
	depth := 0
	nested_ifs := 0
	then_tok, else_tok: Token
	for token := token_next(text, if_word.end, multiline); token.kind != .None && token.start < end; token = token_next(text, token.end, multiline) {
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			depth -= 1
		case depth == 0 && word_is(text, token, "if"):
			nested_ifs += 1
		case depth == 0 && word_is(text, token, "then"):
			if nested_ifs == 0 && then_tok.kind == .None {
				then_tok = token
			}
		case depth == 0 && word_is(text, token, "else"):
			if nested_ifs > 0 {
				nested_ifs -= 1
			} else if then_tok.kind != .None && else_tok.kind == .None {
				else_tok = token
				break
			}
		}
	}
	if then_tok.kind == .None || else_tok.kind == .None {
		pipe_group_copy(pipe_writer, if_word.end, end)
		return
	}
	_, cond_end := pipe_trim(text, if_word.end, then_tok.start, multiline)
	pipe_segment_write(pipe_writer, if_word.end, cond_end)
	pipe_write(pipe_writer, text[cond_end:then_tok.end])
	_, then_end := pipe_trim(text, then_tok.end, else_tok.start, multiline)
	pipe_segment_write(pipe_writer, then_tok.end, then_end)
	pipe_write(pipe_writer, text[then_end:else_tok.end])
	pipe_segment_write(pipe_writer, else_tok.end, end)
}

// pipe_let_write writes a segment that starts with `let`: each binding
// `name = value` with its value nested, then `in` and the body nested. With
// no `in`, the rest is copied: the parser says that it is missing.
@(private)
pipe_let_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	let_word := token_next(text, start, multiline)
	pipe_write(pipe_writer, text[start:let_word.end])
	piece_start := let_word.end
	depth := 0
	lets := 0
	for token := token_next(text, let_word.end, multiline); token.kind != .None && token.start < end && pipe_writer.refusal == .None; token = token_next(text, token.end, multiline) {
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			depth -= 1
		case depth == 0 && word_is(text, token, "let"):
			lets += 1
		case depth == 0 && word_is(text, token, "in"):
			if lets > 0 {
				lets -= 1
				continue
			}
			// The spaces before `in` stay: a nested value ends with its ')'.
			_, value_end := pipe_trim(text, piece_start, token.start, multiline)
			pipe_named_piece_write(pipe_writer, piece_start, value_end)
			pipe_write(pipe_writer, text[value_end:token.end])
			pipe_segment_write(pipe_writer, token.end, end)
			return
		case piece_comma(text, token, depth, lets):
			pipe_named_piece_write(pipe_writer, piece_start, token.start)
			pipe_write(pipe_writer, ",")
			piece_start = token.end
		}
	}
	pipe_group_copy(pipe_writer, piece_start, end)
}

// pipe_stage_read reads the call on the right of one "|>": the bytes
// text[part_start:part_end], up to the next "|>" or the end of the
// segment. It gives false, with the fault, when they are no call.
pipe_stage_read :: proc "contextless" (pipe_writer: ^Pipe_Writer, stage: ^Pipe_Stage, part_start, part_end: int) -> bool {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	name := token_next(text, part_start, multiline)
	if name.kind == .None || name.start >= part_end {
		if part_end >= len(text) {
			pipe_refuse(pipe_writer, .Line_End, stage.operator_start, stage.operator_start + 2)
		} else {
			// Another "|>", or the ')' or the ',' that ends the segment.
			next := token_next(text, part_end, multiline)
			pipe_refuse(pipe_writer, .Not_A_Call, next.start, next.end)
		}
		return false
	}
	_, trimmed_end := pipe_trim(text, part_start, part_end, multiline)
	if name.kind != .Name {
		pipe_refuse(pipe_writer, .Not_A_Call, name.start, trimmed_end)
		return false
	}
	stage.name_start, stage.name_end = name.start, name.end
	stage.arguments_start, stage.arguments_end = name.end, name.end
	stage.closed = true
	for placeholder in pipe_writer.placeholders[:pipe_writer.placeholder_count] {
		if placeholder.call_name_start == name.start {
			stage.placeholder_start, stage.placeholder_argument, stage.placeholder_named = placeholder.start, placeholder.argument, placeholder.named
		}
	}
	after := token_next(text, name.end, multiline)
	if after.kind == .Operator && text[after.start] == '(' && after.start < part_end {
		close, closed := pipe_group_close(text, after.end, part_end, multiline)
		stage.arguments_start, stage.arguments_end = after.end, close
		stage.argument_count = pipe_argument_count(text, after.end, close, multiline)
		stage.closed = closed
		if !closed {
			return true
		}
		after = token_next(text, close + 1, multiline)
	}
	if after.kind != .None && after.start < part_end {
		pipe_refuse(pipe_writer, .Not_A_Call, name.start, trimmed_end)
		return false
	}
	return true
}

// pipe_left_read says what the value text[start:end] on the left of the
// first stage of a segment is, when one literal, one name or one call is
// all of it.
pipe_left_read :: proc "contextless" (text: string, stage: ^Pipe_Stage, start, end: int, multiline := false) {
	stage.left = .Other
	first := token_next(text, start, multiline)
	if first.end == end {
		switch first.kind {
		case .Number:
			if _, fits := number_value(text, first.start, first.end); fits {
				stage.left = .Integer
			}
		case .Text:
			stage.left = .Text
		case .Name:
			stage.left, stage.left_start, stage.left_end = .Name, first.start, first.end
		case .None, .Text_Unfinished, .Operator, .Arrow, .Unknown, .Pipe, .Member, .Function_Arrow, .Hash:
		}
		return
	}
	if first.kind != .Name {
		return
	}
	open := token_next(text, first.end, multiline)
	if open.kind != .Operator || text[open.start] != '(' {
		return
	}
	close, closed := pipe_group_close(text, open.end, end, multiline)
	if closed && close + 1 == end {
		stage.left, stage.left_start, stage.left_end = .Call, first.start, first.end
	}
}

// pipe_group_copy copies text[start:end] as it is, but the inside of each
// group of parentheses or braces, whose pieces can hold "|>".
pipe_group_copy :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	copied := start
	for token := token_next(text, start, multiline); token.kind != .None && token.start < end && pipe_writer.refusal == .None; token = token_next(text, token.end, multiline) {
		if !opens(text, token) {
			continue
		}
		pipe_write(pipe_writer, text[copied:token.end])
		close, closed := pipe_group_close(text, token.end, end, multiline)
		pipe_pieces_write(pipe_writer, token.end, close)
		if !closed {
			return
		}
		pipe_write(pipe_writer, text[close:close + 1])
		copied = close + 1
		token.end = close + 1
	}
	pipe_write(pipe_writer, text[copied:end])
}

// pipe_pieces_write writes the inside of a group: each piece between two
// ',' that end a piece is a segment, after its name and its "=" when it is
// a named argument, a field of a literal or a binding.
pipe_pieces_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	piece_start := start
	depth := 0
	lets := 0
	for token := token_next(text, start, multiline); token.kind != .None && token.start < end && pipe_writer.refusal == .None; token = token_next(text, token.end, multiline) {
		switch {
		case opens(text, token):
			depth += 1
		case closes(text, token):
			depth -= 1
		case depth == 0 && word_is(text, token, "let"):
			lets += 1
		case depth == 0 && word_is(text, token, "in") && lets > 0:
			lets -= 1
		case piece_comma(text, token, depth, lets):
			pipe_named_piece_write(pipe_writer, piece_start, token.start)
			pipe_write(pipe_writer, ",")
			piece_start = token.end
		}
	}
	pipe_named_piece_write(pipe_writer, piece_start, end)
}

// pipe_named_piece_write writes one piece: `name =` as it is and its value
// as a segment, or the whole piece as a segment.
@(private)
pipe_named_piece_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	multiline := pipe_writer.multiline
	name := token_next(text, start, multiline)
	equal := token_next(text, name.end, multiline)
	if name.kind == .Name && name.end <= end && equal.start < end && single_equal(text, equal) {
		pipe_write(pipe_writer, text[start:equal.end])
		pipe_segment_write(pipe_writer, equal.end, end)
		return
	}
	pipe_segment_write(pipe_writer, start, end)
}
