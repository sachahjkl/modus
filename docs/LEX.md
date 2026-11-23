# Lex: the language and runtime of modus

Lex is the one language of `modus` for both interactive console lines and pure declarative `.lex` files. One parser and one lazy evaluator execute both forms in two evaluation modes, and text always stops at the evaluator border.

## About this guide

**The idea in plain words.** A principal types expressions in the console and writes system or project declarations in `.lex` files using one language. Commands are typed functions, never text pipelines. Every value has a checked kind, every refusal carries a source place and a reason, and no process parses text sent by another process.

**For whom.** A principal who runs commands or writes plans and projects, and a developer who works on `src/library/modus/lex_parser`, `src/library/modus/lex_evaluator`, `src/library/modus/contract/declaration_eval`, or `src/modules/system/declaration_eval`.

**Read before.** `docs/PROPERTIES.md`, "19. A command is a function: no text between processes", and `docs/CONSOLE.md`, "Lex". The terms Lex, syntax tree, evaluation mode, thunk, record literal, named argument, anonymous function, evaluation budget, and evaluation stack bound are in `docs/glossary/desktop.md`; plan, applied plan, declaration, pin, recipe, and project are in `docs/glossary/code.md`; pipe operator, placeholder, condition, record stream, wiring, and body region are in `docs/glossary/communication.md`.

## 1. What Lex is: one language, two evaluation modes

One grammar, one parser (`src/library/modus/lex_parser`), and one lazy evaluator (`src/library/modus/lex_evaluator`) serve all of Lex. The evaluator runs in one of two closed evaluation modes (`lex_evaluator.Evaluation_Mode`):

| Property | Mode `console` | Mode `declaration` |
|---|---|---|
| Where it runs | The console process (`src/modules/system/console`) | The sandboxed evaluation process (`src/modules/system/declaration_eval`) |
| Evaluation strategy | Forces each line whole, left to right, including every `let` binding | Lazy thunk graph: forces only the requested field path and its dependencies |
| Effects and calls | Allowed: built-in commands, loaded exports, isolated calls, service calls, record streams | Refused at the border with `Effect_Refused` before arguments run |
| Input format | One line of up to 4096 bytes; supports top-level `name = expr` variable assignment | Multi-line `.lex` file up to 16 MiB; supports trailing commas; refuses top-level assignment |
| Authority | Acts for the principal of the console session | Zero authority: read-only input bundle, no writable store, no network, no root ring |
| Cross-file loading | Not performed directly; declaration expressions return a typed declaration reference | `import("path.lex")` and `declaration(blake3:...)` read from the caller-supplied read-only bundle |

**Why one language has one meaning in both modes.** Every call forces its arguments from left to right before execution. In mode `console`, forcing the whole line guarantees that no side-effecting call is skipped because its result went unused. In mode `declaration`, effects are refused at the border, and pure sub-expressions stay lazy until needed. Pure expressions produce the exact same value in both modes.

**Text stops at the evaluator.** Neither the root service nor any system service reads Lex text. The sandboxed evaluation process accepts a validated read-only input bundle (`src/library/modus/contract/declaration_eval`) and returns either a canonical serialized typed value or a typed refusal record with its line, column, and failure kind.

## 2. Grammar and values

### Complete grammar

The parser reads `|>` and `_` directly into the compact 16-byte syntax tree without text rewriting.

```
line          = name "=" pipeline | pipeline
pipeline      = logical_or { "|>" stage }
stage         = name | name "(" [ arguments ] ")"
logical_or    = logical_and { "||" logical_and }
logical_and   = comparison { "&&" comparison }
comparison    = with_expr [ ("=" | "!=" | "<" | "<=" | ">" | ">=") with_expr ]
with_expr     = sum { "with" sum }
sum           = term { ("+" | "-" | "++") term }
term          = factor { ("*" | "/" | "%") factor }
factor        = ("-" | "!") factor
              | "if" pipeline "then" pipeline "else" pipeline
              | "let" binding { "," binding } "in" pipeline
              | postfix
postfix       = primary { "." field_name }
primary       = integer
              | "true" | "false"
              | text
              | hash
              | "." name
              | name "(" [ arguments ] ")"
              | name record_lit
              | name
              | "(" [ param { "," param } ] ")" "=>" pipeline
              | "(" pipeline ")"
              | record_lit
              | "[" [ pipeline { "," pipeline } [ "," ] ] "]"
param         = name | record_pat
binding       = (name | record_pat) "=" pipeline
record_pat    = [ name "@" ] "{" [ pat_field { "," pat_field } [ "," ] ] [ "..." [ "," ] ] "}"
pat_field     = name [ "=" pipeline ]
record_lit    = "{" [ field_init { "," field_init } [ "," ] ] "}"
field_init    = name "=" pipeline
arguments     = argument { "," argument }
argument      = [ name "=" ] (pipeline | "_")
              | condition
              | fact_name
              | field_names
condition     = name ("=" | "!=" | "<" | "<=" | ">" | ">=") pipeline
fact_name     = name "." name
field_names   = name { "," name }
hash          = "blake3:" 64 * lower_hex_digit
comment       = "//" { byte except line end }
```

