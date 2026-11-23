package console_language

// thin_arrow_function gives the parts of a function that a line wrote with
// "->" at arrow, as Lex writes it: the parameters before the "->", back to
// the start of the argument, and the body after it, to the "," or the
// closing bracket that ends the argument. `map(x, n -> n * n)` gives "n"
// and "n * n"; parameters in parentheses, `(a, b) -> a + b`, give "a, b".
// A part with no token gives an empty text: the caller then names the form
// with no parts of the line.
thin_arrow_function :: proc "contextless" (text: string, arrow: int) -> (parameters, body: string) {
	if arrow < 0 || arrow + 2 > len(text) || text[arrow:arrow + 2] != "->" {
		return "", ""
	}
	// The parameters: the tokens before the arrow, after the "(", "[", "{"
	// or "," that opens their argument. A group that closes before the
	// arrow is a part of the argument: its opening place is restored.
	ARGUMENT_STARTS_MOST :: 64
	starts: [ARGUMENT_STARTS_MOST]int
	depth := 0
	start := 0
	for token := token_next(text, 0); token.kind != .None && token.start < arrow; token = token_next(text, token.end) {
		if token.end - token.start != 1 {
			continue
		}
		switch text[token.start] {
		case '(', '[', '{':
			if depth < ARGUMENT_STARTS_MOST {
				starts[depth] = start
			}
			depth += 1
			start = token.end
		case ')', ']', '}':
			if depth > 0 {
				depth -= 1
				if depth < ARGUMENT_STARTS_MOST {
					start = starts[depth]
				}
			}
		case ',':
			start = token.end
		}
	}
	parameters = trim_spaces(text[start:arrow])
	if len(parameters) >= 2 && parameters[0] == '(' && parameters[len(parameters) - 1] == ')' {
		parameters = trim_spaces(parameters[1:len(parameters) - 1])
	}
	// The body: to the first "," or unmatched closing bracket at depth 0.
	end := len(text)
	depth = 0
	body_loop: for token := token_next(text, arrow + 2); token.kind != .None; token = token_next(text, token.end) {
		if token.end - token.start != 1 {
			continue
		}
		switch text[token.start] {
		case '(', '[', '{':
			depth += 1
		case ')', ']', '}':
			if depth == 0 {
				end = token.start
				break body_loop
			}
			depth -= 1
		case ',':
			if depth == 0 {
				end = token.start
				break body_loop
			}
		}
	}
	return parameters, trim_spaces(text[arrow + 2:end])
}

// trim_spaces gives a text with no space or tab at its ends.
@(private)
trim_spaces :: proc "contextless" (text: string) -> string {
	first, last := 0, len(text)
	for first < last && (text[first] == ' ' || text[first] == '\t') {
		first += 1
	}
	for last > first && (text[last - 1] == ' ' || text[last - 1] == '\t') {
		last -= 1
	}
	return text[first:last]
}
