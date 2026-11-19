package console_language

// The pipe operator of the console: `a |> f(b, c)` is `f(a, b, c)`, and
// `a |> f` is `f(a)`. The operator adds no meaning to a line: before any
// call, the console writes the line in its nested form here, and its parser
// reads that form as any other line, so a line with '|>' checks and runs as
// the same line with calls in calls (docs/CONSOLE.md, "The pipe operator").
//
// The operator has the lowest priority, below '+' and '-', and it chains
// from the left: `x |> h |> g(1)` is `g(h(x), 1)`. It stops at a ',' and at
// the parentheses that hold it: `f(x |> g, 2)` is `f(g(x), 2)`.
//
// This file finds each fault of the form of the operator, before any call,
// so that a line with such a fault runs nothing. It gives the console each
// stage of the line, with what is known of the value on its left, so that
// the console checks the names and the counts before the run too.

// The "|>" of one line. A line of the console has at most 200 bytes, and
// each "|>" with its name takes 3 bytes at least: 66 at most.
PIPE_STAGE_CAPACITY :: 128

// A fault of the form of the pipe operator.
Pipe_Refusal :: enum u8 {
	None            = 0,
	No_Left_Value   = 1, // "|>" at the start of the line, or after "(", ",", "=" or an operator: no value on its left.
	Line_End        = 2, // The line ends after "|>": no call on its right.
	Not_A_Call      = 3, // After "|>": no name, or a name and more after its call: a number, a text, "(", another "|>".
	Lone_Bar        = 4, // A '|' with no '>' after it: no operator of the language.
	Unmatched_Close = 5, // A ')' that no '(' opened, in a line with "|>": the parts of the operator have no border.
	Too_Many_Stages = 6, // More "|>" than the memory of the stages holds.
	Too_Long        = 7, // The nested form does not fit the memory that the caller gave.
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
	operator_start:  int, // The byte of '|' of "|>".
	name_start:      int, // The name of the command on the right ...
	name_end:        int, // ... and its end.
	argument_count:  int, // The arguments written in its parentheses: the value on the left comes before them.
	arguments_start: int, // The bytes inside its parentheses: from the byte after '(' ...
	arguments_end:   int, // ... to its ')'. A name with no parentheses has none.
	closed:          bool, // The call has its ')', or it is a name with no parentheses.
	left:            Pipe_Left_Form, // What is known of the value on the left.
	left_start:      int, // Name and Call: the name ...
	left_end:        int, // ... and its end.
	stage_before:    int, // Stage: the index of the stage whose result is the value on the left.
}

// The nested form of a line, or the fault of its form.
Pipe_Form :: struct {
	nested:      string, // The line with calls in calls: the line itself when it has no "|>".
	stage_count: int, // The stages written in the memory of the caller.
	refusal:     Pipe_Refusal,
	found_start: int, // The bytes of the line that the refusal names ...
	found_end:   int, // ... and their end.
}

// The state of one writing of a nested form.
Pipe_Writer :: struct {
	text:        string,
	memory:      []u8,
	count:       int,
	stages:      []Pipe_Stage,
	stage_count: int,
	refusal:     Pipe_Refusal,
	found_start: int,
	found_end:   int,
}