Trailing commas inside `{ ... }` and `[ ... ]` and multi-line layouts apply in mode `declaration`.

### Names, reserved words, and comments

- **Names** start with an ASCII letter or `_`, followed by ASCII letters, digits, or `_`. Dotted names (`monitor.count`, `r.value`) select exports, services, record fields, or record streams.
- **Reserved words of Lex.** Nine words cannot name a variable, binding, parameter, field, or named argument: `_`, `let`, `in`, `with`, `if`, `then`, `else`, `true`, and `false`. Longer names that contain `_`, such as `sum_values`, stay valid names.
- **Line comments.** `//` outside a text starts a comment that runs to the end of the line. The scanner skips comments before parsing and before pipe rewriting, so `|>` or `(` inside a comment has no effect. Lex has no block comment.

### Values and their kinds

Every value of Lex carries one explicit kind (`lex_evaluator.Kind`).

| Kind | Literal or source | Rules and bounds |
|---|---|---|
| `Integer` | Decimal digits: `0`, `42`, `-7` | Signed 64-bit integer (`-9223372036854775808` to `9223372036854775807`). Overflow on `+`, `-`, `*`, or `/` is refused; no operation wraps. Minimum literal: `-9223372036854775807 - 1`. |
| `Boolean` | `true`, `false`, or comparison result | Used by `if ... then ... else ...` and `filter`. Integers never coerce to booleans. |
| `Text` | `"hello\n${name}"` | Valid UTF-8 bytes between double quotes. Supports `\\`, `\"`, `\n`, `\r`, `\t`, `\$`, `\u{XXXXXX}` (rejecting surrogates and values above `0x10FFFF`), and `${expr}` interpolation (formatting `Text`, `Integer`, `Boolean`, `Hash`, and `Member`). |
| `Hash` | `blake3:<64 lowercase hex>` | Exact 32-byte BLAKE3 digest. Uppercase hex, wrong length, or invalid hex is refused as `Hash_Not_Valid`. |
| `Enum` / `Member` | `.french`, `.Verify`, or getter call | A member literal `.name` has no enum until its receiving parameter types it. Numbers are refused where an enum is required. |
| `Record` / `Record_Literal` | `{ x = 0, width = 10 }` | Untyped until received by a typed parameter or `with`. Unknown fields, missing fields, and wrong field kinds are refused. |
| `List` | `[1, 2, 3]`, `[]` | Ordered values of any kind except `None`, `Stream`, and `Record_Input`. Stays inside the evaluation; never crosses an export border. |
| `Function` | `(x) => x * 2`, `() => 1` | Up to 12 parameters. Captures enclosing `let` bindings and parameters by thunk reference, never by eager copy. |
| `Table` | Built-in or export result | Homogeneous rows of one record description, passed between commands without text parsing. |
| `Handle` | Export or built-in result | Kernel capability handle with its object kind and rights. |
| `Bytes` | `bytes(memory, offset, count)` | Raw untyped bytes. Accepted by `Bytes` parameters; never stored in a console variable. |
| `Stream` / `Record_Input` | Typed name: `server.requests`, `server.orders` | Console mode only. A `Stream` wires on its first read and closes when the line ends. |
| `Module_Ref` | `module(blake3:...)` | Exact content-addressed module file in declarations: an object. |
| `Tree_Ref` | `here()` | A tree reference: the tree hash of the source tree of the current project, typed as a tree. A bare `Hash` names no kind, so only a `Tree_Ref` or a `Module_Ref` is an input of a recipe. |
| `Recipe_Ref` | `recipe(module(blake3:...), args)` | Lazy build specification identified by its recipe hash. Forcing it does not run a build. |
| `Follow_Ref` | `follow(publisher, name)` | Publisher-signed release pointer input in a declaration. |
| `Store_Ref` | `store("kernel", .Read, .Write)` | Store grant specification inside a project console or plan. |
| `Plan_Value` / `Project_Value` | `plan { ... }`, `project { ... }` | Tagged lazy record values passed to `plans` and `projects` services. In the console, a plan given to `plans.apply` or `plans.difference` becomes the rows of the plan, each value typed by the description of its owner ("A plan in the console"). |

