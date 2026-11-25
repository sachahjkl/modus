// Freestanding Lex formatting and linting helpers for the in-OS editor
// (src/md/features/lex_tools.md).
package edit

import "modus:lex_tools"

// edit_format_lex_buffer formats a Lex text buffer into `out` using canonical
// spacing and 2-space indentation.
edit_format_lex_buffer :: proc "contextless" (source: string, out: []u8) -> (written: int, err: lex_tools.Format_Error) {
	return lex_tools.lex_format(source, out)
}

// edit_lint_lex_buffer collects static Lex diagnostics for an open declaration
// buffer into caller-owned `out`.
edit_lint_lex_buffer :: proc "contextless" (source: string, out: []lex_tools.Lint_Diagnostic) -> (count: int, truncated: bool) {
	return lex_tools.lex_lint(source, out)
}