// expression_start gives the first byte of the expression of a line: the
// byte after "name =" when the line keeps its value in a variable, else 0.
expression_start :: proc "contextless" (text: string) -> int {
	name := token_next(text, 0)
	if name.kind != .Name {
		return 0
	}
	equal := token_next(text, name.end)
	if equal.kind == .Operator && text[equal.start] == '=' {
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

// pipe_nested_form writes the line text in its nested form into memory,
// and each of its stages into stages. text[:first] is not an expression
// (the name and the '=' of a variable): it is copied as it is. A line with
// no "|>" is its own nested form, and nothing is written. A fault of the
// form gives a refusal and no nested form; the stages before the fault
// stay written.
pipe_nested_form :: proc "contextless" (text: string, first: int, memory: []u8, stages: []Pipe_Stage) -> (form: Pipe_Form) {
	start := clamp(first, 0, len(text))
	form.nested = text
	has_pipe := false
	depth := 0
	unmatched_close := -1
	for token := token_next(text, start); token.kind != .None; token = token_next(text, token.end) {
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
			switch text[token.start] {
			case '(':
				depth += 1
			case ')':
				depth -= 1
				if depth < 0 && unmatched_close < 0 {
					unmatched_close = token.start
				}
			}
		case .None, .Name, .Number, .Text, .Text_Unfinished, .Arrow:
		}
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
		text   = text,
		memory = memory,
		stages = stages,
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
pipe_trim :: proc "contextless" (text: string, start, end: int) -> (first, last: int) {
	first = min(space_end(text, start), end)
	last = end
	for last > first && text[last - 1] == ' ' {
		last -= 1
	}
	return first, last
}

// pipe_group_close gives the ')' of the '(' that ends at from, before
// limit. closed is false when the parentheses do not close before limit:
// the group then runs to limit.
pipe_group_close :: proc "contextless" (text: string, from, limit: int) -> (close: int, closed: bool) {
	depth := 1
	for token := token_next(text, from); token.kind != .None && token.start < limit; token = token_next(text, token.end) {
		if token.kind != .Operator {
			continue
		}
		switch text[token.start] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				return token.start, true
			}
		}
	}
	return limit, false
}

// pipe_next_operator gives the first "|>" outside parentheses in
// text[from:end], or end.
pipe_next_operator :: proc "contextless" (text: string, from, end: int) -> int {
	depth := 0
	for token := token_next(text, from); token.kind != .None && token.start < end; token = token_next(text, token.end) {
		switch token.kind {
		case .Pipe:
			if depth == 0 {
				return token.start
			}
		case .Operator:
			switch text[token.start] {
			case '(':
				depth += 1
			case ')':
				depth -= 1
			}
		case .None, .Name, .Number, .Text, .Text_Unfinished, .Arrow, .Unknown:
		}
	}
	return end
}

// pipe_argument_count gives the count of the arguments in text[start:end]:
// the ',' outside parentheses, and one more; 0 when the bytes are spaces.
pipe_argument_count :: proc "contextless" (text: string, start, end: int) -> int {
	commas := 0
	depth := 0
	written := false
	for token := token_next(text, start); token.kind != .None && token.start < end; token = token_next(text, token.end) {
		written = true
		if token.kind != .Operator {
			continue
		}
		switch text[token.start] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 0 {
				commas += 1
			}
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
	first_operator := pipe_next_operator(text, start, end)
	if first_operator == end {
		pipe_group_copy(pipe_writer, start, end)
		return
	}
	left_start, left_end := pipe_trim(text, start, first_operator)
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
		part_end := pipe_next_operator(text, part_start, end)
		if pipe_writer.stage_count == len(pipe_writer.stages) {
			pipe_refuse(pipe_writer, .Too_Many_Stages, operator, operator + 2)
			return
		}
		stage := Pipe_Stage {
			operator_start = operator,
		}
		if !pipe_stage_read(pipe_writer, &stage, part_start, part_end) {
			return
		}
		if pipe_writer.stage_count == first_stage {
			pipe_left_read(text, &stage, left_start, left_end)
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
	for index := last_stage - 1; index >= first_stage; index -= 1 {
		pipe_write(pipe_writer, text[pipe_writer.stages[index].name_start:pipe_writer.stages[index].name_end])
		pipe_write(pipe_writer, "(")
	}
	pipe_group_copy(pipe_writer, left_start, left_end)
	for index in first_stage ..< last_stage {
		// The groups of the arguments add stages after last_stage: a copy
		// of each stage of this segment keeps its places.
		stage := pipe_writer.stages[index]
		if stage.argument_count > 0 {
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

// pipe_stage_read reads the call on the right of one "|>": the bytes
// text[part_start:part_end], up to the next "|>" or the end of the
// segment. It gives false, with the fault, when they are no call.
pipe_stage_read :: proc "contextless" (pipe_writer: ^Pipe_Writer, stage: ^Pipe_Stage, part_start, part_end: int) -> bool {
	text := pipe_writer.text
	name := token_next(text, part_start)
	if name.kind == .None || name.start >= part_end {
		if part_end >= len(text) {
			pipe_refuse(pipe_writer, .Line_End, stage.operator_start, stage.operator_start + 2)
		} else {
			// Another "|>", or the ')' or the ',' that ends the segment.
			next := token_next(text, part_end)
			pipe_refuse(pipe_writer, .Not_A_Call, next.start, next.end)
		}
		return false
	}
	_, trimmed_end := pipe_trim(text, part_start, part_end)
	if name.kind != .Name {
		pipe_refuse(pipe_writer, .Not_A_Call, name.start, trimmed_end)
		return false
	}
	stage.name_start, stage.name_end = name.start, name.end
	stage.arguments_start, stage.arguments_end = name.end, name.end
	stage.closed = true
	after := token_next(text, name.end)
	if after.kind == .Operator && text[after.start] == '(' && after.start < part_end {
		close, closed := pipe_group_close(text, after.end, part_end)
		stage.arguments_start, stage.arguments_end = after.end, close
		stage.argument_count = pipe_argument_count(text, after.end, close)
		stage.closed = closed
		if !closed {
			return true
		}
		after = token_next(text, close + 1)
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
pipe_left_read :: proc "contextless" (text: string, stage: ^Pipe_Stage, start, end: int) {
	stage.left = .Other
	first := token_next(text, start)
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
		case .None, .Text_Unfinished, .Operator, .Arrow, .Unknown, .Pipe:
		}
		return
	}
	if first.kind != .Name {
		return
	}
	open := token_next(text, first.end)
	if open.kind != .Operator || text[open.start] != '(' {
		return
	}
	close, closed := pipe_group_close(text, open.end, end)
	if closed && close + 1 == end {
		stage.left, stage.left_start, stage.left_end = .Call, first.start, first.end
	}
}

// pipe_group_copy copies text[start:end] as it is, but the inside of each
// pair of parentheses, whose pieces can hold "|>".
pipe_group_copy :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	copied := start
	for token := token_next(text, start); token.kind != .None && token.start < end && pipe_writer.refusal == .None; token = token_next(text, token.end) {
		if token.kind != .Operator || text[token.start] != '(' {
			continue
		}
		pipe_write(pipe_writer, text[copied:token.end])
		close, closed := pipe_group_close(text, token.end, end)
		pipe_pieces_write(pipe_writer, token.end, close)
		if !closed {
			return
		}
		pipe_write(pipe_writer, ")")
		copied = close + 1
		token.end = close + 1
	}
	pipe_write(pipe_writer, text[copied:end])
}

// pipe_pieces_write writes the inside of a pair of parentheses: each piece
// between two ',' outside inner parentheses is a segment.
pipe_pieces_write :: proc "contextless" (pipe_writer: ^Pipe_Writer, start, end: int) {
	text := pipe_writer.text
	piece_start := start
	depth := 0
	for token := token_next(text, start); token.kind != .None && token.start < end && pipe_writer.refusal == .None; token = token_next(text, token.end) {
		if token.kind != .Operator {
			continue
		}
		switch text[token.start] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 0 {
				pipe_segment_write(pipe_writer, piece_start, token.start)
				pipe_write(pipe_writer, ",")
				piece_start = token.end
			}
		}
	}
	pipe_segment_write(pipe_writer, piece_start, end)
}