### Integers with units

Exports and record descriptions attach explicit integer units from `src/library/modus/contract/value_kinds` to integer parameters and fields:

- **Size units:** `bytes`, `KiB`, `MiB`, `pages` (4096 bytes), `blocks`.
- **Time units:** `ns`, `us`, `ms`, `s`.

The console draws unit-annotated record fields with their unit (`memory  256 MiB`, `time  120 ms`) and places the unit once in table column headers (`resident (pages)`, `time (ms)`). The palette displays the unit beside the input field so the principal types the quantity in the declared unit.

### Operators, `with`, `let`, and `if`

- **Arithmetic:** `+`, `-`, `*`, `/`, `%` operate on `Integer` values with standard precedence. Unary `-` negates an `Integer`. Division or remainder by `0` fails with `Division_By_Zero`. Dividing `-9223372036854775808` by `-1` fails with `Overflow`; its remainder `%` is `0`.
- **Addition on non-integers:** `+` joins two `Text` values (`"a" + "b"` gives `"ab"`). In mode `console`, `+` concatenates two `Table` values that share one equal record description (used to join wiring lists).
- **Comparisons:** `=`, `!=`, `<`, `<=`, `>`, `>=` return a `Boolean`. Equality (`=` and `!=`) compares `Integer`, `Boolean`, `Text`, `Hash`, and `Member` values of matching kinds. Ordering (`<`, `<=`, `>`, `>=`) compares `Integer` and `Text` (lexicographic byte order).
- **Boolean logic:** `&&`, `||`, and `!` operate strictly on `Boolean` values (non-booleans are refused). `&&` and `||` short-circuit: the right operand is never evaluated when the left determines the result.
- **List concatenation:** `++` concatenates two `List` values (`[1, 2] ++ [3, 4]` gives `[1, 2, 3, 4]`) and refuses non-list operands.
- **Conditionals:** `if condition then first else second` forces `condition`, refuses any non-`Boolean` result (`Condition_Not_Boolean`), and forces only the chosen branch.
- **Bindings and record destructuring (`let ... in ...`, function parameters):**
  ```
  let
    width = 6,
    { host, port = 8080, ... } = config,
    r @ { a, b } = pair,
    area_fn = ({ w, h = w }) => w * h
  in
    area_fn({ w = width })
  ```
  Bindings can reference earlier or later bindings in the same `let`. Record destructuring is strict by default (extra fields are refused unless `...` appears), forces only referenced fields on lazy records, and evaluates default expressions only when the field is absent.
- **Record composition (`with`, `extend`, `merge_deep`):**
  - `base with override` is strictly override-only in both modes: every field of `override` must already exist in `base`'s shape (checked eagerly without forcing field values), catching typos immediately.
  - `extend(a, b)` performs shallow lazy field addition and override without forcing field values.
  - `merge_deep(a, b)` performs recursive lazy merging of nested records (depth- and step-bounded).
- **Call on a record literal:** `name { ... }` is exact syntax sugar for `name({ ... })`. Both `plan { ... }` and `project { ... }` use this form.
- **Named arguments:** `grow(r, by = 2)` passes arguments by parameter name. Once a named argument appears, every remaining argument in that call must be named. Optional enum parameters can be left out (`settings.set(font = .spleen)`).

## 3. The pipe operator and transforms

### The pipe operator `|>` and placeholder `_`

The pipe operator `|>` passes the value on its left into the call on its right. It has the lowest precedence and binds left to right.

```
a |> f          // rewrites to: f(a)
a |> f()        // rewrites to: f(a)
a |> f(b, c)    // rewrites to: f(a, b, c)
a |> f(b, _)    // rewrites to: f(b, a)
a |> f(by = _)  // rewrites to: f(by = a)
```

**Native parsing.** The parser parses `|>` and `_` directly into `Pipe` and `Placeholder` AST nodes with zero source rewriting and no stage limit, preserving exact original byte spans for diagnostics. In `g() |> f(h(), _)`, argument 1 (`h()`) forces before argument 2 (`g()`).

**Refusals before any call runs:**
- `|` alone is not an operator; write `|>` for pipes or `||` for logical OR.
- Missing left operand (`|> f`), missing right stage (`a |>`), or non-call right stage (`a |> 12`).
- `_` used as part of a larger expression (`a |> f(_ + 1)`), repeated twice in one call (`a |> f(_, _)`), placed inside a nested call (`a |> f(g(_))`), or used without a preceding `|>`.

### Built-in pure standard functions

Eleven pure functions are built into the evaluator (`lex_evaluator`), collision-free with console commands, so they work identically in mode `console` and mode `declaration`:

```
map([1, 2, 3], (x) => x * 2)                                // [2, 4, 6]
filter([1, 2, 3, 4], (x) => x % 2 = 0)                      // [2, 4]
[1, 2, 3, 4] |> fold(0, (acc, x) => acc + x)                // 10
zip([10, 20], [1, 2]) |> map(({ first, second }) => first + second) // [11, 22]
fields({ b = 2, a = 1 })                                    // ["a", "b"] (non-forcing)
has({ a = 1 }, "a")                                         // true (non-forcing)
extend({ a = 1 }, { b = 2 })                                // { a = 1, b = 2 } (lazy)
merge_deep({ net = { port = 80 } }, { net = { host = "h" } })
assert(port > 0, "port must be positive", port)
trace("resolved port", port)
```

- `map(list, fn)` applies a 1-parameter function to each item in order.
- `filter(list, predicate)` keeps items where the 1-parameter `Boolean` predicate returns `true`.
- `fold(list, init, fn)` runs an iterative left fold `fn(acc, item)` in O(1) stack space.
- `zip(left, right)` pairs elements as `{ first = left[i], second = right[i] }` up to the shorter length.
- `fields(rec)` returns the record's field names in canonical ascending UTF-8 order without forcing field values.
- `values(rec)` forces and returns the record's field values in canonical ascending UTF-8 key order.
- `has(rec, name)` checks whether `name` exists in `rec`'s shape without forcing any field.
- `extend(a, b)` lazily adds and overrides fields from `b` onto `a` without forcing values.
- `merge_deep(a, b)` recursively merges nested records lazily within `MERGE_DEEP_DEPTH_LIMIT` (64 levels) and step bounds.
- `assert(cond, msg, value)` checks `Boolean` `cond`; on `false` forces `Text` `msg` and refuses with `Assertion_Failed`; on `true` skips `msg` and evaluates `value` in tail position.
- `trace(msg, value)` appends `Text` `msg` to a caller-supplied bounded `Trace_Log` (zero ambient I/O, zero effect on canonical output) and evaluates `value` in tail position.

### Table transforms: `where`, `sort`, and friends

Tables are the data unit that crosses module and service borders. Eight built-in console commands transform any `Table` using its record description:

| Command | Result | Example |
|---|---|---|
| `where(table, field op value)` | Rows matching a typed condition | `processes() \|> where(threads > 1)` |
| `sort(table, field)` | Stable ascending sort on `field` | `processes() \|> sort("name")` |
| `columns(table, f1, f2)` | Rows projected to chosen fields | `processes() \|> columns(name, slot, resident)` |
| `join(left, right, field)` | Inner join on equal `field` values | `join(a, b, "hash")` |
| `first(table, count)` | At most `count` leading rows | `log.records(0) \|> first(10)` |
| `skip(table, count)` | Rows after the first `count` | `processes() \|> skip(2)` |
| `rows(table)` | Row count as `Integer` | `processes() \|> rows` |
| `row(table, number)` | One `Record` by 1-based index | `processes() \|> row(1)` |

**Why `where` takes a condition instead of a function.** A condition (`status >= 500`, `level = Warning`) is a typed `output.Condition_Terms` record (96 bytes), never executable code. The root service checks it against the writer's record description and hands the resolved `output.Writer_Condition` page directly to the writer of a record output so non-matching records never enter the ring.

## 4. Plans, recipes, and projects

Declarations describe a whole system, session, or project as one lazy value in a `.lex` file. Evaluating a declaration never performs I/O, never accesses the network, and never changes a running process.

### Declaration primitives

| Form | Meaning in mode `declaration` |
|---|---|
| `module(blake3:...)` | Exact content-addressed module reference |
| `declaration(here())`, `declaration(blake3:...)` | Loads a declaration tree from the read-only bundle: a tree reference, or the hash of one exact declaration. A module file or a text is refused |
| `import("path.lex")` | Loads a relative `.lex` file inside the current tree; refuses `..`, leading `/`, `\\`, and non-`.lex` paths |
| `recipe(module(blake3:...), args)` | Lazy build value. The builder is a module file; a bare hash is refused. Each field of `args` that is a tree reference or a module file is an input under its name; the other fields are the arguments; an integer `source_date` of 0 or more is the date of the recipe. Its `recipe_hash` binds the builder, the output kind (a tree), the date, the inputs sorted by name, and the argument record. A bare hash, a tree or module file below the first level, and a `source_date` that is not such an integer are refused with `Recipe_Refused` and the words of the refusal |
| `plan { ... }` | Tagged plan record consumed by the `plans` service |
| `project { ... }` | Tagged project record with `source`, `inputs`, `outputs`, and `console` |
| `follow(publisher, name)` | Release pointer input signed by a trusted publisher key from `keys` |
| `here()` | A tree reference (`Tree_Ref`): the tree hash of the current project source tree |
| `store(name, .Read, .Write)` | Store access grant declared for a project console or plan |

