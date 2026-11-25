# Bound module handles in the console

## Purpose

When a principal loads or isolates a module in the console (`load`, `isolate`, `isolate_memory`), its exports and record constructors are bound to a variable name (`s = isolate("sample")`) and live strictly under that prefix (`s.readings(4)`, `s.sum_values(...)`, `s.Reading(...)`). The variable owns the lifetime of the loaded module or call host: `unload(s)` or reassigning `s` removes only that handle's commands and stops its call host.

The user guide is [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "1. The keys".

## Constraints

- **No global namespace pollution or silent shadowing.** Registering module exports as flat global names (`commands_add(file, "", ...)`) allowed a loaded module to silently shadow built-in commands or exports of another loaded module, and made the origin of a command invisible at its call site.
- **Multiple independent instances of one module.** Two isolated call hosts of one module (`a = isolate("tally")` and `b = isolate("tally")`) hold separate process state and separate handle lifetimes.
- **No process or mapping on a refused call.** A bare call (`isolate("sample")`) or a nested call (`1 + isolate("sample")`) must fail before spawning a call host or mapping module memory into the console.
- **Explicit handle lifecycle and bounded memory.** Unloading or reassigning a handle must release its commands, its call host or module-space reference, and its bytes in the console command-name buffer so repeated load/unload cycles never exhaust the buffer.
- **Services stay reachable by service name or by bound handle.** Running system services have unique names in the boot image (`monitor`, `plans`, `storage`), so bare `connect("monitor")` keeps registering `monitor.<export>` while `mon = connect("monitor")` binds an explicit handle under `mon.<export>`.

## The chosen form

### Static binding check before evaluation

Right after `lex_parser.parse_console`, `run_line` runs `handle_call_precheck` over the syntax tree before invoking `line_evaluate`:

- Any `.Call` to `isolate`, `load`, `isolate_memory`, or `compile_c` that is not the root of a top-level assignment to a plain identifier (`name = ...`) fails immediately before any evaluation, spawning no process and mapping no memory. The refusal names the concrete binding form (for example `isolate returns a module handle; bind it with sample = isolate("sample")`).
- Inside `add_module`, `isolate_from_memory`, `compile_c`, and bound `connect`, `handle_binding_check` verifies that the target variable name is a plain valid identifier (`lex_parser.name_valid`, refusing dotted targets such as `a.b`), is not a built-in command (`help`, `start`, `where`, ...), fits `VARIABLE_NAME_SIZE`, and has either an existing variable slot or a free slot in `variables` before creating a sandbox or loading into `space`.
- The Desktop Command Palette prepends `<hint> = ` (`palette_handle_prefix_write`) when running or opening handle-returning commands (`load`, `isolate`, `isolate_memory`, `compile_c`) so palette actions satisfy the same bound-handle rule.

### Unique handle ownership (`handle_id`)

Each bound module load, isolated call host, or bound service alias receives a monotonic `handle_id: u64` (from `next_module_handle_id`, starting at 1):

- `Loaded` stores `handle_id`, `binding` (up to `VARIABLE_NAME_SIZE`), `name` (module name), `file`, `place`, `sandbox`, and `service_alias`.
- `Command` stores `handle_id`. `commands_add(file, prefix, sandbox, base, handle_id)` registers both exports and record constructors strictly under `<prefix>.<name>` tagged with `handle_id`, never adding unprefixed global names for a bound handle, and never overwriting a built-in command (`run != nil`).
- `Variable` stores `module_handle: u64`, linking the variable slot to its owned `Loaded` handle.
- The returned `Loaded` record includes `binding`, `module`, `commands`, `call`, and `hash_head`, and `run_line` draws that summary immediately upon binding so the principal sees confirmation without typing a second line. `loaded()` includes the `binding` column.
- The same module can be loaded or isolated several times under distinct bindings (`a = isolate("tally")`, `b = isolate("tally")`), each with its own `handle_id` and sandbox.

### Atomic reassignment, `unload(s)`, and `names` compaction

- **Atomic reassignment.** When `assign(name, value)` updates a variable slot that already owns `old_handle != 0`, the new right-hand side runs and commits into the variable slot first (with `slot.module_handle = new_handle`). Only after the new assignment succeeds does `assign` call `unload_handle_id(old_handle)`. A failed reassignment (`s = isolate("missing")`) leaves the previous `s` and its commands untouched.
- **`unload(s)`.** `unload` takes a `Record` value (the bound `Loaded` handle variable `s`). It validates that the record is a `Loaded` handle whose `binding` and `module` match a live entry in `loaded`, removes only commands matching `entry.handle_id == item.handle_id`, compacts `names`, stops the sandbox or releases the module-space entry (or removes a service alias without disconnecting a shared service sandbox), clears the owning `Variable` slot, and returns an `Unloaded` record (`binding`, `module`, `commands`, `memory`). Passing a non-handle record such as `unload(memory())` or an already-unloaded handle is refused cleanly.
- **`names` buffer compaction.** After removing a handle's commands, `names_compact` rebuilds `names[:names_count]` in-place via a BSS scratch copy for every surviving command whose `name` slice points inside `names[:]`, updating each surviving slice. Built-in command names in `.rodata` stay untouched. Repeated load/unload cycles reclaim every byte.

### Scoped help: `help(s)`

`help([topic_or_handle])` accepts 0 or 1 argument of any value kind:

- `help()` lists all commands in a `Command` table.
- `help("name")` (including `"s.readings"`) delegates to `describe("name")`.
- `help(s)` for a live `Loaded` handle `Record` returns a `Command` table containing only the commands owned by `s` (`entry.handle_id == handle_id`).
- Any other value is refused cleanly.

## Refused forms

- **Flat global commands from `load` and `isolate`.** Allowed silent shadowing of built-in commands and other modules, hid where a command came from, and blocked loading two instances of the same module.
- **Unloading by module name string (`unload("sample")`).** Ambiguous once two instances of one module exist (`a = isolate("tally")`, `b = isolate("tally")`). Unloading by handle variable (`unload(a)`) names one exact instance.
- **Unloading the old handle before evaluating the new right-hand side on reassignment.** A failed `s = isolate("typo")` would destroy the working handle `s`.
- **Leaving deleted command names in `names[:]` until reset.** Repeated load/unload cycles in a long-running console would eventually exhaust the 16 KiB name buffer.

## Subtle points

- **Record field access vs command call.** `s` is a `Record` variable (`s.module`, `s.binding`, `s.hash_head` read record fields via `name_evaluate`), while `s.readings(4)` parses as a `.Call` with name `"s.readings"` and resolves in `commands[]`.
- **Copying a handle record (`x = s`).** Copying the `Loaded` record into another variable `x` sets `x.module_handle = 0`: only the owning variable `s` owns the live handle, and passing a non-owning or stale copy `x` to `unload(x)` or `help(x)` is refused cleanly.
- **Internal console helpers.** `recipes.build_project` (`declaration_eval`), `run` (project module), and `compile_c` (`c_compiler`, `assemble`) call internal handle helpers with internal prefixes and unload by `handle_id` in `defer`, never adding flat global commands.
- **Module-handle completion and colors.** Typing `s.` completes `s.*` exports and record constructors through the existing `.Member` scan over `commands[]`; `line_colors` treats bound handle names as module/variable prefixes cleanly.

## State

Built: static precheck refusing bare and nested `isolate`/`load`/`isolate_memory` before spawn, `handle_id` ownership across `Loaded`/`Command`/`Variable`, prefixed exports and record constructors, multi-instance isolation, atomic reassignment, `unload(s)`, `names` buffer compaction, `help(s)`, bound `mon = connect("monitor")` alongside bare `connect("monitor")`, host unit tests, and updated machine scenarios.
