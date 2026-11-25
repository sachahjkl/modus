// Freestanding Lex formatting and linting helpers for the sandboxed
// declaration evaluator module (src/md/features/lex_tools.md).
package declaration_eval_module

import "modus:lex_parser"
import "modus:lex_tools"

// declaration_format_source formats a Lex declaration into caller-owned `out`.
declaration_format_source :: proc "contextless" (source: string, out: []u8) -> (written: int, err: lex_tools.Format_Error) {
	return lex_tools.lex_format(source, out)
}

// declaration_lint_source runs static Lex checks using caller-owned AST storage
// and diagnostic buffers.
declaration_lint_source :: proc "contextless" (
	source: string,
	storage: lex_parser.Tree_Storage,
	out: []lex_tools.Lint_Diagnostic,
) -> (count: int, truncated: bool) {
	return lex_tools.lex_lint_with_storage(source, storage, out)
}