### Writing a project (`project.lex`) and its pins (`pins.lex`)

A project tree contains `project.lex`, `pins.lex`, and its source files. Its content-addressed tree hash covers both `.lex` files, so any machine with the same tree hash evaluates identical hashes.

```
// project.lex
project {
  source = here(),
  inputs = {
    modus = catalog,
    gt    = follow(publisher = keys.gui_toolkit, name = "gui_toolkit"),
    tool  = catalog.git.source(address = "https://example.org/tool", branch = "main"),
  },
  outputs = {
    default = gt.window_app(here()),
    tools   = recipe(catalog.odin_builder, { target = "tools", src = here() }),
  },
  console = {
    modules = [catalog.odin, catalog.nasm, catalog.qemu],
    stores  = [store("kernel", .Read, .Write)],
  },
}
```

`pins.lex` lives beside `project.lex` and holds one canonical sorted record literal of resolved hashes. Only `projects.update` writes it; hand-edited hashes still verify against every fetched tree hash.

```
// pins.lex (written by projects.update)
{
  gt = { tree = blake3:1111111111111111111111111111111111111111111111111111111111111111, source = blake3:2222222222222222222222222222222222222222222222222222222222222222, ref = "41" },
  tool = { tree = blake3:3333333333333333333333333333333333333333333333333333333333333333, source = blake3:4444444444444444444444444444444444444444444444444444444444444444, ref = "a1b2c3" },
}
```

### Applying plans, building recipes, and entering projects

Three separated services hold least authority (`src/library/modus/contract/plans_recipes`):

- **Plans (`plans` service):**
  - `plans.difference(p)` forces plan `p` in a sandboxed evaluator and asks the root service for the grant, role, module, and store difference against the current applied plan.
  - `plans.apply(p)` displays that root-computed difference on the trusted display (`Show_Plan_Difference`). After whole-plan consent, the root service checks that the current plan has not changed, checks module closure in `module_files`, writes applied plan `N + 1` into `applied_plans` (104-byte wire record), and commits the current-plan pointer atomically.
  - `plans.rollback()` shows the difference back to the previous applied plan generation on the trusted display and gives a ticket; `plans.rollback_poll(ticket)` selects that generation, without writing a new record, once the principal accepts. `plans.rollback(n)` selects generation `n`.
- **Recipes (`recipes` service):**
  - `recipes.build(target)` realises `outputs.default` (or a named output such as `recipes.build(kernel.tools)`).
  - Substitution mode is passed as a named argument: `recipes.build(kernel, substitution = { mode = .Verify })`. Modes are `.Cache_First`, `.Build_Only`, `.Cache_Only`, and `.Verify` (builds locally and verifies byte-for-byte equality with a signed cache realisation).
  - Sandboxed builders receive read-only inputs, an empty output store, a frozen date, a deterministic seed equal to `recipe_hash`, zero network access, and no root ring.
  - `recipes.provenance(target)` reports whether an output came from a local build or a signed cache realisation and names its signer.
- **Projects (`projects` service):**
  - `projects.inputs(p)` lists each pinned input with its tree hash and source provenance.
  - `projects.update(p)` (or `projects.update(p, inputs.gt)`) runs each input's source resolver with a network grant restricted to that source's host and writes a new version of `pins.lex`.
  - `projects.enter(p)` starts a child console connected to the hashes in `console.modules` and granted only attenuated rights to stores already held by the caller. Nothing is installed globally.
  - `exit()` stops the child console and returns control to the parent console.

## 5. Record stream short forms and the body region

Record outputs (`server.requests`, `server.log`) and record inputs (`server.orders`, `collector.sources`, `merge.sources`) connect processes through typed output rings (`src/library/modus/contract/output`). The general form composes rows with `wire(from, to)` and `+`, then passes the list to `start(module, list)` so the root service creates every ring before the child's first instruction.

### Short forms for frequent stream tasks

Four short forms expand purely into validated wiring lists (`src/library/internal/console/console_stream/short_forms.odin`) with zero special paths in the root service:

