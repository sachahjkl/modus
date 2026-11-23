# The pipe operator of the console

`a |> f(b, c)` is `f(a, b, c)`: the value on the left is the first argument of the call on the right. `a |> f` is `f(a)`. `a |> f(b, _, c)` is `f(b, a, c)`: the placeholder `_` puts the value in another place. It chains from the left: `x |> h |> g(1) |> f` is `f(g(h(x), 1))`. The guide is [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "The pipe operator".

## Purpose

A frequent task of the console is a chain of calls: a table, then a filter, then the columns. With calls in calls, the reader reads it from the inside out, and the name of the last call is the first word of the line. With `|>`, the line reads in the order in which its calls run, which property 22 asks for: `processes() |> where(name = "server") |> columns(name, slot)`. The designs of the log facts and of the record outputs write their frequent tasks with it ([log_facts.md](log_facts.md), [module_outputs.md](module_outputs.md)).

## Constraints

- **Sugar only.** The operator adds no meaning and no kind. A line with `|>` checks and runs as the same line with calls in calls, with the same errors.
- **A refused line runs nothing.** A fault of the operator is found before the first call: a call has effects, and the console cannot undo them.
- **One parser.** The console has one parser of its expressions and one check of a call; the operator gives them no second path.

## The chosen form

**The lowest priority, from the left.** The whole expression on the left is the value: `1 + 2 |> text` is `text(1 + 2)`. A `,` and the parentheses that hold it end it, so `|>` works inside an argument: `where(x |> f, a = 1)`. On the right: the name of a command, alone or with its arguments.

**Native `|>` in the parser.** `src/library/modus/lex_parser/lex_parser.odin` parses `|>` directly as a left-associative binary `Pipe` node (`a |> f(b, c)`), with no string-rewrite pass before parsing. The parser tracks whether each call is on the right of `|>` and passes `Form_Lookup.arg_offset` (`1` when the piped value takes argument 0, `0` when an explicit `_` fills another argument position) so special-form argument parsing (`where`, `columns`) matches nested calls identically. The bytecode compiler lowers `Pipe` straight to the same call sequence as nested calls, so equivalence holds by construction and original source byte offsets stay intact for diagnostics.

**The check before the run.** The parser validates the form of `|>` and `_` before evaluation runs, and the console checks each piped stage before any call runs:

- the form of the operator, in the parser: no value on the left, nothing on the right, a right part that is no name or no call, a `|` alone, a `)` that no `(` opened;
- each name on the right, from the last stage to the first;
- the count of the arguments: a command that takes none, a call with 12 arguments already, another count;
- the first parameter, when the console knows the value on the left before the run (`Left_Knowledge`): a literal, a variable, the result of an export, whose description gives its record, and a result of the kind Integer, Text or none. The sentence is the sentence of the same line with calls in calls, from the same procedure (`argument_accepted`).

**The completion after `|>`.** The list offers the commands that take an argument and whose first parameter takes the value on the left, from the same knowledge. The console reads the line up to the `|>`, with a name of one byte in the place of the typed one, so the name being typed does not change the value on the left. When it does not know the value, it offers each command that takes an argument.

**The placeholder `_`.** In `a |> f(b, _, c)`, the value on the left takes the place of `_`: it is `f(b, a, c)`. With no `_`, the value stays the first argument. So a command that takes its subject in another place reads in the order of its data: `compile(src, t) |> bytes(t, 0, _) |> assemble(f)` is `assemble(bytes(t, 0, compile(src, t)), f)`. The rules, each checked by the parser before any call:

- `_` is a whole argument of the call on the right of `|>`: a positional argument, or the value of a named argument (`f(count = _)`). `f(_ + 1)` is refused: `error: |>: _ is a whole argument of f, not a part of an expression`. A `_` in a group `f((_))` or in a record literal `f({a = _})` is a part of an expression too. An expression around the value is a function, which comes with layer 4 of [declarations.md](declarations.md), "The build order".
- At most one `_` in that call. Two are refused: `error: |>: f has two _; the value on the left takes one place`.
- A `_` outside the right side of a `|>` is refused: on the left of `|>`, and in a line with no `|>`: `error: _ is a place of the call on the right of |>; this call has no |> before it`.
- A `_` inside a call nested in the call on the right is refused: `f(g(_))`, and `_` in the body of a function. `error: |>: _ names an argument of f, not of g inside it`.
- `_` alone is no name: a variable or a field named `_` is refused. A name that holds `_`, such as `sum_values`, is a name.

The compiler inserts the left value at the `_` argument index (or index 0 when absent). The count of the arguments counts `_` as one: `f(b, _, c)` passes 3 arguments, `f(b, c)` with no `_` passes 3 too. The check of the first parameter becomes the check of the parameter at `_`, from the same `Left_Knowledge`; a `_` that is the value of a named argument has its parameter checked when the call runs.

**How the `_` are found.** The parser tracks the current pipe-target call while parsing arguments. A `_` directly as a call argument binds to that pipe-target call (at most once). A `_` inside an expression, nested call, group, list, record literal, or function body inside a pipe-target call is refused with `Placeholder_Not_Whole` or `Placeholder_Nested`; a `_` with no enclosing pipe-target call is refused with `Placeholder_Without_Pipe`. A `_` right after `|>`, in the place of the name of the call, is refused as a reserved name. So a `_` inside an inner `x |> g(_)` belongs to `g`, with no separate rewrite pass.

**A function and a list.** Because `|>` is a normal expression operator in `lex_parser`, it works directly inside function bodies (`map(l, (x) => x |> g)`), list elements (`[a |> f, b]`), `let` bindings, record literals, and named arguments, with original source spans preserved.

**Why `_` names a place of the call on the right only.** Each `|>` then has one place, which a reader finds in the call that follows it. A `_` in a nested call `f(g(_))` hides that the value goes through `g` first, and a `_` in `g` that a `|>` inside an argument also owns would need a rule of scope. The order of the data says it with no rule: `x |> g(_) |> f(_)`. An expression around the value is a function: `x |> ((v) => f(v + 1))`.

**Why `|>`, and not `|`.** `|>` has no other meaning in Lex, so a reader and the parser never take it for another operator, and `|` stays free for a union of sets. The arrow reads as "goes to". Elixir, Gleam and R give the same sign this meaning. F#, where the sign comes from, gives the value to a function of one argument: `x |> f a` is `f a x` there, with the value last; the console has no curried call, so the first argument is the one place that reads as the line.

## The refused forms

- **`|`.** It reads as a pipe of text between processes, which property 19 refuses, and it takes the sign that a union of sets needs.
- **The value as the last argument**, as in F#. The commands of the console take their subject first (`where(table, ...)`, `columns(table, ...)`), so the last place would need the arguments of each command in another order. A command that takes its subject elsewhere takes `_`.
- **Functions only, for a place other than the first.** `compile(src, t) |> ((n) => bytes(t, 0, n)) |> assemble(f)` names a value that the line already says, and puts a function in a frequent task.
- **Several placeholders (`_1`, `_2`) or two `_` in one call.** One value on the left fills one place; a second place is a `let`.
- **`_` in a nested call or inside an expression.** The place of the value then hides in the depth of the call ("Why `_` names a place of the call on the right only").
- **A separate string-rewrite pass before the parser.** Rewriting `a |> f(b)` into a scratch buffer before lexing destroyed source byte offsets for diagnostics and added a second tokenizer pass over the input.
- **A check during the run only.** The left part would run before a fault of the right part: `processes() |> help` would connect to `monitor` and then fail.
- **A check of each kind before the run.** A built-in command makes the description of its table when it runs; a check before the run would need a second description of each one. The call checks it then, after the left part ran, with the sentence of the nested form.

## Subtle points

- **Two faults in one line** can give another first error than the nested form: the check before the run finds the faults that it knows first. A line with one fault gives the error of the nested form, or a sentence of the operator.
- **An error that quotes the line** (`unexpected "..."`) quotes the original source line at its exact byte span.
- **A `|` alone fails each line**, also a line with no `|>`: it was an unknown byte, and its line failed after the part before it ran.
- **A call with no `)`** is reported directly by the parser at the missing closing parenthesis.
- **`_` and the order of the effects.** The line means its nested form, and an export forces its arguments from the left to the right ([declarations.md](declarations.md), "One parser, one lazy evaluator, two modes"). So in `x() |> f(g(), _)`, which is `f(g(), x())`, `g()` runs before `x()`, though `x()` is written first. With no `_`, or with `_` first, the value on the left runs first. A line whose effects must run in the order of its text puts `_` first, or names the value with `let`.
- **The hint line** under the edit line uses `console_language.call_parameter_at_caret`: for a call on the right of `|>` without a top-level placeholder `_`, the value on the left takes parameter 0, so the hint marks parameter `commas + 1`. When a top-level `_` is present in the call, the piped value fills `_` and no extra shift applies.

## State

Built: the operator for the calls of today (tables, records, exports), its refusals, its completion, its hint line parameter marking and its colors (an Operator); the placeholder `_` with its four refusals; the nested form of a named argument, of a record literal and of a `let` ([declarations.md](declarations.md), "The forms of layer 3 as built"), and of the body of a function and the items of a list ([declarations.md](declarations.md), "The functions of layer 4 as built"). Left: the Stream of the record outputs, which takes `|>` as each value does; the completion after `|>` of the commands that take the value at the place of a `_`.
