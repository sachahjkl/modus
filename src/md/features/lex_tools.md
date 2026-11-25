# Canonical Lex formatter and static linter

## Purpose

Lex declarations (`project.lex`, `pins.lex`, and system plans) are content-addressed inputs whose hashes decide builds and deployments. A canonical formatter removes layout drift across edits, and a static linter catches dead bindings, shadowing, duplicate fields, redundant parentheses, and malformed constructs before evaluation runs.

## Constraints

- The formatting and linting core lives in `src/library/modus/lex_tools/` as a freestanding, zero-allocation package (`"contextless"`). Every output buffer and diagnostic array is supplied by the caller so the same code runs inside `modus` modules (`edit`, `declaration_eval`) and inside `modustool` on the host.
- The formatter preserves every comment (`// ...`), string literal (including escapes and `${...}` interpolations), hash literal (`blake3:...`), and numeric unit suffix (`64 MiB`, `500 ms`).
- Formatting is strictly idempotent: formatting an already formatted document produces the exact same bytes (`format(format(x)) == format(x)`).
- Neither tool performs I/O, network calls, or evaluation side effects.
- Every bound in the core is explicit and documented by kind (format property, plan value, or inline capacity with a caller-supplied tier past it).

## Chosen form

### Canonical formatting (`format.odin`)

The formatter reads the source with `modus:console_language.token_next` and `comment_starts` / `comment_end` so scanning agrees with the Lex parser and highlighter on every token boundary. Adjacent two-byte comparison operators (`<=`, `>=`, `!=`) are coalesced before spacing so `a <= b` never splits into `a < = b`.

Canonical layout rules:

- **Indentation:** 2 spaces per multi-line nesting level (`{ ... }`, `[ ... ]`, `let ... in` bindings), plus one continuation level for a line that starts with `|>`.
- **Spacing:** Single spaces around binary operators (`=`, `!=`, `<`, `<=`, `>`, `>=`, `+`, `-`, `*`, `/`, `%`, `++`, `&&`, `||`, `??`, `|>`, `=>`, `@`, `with`, `in`, `then`, `else`), after `,` and `:`, and between a number and its unit suffix (`64 MiB`). No space before `,`, `:`, `)`, or `]`, after `(` or `[`, after unary `-` or `!`, before call `(` or index `[` after a non-keyword name, or before postfix `.field` after `)`, `]`, `}`, or a non-keyword name. Single space inside non-empty single-line `{ a = 1 }`; empty containers collapse to `{}`, `[]`, and `()`.
- **Record field order:** Preserved in source order so attached comments and author grouping remain intact.
- **Multi-line blocks:** A `{ ... }` or `[ ... ]` block formats multi-line if it contains a comment, already contains a newline and is non-empty, or exceeds the 100-byte single-line width target. Because the width estimate depends only on the block's tokens and not on input whitespace, single-line and multi-line decisions are stable across repeated passes.
- **Line endings and blank lines:** Trailing spaces on every line (including comments) are removed. Multiple consecutive blank lines collapse to at most one, and blank lines immediately after an opener or before a closer are dropped. Non-empty output ends with one `\n`; empty or whitespace-only input produces zero bytes.
- **Refusals:** Unterminated strings, unknown bytes, unmatched or unclosed delimiters, nesting past `FORMAT_DEPTH_LIMIT`, inputs past `DECLARATION_TEXT_BYTES_MOST`, and undersized output buffers return a closed `Format_Error` without claiming partial output.

### Static linter (`lint.odin`)

The linter runs two complementary passes over caller-owned buffers and reports structured `Lint_Diagnostic` records (`Lint_Kind`, `Lint_Severity`, 1-based line/column, byte span, and offending name):

1. **Streaming token pass:** Flags empty or comment-only inputs (`Empty_Expression`), unfinished strings, unknown bytes, malformed `blake3:...` hashes (`Malformed_Token`), empty or missing pipe targets (`Empty_Pipe_Target`), and unambiguously redundant parentheses (`((expr))` or a single-atom non-call, non-lambda `(atom)` -> `Redundant_Parentheses`).
2. **AST pass (`lex_parser.parse_declaration`):** Flags duplicate record fields (`Duplicate_Record_Field`), parse refusals not already reported by the token pass (`Parse_Error`), empty records (`Empty_Record`), empty lists (`Empty_List`), `let` bindings that shadow an enclosing binding or parameter (`Shadowed_Binding`), and `let` bindings never referenced in their sibling bindings or body (`Unused_Binding`).

`lex_lint` uses a 512-node inline stack workspace for small snippets and falls back to the token pass if a larger file fills the inline tier; `lex_lint_with_storage` accepts caller-allocated `lex_parser.Tree_Storage` so `modustool lex lint` and arena-backed modules lint arbitrarily large files without hitting the inline cap.

### Host CLI (`tools/modustool/lex_cli/`)

`modustool lex fmt [--check] <file>...` formats one or more `.lex` files in place (or exits with status 1 if any file differs under `--check`). `modustool lex lint <file>...` prints `path:line:column: severity: kind: message` diagnostics and exits with status 1 when any diagnostic is reported. See [`docs/LEX.md`](../../../docs/LEX.md), "9. Formatting and linting (`modustool lex`)".

## Refused forms

- **Regex or line-by-line formatting:** Fails on string interpolations (`"${a + b}"`), comments containing quotes or braces, and nested expressions.
- **Sorting record fields during formatting:** Moving fields across inline or leading comments breaks comment ownership and surprises authors who group fields logically (`source`, `inputs`, `outputs`, `console`). Canonical sorted order belongs in the evaluator's `Record_Shape` and `pins.lex` writer, not in a general source formatter.
- **Heap allocation inside `modus:lex_tools`:** Modules of `modus` have no ambient heap allocator; keeping the core caller-buffered allows one implementation across host tools and in-OS modules.
- **Duplicate scanner tables:** Re-implementing tokenization risks drift from `console_language` and `lex_parser`.

## Subtle points and hazards

- **Two-byte comparison operators:** `console_language.token_next` emits `<`, `>`, `!`, and `=` as 1-byte `.Operator` tokens. The formatter coalesces adjacent `<=`, `>=`, and `!=` only when `next.start == prev.end`.
- **Unary versus binary `-`:** Determined strictly from whether the previous non-comment token can end an expression (`.Number`, `.Text`, `.Hash`, `.Member`, closing delimiter, or non-keyword `.Name`). Keywords such as `then`, `else`, `in`, and `with` are not expression enders, so `if c then -1 else -2` keeps unary `-` tight.
- **Dotted names and calls in unused-binding analysis:** `lex_parser` stores `cfg.port` as one `.Name` token and `f(x)` as a `.Call` node without a child `.Name`. The linter extracts the root identifier before the first `.` on both `.Name` and `.Call` nodes so `let f = ... in f(1)` and `let cfg = ... in cfg.port` mark their bindings used.
- **Mutual visibility in `let`:** All bindings of one `let` block are visible to each sibling binding's RHS as well as the body, matching `lex_parser` and `lex_evaluator`.
- **Bounded diagnostic output:** When `len(out)` fills, `lex_lint` stops appending and sets `truncated = true` instead of dropping diagnostics silently.

## State

Built: freestanding formatter (`format.odin`), static linter (`lint.odin`), host unit tests (`lex_tools_test.odin`), host CLI (`tools/modustool/lex_cli/`), and guide section in `docs/LEX.md`.
Left: wiring editor keybindings in `edit` to invoke the in-OS formatter helper on demand.