| Short form | Expansion | Pace and space terms | Refused inputs |
|---|---|---|---|
| `audit(server)` | One row per declared record output of `server` plus `server.log`, all to `collector.sources` | `Always_Holds_Writer`, space `Audit` | Invalid name, `"collector"` self-audit, generic or `Paired` output, damaged module, out-of-bounds block limit, `> 32` rows |
| `audited(wire(shop.orders, server.orders))` | Row 1: `shop.orders` to `collector.sources` (`forward = true`); Row 2: `collector.forward` to `server.orders` | `Always_Holds_Writer`, space `Audit` | Self-wiring, `"collector"` as source or target, `log` stream, asker reader |
| `keep(stream, limit)` | One row from `stream` (preserving its `where` condition) to `collector.sources` | `Never_Holds_Writer`, space `Keep`, block limit `1 ..= 1048576` (default `1024`) | `limit <= 0` or `limit > 1048576`, `"collector"` self-keep, `log` stream, generic or missing output |
| `merge(a, b)` | Rows `a -> merge.sources`, `b -> merge.sources`, plus `merge.merged -> asker` | `Writer_Chooses` | Fewer than 2 or more than 7 sources, cyclic self-merge (`merge` as source), duplicate `(owner, stream)` or `(owner, index)`, `log` stream, mismatched record types |
| `collector.verify(space)` | Validates typed name `owner.stream` (including `owner.log`) and verifies the BLAKE3 segment hash chain of that `Audit` space | Service call (refused in mode `declaration` with `Effect_Refused`) | Malformed typed name, `"collector"` self-verify, absent space, `Keep` space (only `Audit` spaces hold a hash chain) |

Composing an audited server start:

```
start("server", audit(server) + audited(wire(shop.orders, server.orders)))
start("server", keep(server.requests |> where(status >= 500), 2048))
merge(alpha.requests, beta.requests) |> where(status >= 500) |> first(10)
collector.verify(server.log)
```

### Large payloads: the body region

An output ring compartment holds records up to 256 bytes. A record output whose records carry larger payloads uses a **body region** (`src/library/modus/contract/output/body_region.odin`): a ring-buffered shared memory object owned by the writer and mapped read-only by readers.

- **`Body_Region_Header` (64 bytes at offset 0):** carries magic `"BODY"`, version `1`, power-of-two alignment (`8 ..= 64`), `data_capacity`, monotonic wrap `generation` (from `1`), `write_offset`, `previous_wrap_offset`, `next_serial`, `total_written`, and zeroed reserved words.
- **`Body_Reference` (16 bytes inside a record):** carries aligned `offset`, exact byte `length`, `generation`, and `serial`.
- **Contiguous wrap without splitting:** when a payload does not fit between `write_offset` and `data_capacity`, `body_region_write` records `previous_wrap_offset = write_offset`, increments `generation`, resets `write_offset` to `0`, copies the payload, and zeroes alignment padding bytes. At `generation == max(u32)`, wrapping fails closed with `Generation_Exhausted`.
- **Single-copy border check:** `body_region_read` copies the header once, verifies header invariants, checks 64-bit `offset + aligned_length <= data_capacity`, refuses stale or overwritten `generation - 1` ranges (`offset < write_offset` or `write_offset >= previous_wrap_offset`), refuses ranges past `previous_wrap_offset` (`Wrap_Corruption`), refuses future generations, checks alignment and optional zero-length / serial rules, and copies the payload once into caller memory. A refused read never modifies the destination buffer.

## 6. Evaluation diagrams

### Eager console evaluation (mode `console`)

In mode `console`, every line parses directly (including native `|>` and `_`) into a compact 16-byte SoA AST, compiles to flat 32-bit register bytecode, and runs on the shared VM forcing the root and all `let` bindings from left to right. Effects execute in strict data-flow order.

```
  Console line:  "let x = f(1) in g(2) |> h(x, _)"
         |
         v
  [1] lex_parser.parse_console (16-byte SoA Ast_Node, native |> and _)
         |
         v
  [2] lex_evaluator compiler (32-bit register bytecode + sorted Record_Shapes)
         |
         v
  [3] lex_evaluator VM (Mode = .Console, flat arena-backed frames, O(1) TCO)
         |-- force binding x  ---> calls host f(1)   [effect 1, memoized in 24B Thunk]
         |-- force Call("h"):
         |     |-- arg 1: Name(x) ---> reads memoized thunk (0 extra calls)
         |     |-- arg 2: Call("g") -> calls host g(2) [effect 2]
         |     `-- call host h(x_val, g_val)           [effect 3]
         v
  [4] Result drawer (console_results) draws typed value or error record
