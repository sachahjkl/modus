#+build !freestanding
#+build !modus
package console_language

import "core:testing"

// The parts of a function written with "->": no arrow at the place, the
// arrow at the edges of the line, a body with no token, then the forms of
// an argument, of a list item, of parameters in parentheses, and of a body
// with calls and brackets inside it.
@(test)
thin_arrow_function_gives_the_parameters_and_the_body :: proc(t: ^testing.T) {
	Case :: struct {
		text:       string,
		arrow:      int,
		parameters: string,
		body:       string,
	}
	cases := []Case {
		{"", 0, "", ""},
		{"n - > n", 2, "", ""},
		{"n -> n", -1, "", ""},
		{"n -> n", 5, "", ""},
		{"->", 0, "", ""},
		{"n ->", 2, "n", ""},
		{"-> n", 0, "", "n"},
		{"n -> n * n", 2, "n", "n * n"},
		{"map(x, n -> n * n)", 9, "n", "n * n"},
		{"map(x, n->n*n) + 1", 8, "n", "n*n"},
		{"[1, n -> f(n, 2), 3]", 6, "n", "f(n, 2)"},
		{"(a, b) -> a + b", 7, "a, b", "a + b"},
		{"map(f(x), (a) -> [a, a])", 14, "a", "[a, a]"},
		{"g(\"(\", n -> n)", 9, "n", "n"},
	}
	for item in cases {
		parameters, body := thin_arrow_function(item.text, item.arrow)
		testing.expectf(t, parameters == item.parameters && body == item.body, "%q at %d: %q and %q, not %q and %q", item.text, item.arrow, parameters, body, item.parameters, item.body)
	}
}