```

### Lazy thunk-graph evaluation and cycle detection (mode `declaration`)

In mode `declaration`, record fields and `let` bindings create unforced thunks. Requesting a field path such as `outputs.tools` forces only the nodes on that dependency path. Every thunk transitions through three explicit states: `Unforced -> Computing -> Forced`.

```
  Declaration file (.lex) + read-only bundle
         |
         v
  [1] lex_parser.parse_declaration (caller-owned node pool)
         |
         v
      project {
        inputs  = { ... },          <-- Thunk #1: Unforced (never evaluated!)
        outputs = {
          image = slow_build(...),  <-- Thunk #2: Unforced (never evaluated!)
          tools = recipe(odin, {    <-- Thunk #3: Requested path "outputs.tools"
            src = here(),           <-- Thunk #4: Forced (computes tree hash)
          }),
        },
      }
         |
         v
  [2] Force path "outputs.tools" (Mode = .Declaration)
         |
         |-- Effect check at every Call:
         |     if command.has_effect -> STOP (Effect_Refused, 0 side effects)
         |
         |-- Bounds check at every force:
         |     steps > budget       -> STOP (Step_Bound_Reached)
         |     depth > depth_limit  -> STOP (Depth_Bound_Reached)
         |     stack > 512 KiB      -> STOP (Stack_Bound_Reached)
         |
         `-- Thunk state machine (cycle detection):

               [Unforced] ---force()---> [Computing] ---done---> [Forced(value)]
                                              |                        |
                                      re-entered while              re-forced:
                                        Computing!                returns cached
                                              |                   value (0 steps)
                                              v
                                   STOP: Cycle_Detected
                                   (direct, mutual, record-field,
                                    or cross-file import cycle)
         |
         v
  [3] Canonical serializer (modus:contract/declaration_eval)
      sorts record field keys -> writes validated typed buffer or refusal
```

## 7. Errors and how to read them

A failed evaluation stops at the first refusal and returns one typed record with its source place (line and column from 1, byte offset from 0). In the console, the first line starts with `error: ` and gives the reason in plain words; an export or root refusal follows with the seven integers of its error record (`docs/MODULE_CONTRACT.md`, "8. Errors that diagnose").

### Reading a refusal

```
error: Rectangle has no field widht; its fields are x, y, width, height
```

1. **Where:** line and column (or command and argument number) locate the exact token or expression that failed.
2. **What:** the refusal names the kind mismatch, missing field, invalid member, or bound reached.
3. **What is valid:** when a closed set applies (record fields, enum members, record outputs), the error lists the valid names.

### Refusal kinds, examples, and fixes

| Refusal kind | Concrete example | What failed | How to fix |
|---|---|---|---|
| `Parse_Error` (`Text_Without_End_Quote`, `Unexpected`, `Hash_Not_Valid`, `Word_As_Name`, `If_Then_Missing`, `Let_In_Missing`) | `let with = 1 in with` or `blake3:ABCD` | Invalid syntax, reserved word used as a name, or malformed 64-hex lowercase BLAKE3 hash | Rename bindings away from reserved words; write `blake3:` with exactly 64 lowercase hex digits; close all quotes, braces, and branches |
| `Effect_Refused` | `plans.apply(p)` or `collector.verify("server.log")` inside `project.lex` | A command with an effect ran in mode `declaration` | Move the effect command to the console; keep `.lex` declarations pure values |
| `Cycle_Detected` (`Cycle`) | `let a = b, b = a in a` or `a.lex` imports `b.lex` imports `a.lex` | A thunk or imported file forced itself while still computing | Break the circular dependency so each binding or import forms a directed acyclic graph |
| `Step_Bound_Reached` (`Budget_Exceeded`) | `let f = (n) => f(n + 1) in f(0)` | Evaluation exceeded `EVALUATION_BUDGET_STEPS` (33 554 432 steps; charged across VM ops, thunk forces, bulk ops, `=`, and canonical serialization) | Add a base case with `if ... then ... else ...` so recursion terminates |
| `Depth_Bound_Reached` (`Depth_Exceeded`) | 5000 nested non-tail calls or >64 nested `merge_deep` layers | Arena-backed VM frame depth exceeded `EVALUATION_DEPTH_LIMIT` (4096) or `MERGE_DEEP_DEPTH_LIMIT` (64) | Convert recursion to tail calls (O(1) stack) or flatten nested merges |
| `Assertion_Failed` | `assert(port > 0, "port must be positive", port)` | `assert` condition evaluated to `false` | Fix the value that violated the assertion; the refusal detail holds the message |
| `Unknown_Name` / `Unknown_Command` | `unknwon_var` or `foo(1)` | Identifier is not bound in `let`, parameters, variables, or command table | Load or connect the module (`load("...")`, `connect("...")`), or fix the spelling |
| `Field_Unknown` / `Literal_Field_Unknown` | `{ widht = 3 }` or `r.missing` | Record does not declare that field | Check the listed field names in the error sentence |
| `Literal_Field_Missing` | `area({ x = 0, y = 0, width = 3 })` | Required record field omitted; fields have no implicit zero default | Supply every field of the record, or modify an existing record with `r with { width = 3 }` |
| `Literal_No_Type` / `Member_No_Type` | `{ a = 1 }` or `.french` alone on a console line | Untyped literal or enum member has no typed receiver | Pass it to a typed parameter or compose it with `record with { ... }` |
| `Member_Unknown` | `settings.set(font = .comic)` | Member name is not in the parameter's enum | Choose one of the enum members listed in the error |
| `Argument_Unknown` / `Argument_Twice` / `Argument_Missing` | `grow(r, r, by = 2)` | Named argument unknown, passed both positionally and by name, or missing | Match parameter names from the hint line; place named arguments last |
| `Type_Error` (`Operator_Kinds`, `With_Kinds`, `Condition_Not_Boolean`, `Not_A_Function`, `Not_A_List`, `Value_At_Border`) | `if 1 then 2 else 3` or `area([1, 2])` | Wrong value kind for operator, condition, function call, or export border | Use booleans in `if` / `filter`; keep `Function` and `List` values inside Lex expressions |
| `Division_By_Zero` / `Overflow` | `10 / 0` or `9223372036854775807 + 1` | Zero divisor or signed 64-bit arithmetic overflow | Guard divisors with `if d = 0` and keep arithmetic within signed 64-bit bounds |
| `Import_Path_Refused` / `Import_Not_Found` | `import("../other.lex")` or `import("missing.lex")` | Path escapes tree, lacks `.lex` suffix, or is absent from the input bundle | Use a relative path inside the tree ending in `.lex` and include it in the project tree |
| `Pool_Exhausted` (`Calls_Full`, `Lists_Full`, `With_Pairs_Full`, `Imports_Full`) | Too many calls, list items, `with` pairs, or imported files in one evaluation | Fixed zero-allocation workspace pool filled | Reduce collection size or split the declaration |
| `Recipe_Refused` | `recipe(module(blake3:...), { source = blake3:... })` | The arguments of a recipe do not convert to the record of the service `recipes`; the detail gives the words of the refusal | Give each input as `here()` or `module(...)` at the first level of the arguments, and `source_date` as an integer of 0 or more |
| `Unserializable_Value` | Declaration evaluating to a bare `Function` | Requested output cannot cross the canonical declaration border | Select a concrete field (integer, boolean, text, hash, list, record, plan, or project) |

## 8. Frequent tasks reference

| Task | Lex expression |
|---|---|
| List running processes and filter by name | `processes() \|> where(name = "server")` |
| Select columns and sort a table | `processes() \|> where(threads > 1) \|> columns(name, slot, resident) \|> sort("resident")` |
| Read typed log facts | `log.records(0) \|> facts(log_reader.Fact_Probe) \|> where(probe_number = 7)` |
| Pass piped value into a non-first argument | `compile(src, t) \|> bytes(t, 0, _) \|> assemble(f)` |
| Update one field of a record | `r with { width = 10 }` |
| Bind local values and define a helper function | `let double = (x) => x * 2 in map([1, 2, 3], double)` |
| Filter and transform a list | `[1, 2, 3, 4] \|> filter((x) => x > 2) \|> map((x) => x * 10)` |
| Change one setting with a named enum argument | `settings.set(keyboard_layout = .french)` |
| Watch live errors from a record output | `server.requests \|> where(status >= 500)` |
| Capture the first N matching stream records as a table | `server.requests \|> where(status = 404) \|> first(5)` |
| Start a server with full audit of outputs, log, and inputs | `start("server", audit(server) + audited(wire(shop.orders, server.orders)))` |
| Keep filtered server errors in a bounded collector space | `start("server", keep(server.requests \|> where(status >= 500), 2048))` |
| Merge two record outputs into one stream | `merge(alpha.requests, beta.requests) \|> where(status >= 500)` |
| Verify the hash chain of an audit space | `collector.verify(server.log)` |
| Inspect a plan grant difference without applying | `plans.difference(system)` |
| Apply a plan after trusted-display approval | `plans.apply(system)` |
| Roll back to the previous or numbered applied plan | `plans.rollback()`, `plans.rollback(4)` |
| Read a project from the current source tree | `kernel = declaration(here())` |
| Build default or named project output with verification | `recipes.build(kernel)`, `recipes.build(kernel.tools, substitution = { mode = .Verify })` |
| Update pinned declaration inputs in `pins.lex` | `projects.update(kernel)`, `projects.update(kernel, inputs.gt)` |
| Enter and leave the console of a project | `projects.enter(kernel)`, then `exit()` |
