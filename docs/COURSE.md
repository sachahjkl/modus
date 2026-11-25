# Modus Practical Course

This guide is a hands-on course for `modus`: what its core properties are, how they work internally, why they are designed this way, and how to use them daily across the Lex console, apps, services, declarative plans, live streams, and application builds.

## About this guide

**The idea in plain words.** Every part of `modus` builds on five coherent properties: typed console functions and one language (`Lex`), explicit process isolation and capabilities, declarative `plan { ... }` changes with trusted display consent, structured live record streams, and automatic copy-on-write storage. Every command, enum member, unit, and module name is explained in plain English before you run it.

**For whom.** A reader learning `modus` for the first time, and a developer building or operating applications on it.

**Read before.** Nothing is required first. Follow-up references: `docs/PROPERTIES.md`, `docs/CONSOLE.md`, `docs/LEX.md`, `docs/STORAGE.md`, and `docs/TOOLS.md`.

**The map of this course.**

| Lesson | What you learn |
|---|---|
| "Lesson 1: Core properties of modus" | The five core design properties and how they fit together |
| "Lesson 2: Daily console, typed data, and Lex" | Typed `Table` and `Record` pipelines, exact units, pure functions, dotted `.enum` choices, and `help("name")` |
| "Lesson 3: How modus runs apps, services, and libraries" | Plain mental model for `start`, `start_from_disk`, `connect`, `isolate`, and `load` |
| "Lesson 4: Declarative plans and trusted consent" | Writing `plan { ... }`, catching typos early, reviewing diffs on the trusted display, applying, and rolling back |
| "Lesson 5: Live record streams, wiring, and audit" | Filtering live service streams at the writer and verifying tamper-evident audit chains |
| "Lesson 6: Building, installing, and versioning apps" | `project.lex`, one-step `projects.install`, the four `recipes.*` cache steps, explicit `grants`, and `Ctrl+H` versions |

## Lesson 1: Core properties of modus

Every layer of `modus` — from kernel handles to desktop windows — follows five interconnected properties (`docs/PROPERTIES.md`):

| Property | What it is | How it works internally |
|---|---|---|
| **Typed commands and one language (`Lex`)** | Every console command is a typed function returning a `Table`, `Record`, `Enum`, `Unit`, or `Stream` | Each module ships a machine-readable contract; the console validates field names, units, and enum choices against that contract before any call runs |
| **Zero ambient authority** | Every process begins with zero file, store, or network access | The root service hands a process only the explicit kernel handles listed in its grant set; every active handle can be inspected and revoked live |
| **Explicit execution modes** | Launching an app, connecting to a service, isolating a library, and loading in-process are distinct verbs | One compiled `.module` format runs inside a full app process, a background service, a zero-grant child call host, or the console itself |
| **Declarative plans with trusted consent** | System defaults, locks, role holders, and store grants are written as typed `plan { ... }` values | The root service computes the exact difference and the compositor renders the consent dialog directly on the trusted display before any commit |
| **Automatic copy-on-write storage** | Every store commit keeps an immutable, timestamped generation | Storage writes modified 4 KiB blocks to free space and flips one verified root block atomically; pressing `Ctrl+H` previews and restores any earlier generation |

## Lesson 2: Daily console, typed data, and Lex

The console is a normal user-space process (`docs/CONSOLE.md`). Every command is a typed function call, and the pipe operator `|>` passes the value on its left as the first argument of the call on its right.

### Built-in help on any command or keyword

Call `help()` with no arguments to list every available command as a typed `Command` table, or call `help("name")` (equivalently `describe("name")`) to read the exact signature, description, and usage guide of one command or Lex word:

```
help("where")
help("start")
help("plans.apply")
```

### Filtering, projecting, and sorting typed tables

Start `monitor` (or call `processes()` directly when `monitor` runs) to inspect live processes as a typed `Table` of `Process` records:

```
processes() |> where(threads > 1) |> columns(name, slot, resident) |> sort("resident")
```

What each stage does:

- `processes()` returns a `Table` of `Process` records.
- `where(threads > 1)` filters rows using a typed comparison (`=`, `!=`, `<`, `<=`, `>`, `>=`) checked against the `Process` schema before the table runs.
- `columns(name, slot, resident)` selects only the named columns while preserving their types and unit headers (`resident` displays its unit `pages` in the header).
- `sort("resident")` sorts rows in ascending numerical order by resident memory pages.

Useful companions on any `Table`:

- `rows(table)` counts rows and returns an `Integer`.
- `row(table, 1)` extracts the first row as a typed `Record`.
- `first(table, 5)` and `skip(table, 2)` slice rows while preserving column metadata.
- `join(left, right, "hash")` performs an inner join across two tables on a matching field.

### Reading structured records, variables, and `with` overrides

`memory()` returns a typed `Memory` record whose fields carry exact size units (`MiB` for total and free RAM, `pages` for used, reserved, and budget counts):

```
m = memory()
m.free
```

Assigning `name = expr` stores the typed value in a console variable for later lines. A record variable exposes fields directly through dot access (`m.free`), and `r with { width = 10 }` returns a new record with strictly checked field overrides (a misspelled field name is refused immediately).

### Exact units, pure functions, `match`, and `??`

Lex attaches size units (`bytes`, `KiB`, `MiB`, `pages`, `blocks`) and time units (`ns`, `us`, `ms`, `s`) directly to integers (`docs/LEX.md`, "Integers with units"):

```
1 MiB + 512 KiB
1 s - 250 ms
```

Compatible units convert exactly to the finer unit (`1536 KiB`, `750 ms`). Incompatible units (`1 MiB + 1 ms`) are refused with `Unit_Mismatch` before running.

Pure functional tools (`let ... in`, `filter`, `map`, `fold`, `match`, `??`, and placeholder `_`) work identically in the console and in declarative `.lex` files:

```
let double = (x) => x * 2 in [1, 2, 3, 4] |> filter((x) => x > 2) |> map(double)
```

- `let double = (x) => x * 2 in ...` binds a local function for the expression.
- `filter((x) => x > 2)` keeps `[3, 4]`.
- `map(double)` applies `double` to each item and returns `[6, 8]`.
- Placeholder `_` directs a piped value into any non-first argument position (`"ab" |> repeat(_, 3)`).
- `match` matches literals, enum members, and record patterns; `cfg.net.port ?? 8080` selects a fallback value without introducing `null`.

### Closed named choices (enums) and fuzzy completion

Every setting uses a closed enum written with a leading dot instead of raw strings or numbers. For example, the `Font` enum of `settings` has two members: `.vector` (smooth outline font) and `.spleen` (pixel bitmap font). The `Appearance` enum has three members: `.auto`, `.dark`, and `.light`.

```
settings.set(keyboard_layout = .french)
settings.set(font = .comic)
```

The console checks `font = .comic` against `settings`' exported module contract before contacting the service. Because `.comic` is not a member of `Font`, the call is refused immediately and lists its valid choices: `.vector, .spleen`.

While typing in the console, fuzzy completion ranks matching commands, services, variables, and modules:

- Type `mcnt`: `monitor.count` rises to the top with its matched characters highlighted.
- Press `Tab`: the console inserts `monitor.count(` and displays the signature hint `count(name: Text) -> Integer` under the edit line.
- Press `Ctrl+R`: search past console lines interactively across restarts.

To follow live warnings as structured records:

```
log.follow |> where(level = Warning)
```

Press `Escape` at any time to close a live stream cleanly.

## Lesson 3: How modus runs apps, services, and libraries

One compiled module format (`.module`) serves desktop apps, background services, libraries, and sandboxed children (`docs/MODULE_CONTRACT.md`). The console provides explicit verbs so process isolation and authority are always clear when you run code:

| Command | Plain-English meaning | Isolation and grants | Typical use |
|---|---|---|---|
| `start("name")` | Launch a built-in app or a pinned disk app from `module_files` | Separate process; built-in apps receive their declared grant set; disk apps verify their pinned BLAKE3 hash and start with only their allowed grants | `start("notes")`, `start("grants")`, `start("db_browser")` |
| `start("name", hash)` / `start_from_disk("name", hash)` | Launch a disk app in `module_files` against an explicit 64-digit BLAKE3 hash | Separate disk process; refuses immediately if stored bytes do not match `hash`; starts with zero ambient grants | `start("db_browser", mod)` or `start_from_disk("db_browser", mod)` |
| `connect("service")` / `mon = connect("service")` | Attach the console to a running (or on-demand) background service | Service runs in its own address space; commands use `service.*` or the bound handle prefix `mon.*` | `connect("monitor")` or `mon = connect("monitor")` |
| `s = isolate("module")` | Spawn a disposable zero-grant child process for a library module and bind its exports to variable `s` | Separate child process with zero kernel handles; a fault stops only that child; all exports stay scoped under `s.*` | `s = isolate("sample")` then `help(s)` |
| `m = load("module")` | Map a trusted library module directly into the console's own memory and bind its exports to `m` | Runs in-process with the console's memory and handles (no crash wall); exports stay scoped under `m.*` | `m = load("math")` then `m.gcd(84, 36)` |

### Why library modules require a bound handle (`s = isolate(...)`)

Calling `isolate("sample")` or `load("math")` without assigning it to a variable is refused **before** any process spawns or memory maps (`src/md/features/module_handles.md`). Binding every library module to a plain identifier variable gives three concrete guarantees:

- **Zero global namespace pollution.** Every export and record constructor lives strictly under `<binding>.<name>` (`s.readings`, `s.sum_values`), so one library can never silently shadow another library or a built-in command.
- **Multiple independent instances.** You can isolate the same module twice at the same time (`a = isolate("tally")` and `b = isolate("tally")`), and each handle runs its own separate child process and state (`a.add(5, "first")` and `b.total()` stay independent).
- **Clean lifetime ownership.** Passing the handle to `unload(s)` — or reassigning `s` to a new value (`s = 42` or `s = isolate("other")`) — stops only that exact child process and reclaims its command names. If a reassignment fails on the right-hand side, the previous handle remains intact.

### Inspecting and calling an isolated library (`sample`)

`sample` is a built-in demonstration library module that exports 12 typed record and table functions, including `readings(count)` (which generates `count` example sensor rows with fields `sensor`, `time`, `value`, `minimum`, and `maximum`) and `sum_values(table)` (which sums the `value` column of a `Reading` table).

Bind `sample` to a handle `s`, inspect its exports with `help(s)` or `help("s.readings")`, and pipe a typed table across the sandbox border:

```
s = isolate("sample")
help(s)
help("s.readings")
t = s.readings(4)
t |> where(sensor = 2) |> s.sum_values
unload(s)
```

What happens step by step:

1. `s = isolate("sample")` starts the zero-grant child process and binds its `Loaded` handle record to `s` (`binding: s`, `module: sample`, `call: isolated`).
2. `help(s)` lists only the commands owned by handle `s`; `help("s.readings")` prints the exact signature (`s.readings(count: Integer) -> Table(Reading)`) and description of `s.readings`.
3. `t = s.readings(4)` runs inside the isolated child process and returns 4 demo `Reading` rows (`sensor` 0..3, values `10, 20, 30, 40`) across the call ring.
4. `where(sensor = 2)` filters the table in the console to the single row whose `sensor` is `2` (`value = 30`).
5. `s.sum_values` sends the filtered `Table(Reading)` back to `s`'s isolated child and returns `30`.
6. If you pass a mismatched table shape (`t |> columns(sensor, value) |> s.sum_values`), the console refuses before crossing the border because the projected table does not match `Table(Reading)`.
7. If an isolated module faults, only that disposable child stops; the console reports the stop reason and keeps running.
8. `unload(s)` stops `s`'s disposable child process, removes `s.*` commands, and clears the variable `s`.

### Calling a connected service

`connect("monitor")` attaches to a long-lived background service under its service prefix (`monitor.*`), and you can also bind it to an explicit handle (`mon = connect("monitor")`):

```
connect("monitor")
monitor.served()
monitor.processes() |> first(5)
```

Calling `monitor.processes()` directly also connects on demand with the same grant check if the console has not connected yet.

## Lesson 4: Declarative plans and trusted consent

In `modus`, desired defaults (`values`), locked settings (`locks`), role holders, and store grants are declared as one typed `plan { ... }` value (`docs/CONSOLE.md`, "A plan").

### Step 1: Catch schema typos before any dialog opens

Try a misspelled `Appearance` member first (`.neon` is not one of `.auto`, `.dark`, `.light`):

```
plans.apply("evening", plan { locks = { settings = { appearance = .neon } } })
```

The console validates every value against its owner's exported contract (`settings.set`) before contacting the `plans` service. Because `.neon` is not a member of `Appearance`, the call fails immediately and lists `.auto, .dark, .light`. No dialog opens and nothing changes.

### Step 2: Apply a valid plan through the trusted display

Now apply a valid plan in one step (no separate `connect("plans")` or poll step required; an optional third argument `{ current_plan_hash = blake3:... }` can assert a specific prior plan):

```
plans.apply("evening", plan { locks = { settings = { appearance = .dark } } }) |> columns(generation, standing)
```

You can combine defaults (`values`) and locks (`locks`) in one plan:

```
plans.apply("home", plan { values = { browser = { home = "modus://guide" }, monitor = { sample_interval = 1000 } }, locks = { settings = { appearance = .dark } } })
```

What happens internally and on screen:

1. The console connects to `plans` automatically, and `plans` asks the root service to compute the exact difference between your active state and the proposed plan.
2. The compositor draws a **TRUSTED PLAN DIFFERENCE** dialog directly on the trusted display showing the plan name (`evening`) and the root-computed additions (`+ lock settings.appearance = 1`).
3. **Refuse** is focused by default and input waits through a brief arm delay so no stray keystroke or untrusted process can accept a plan on your behalf.
4. Press `Tab` to move focus to **Accept plan**, then press `Enter`.

### Step 3: Inspect generation history and roll back

Once you accept the dialog, `plans.apply` commits generation `1` atomically into the `plans` private store and returns its `Plan_Generation_Row` table directly (showing `standing: Current` as a typed enum). Inspect all stored generations at any time:

```
plans.generations() |> columns(generation, timestamp_ms, standing)
```

Omit `|> columns(...)` whenever you also want the full `plan_hash` and `previous_plan_hash` columns. Every subsequent plan commit appends generation `N + 1` while preserving earlier generations.

To revert to the previous generation (or pass a specific generation number such as `plans.rollback(1)`):

```
plans.rollback()
```

The trusted display shows the exact reverse diff; accepting commits the rollback in one step and returns the new `Plan_Generation_Row`.

## Lesson 5: Live record streams, wiring, and audit

Background services publish structured events as **record outputs** (`server.requests`, `server.log`) (`docs/CONSOLE.md`, "Streams"; `docs/LEX.md`, "5. Record stream short forms and the body region").

### Filtering live streams at the writer

Connect to a running service and read its typed stream:

```
connect("server")
server.requests |> where(status >= 500) |> first(5)
```

The first `where(...)` condition travels through the root service directly to `server`, so non-matching records never enter the console's ring. `first(5)` turns the live stream into a finite `Table` once 5 matching records arrive.

### Composing wirings and tamper-evident audit

Five short forms expand into validated wiring tables passed to `start(module, wirings)` before the child executes its first instruction:

| Short form | What it builds |
|---|---|
| `wire(from, to)` | Connects one typed record output to one matching record input |
| `audit(server)` | Wires every record output of `server` plus `server.log` into `collector.sources` (holds the writer if full so zero audit records drop) |
| `audited(wire(shop.orders, server.orders))` | Routes `shop.orders` through `collector` before forwarding to `server.orders` |
| `keep(server.requests \|> where(status >= 500), 2048)` | Retains matching records in `collector` up to a 2048-block ring without holding the writer |
| `merge(alpha.requests, beta.requests)` | Merges two to seven matching streams into one stream |

Example audited launch and hash-chain verification:

```
start("server", audit(server) + audited(wire(shop.orders, server.orders)))
start("server", keep(server.requests |> where(status >= 500), 2048))
collector.verify(server.log)
```

`collector.verify(server.log)` verifies the BLAKE3 segment hash chain stored by `collector` and reports any tampered or missing record.

## Lesson 6: Building, installing, and versioning apps

Building and running an outside application such as `db_browser` (a sandboxed SQLite GUI app in `src/outside/projects/db_browser/`) combines Lex project declarations, a signed QUIC object cache, explicit store grants, and automatic copy-on-write versions.

### Step 1: Declare the project in `project.lex`

`edit("db_browser", "project.lex")` opens the project declaration directly from its store:

```
let
  default_build = {
    source = here(),
    target = "db_browser",
    heap   = 2 MiB,
  },
  release_build = default_build with { heap = 4 MiB },
in
  project {
    source = here(),
    inputs = { modus = catalog },
    outputs = {
      default = recipe(catalog.modules.host, release_build),
      source  = here(),
    },
    console = {
      modules = [catalog.modules.host],
      stores  = [store("db_browser", .read, .write)],
    },
  }
```

- `here()` binds the project folder by its canonical BLAKE3 tree hash.
- `default_build with { heap = 4 MiB }` overrides a typed size unit with strict field checking.
- `recipe(...)` pins the exact builder module and inputs.
- `store("db_browser", .read, .write)` states the exact storage scope for a project console.

### Step 2: One-step `projects.install` and the four `recipes.*` steps

For daily use, one command runs the full verified build, cache pull, provenance check, and delivery pipeline:

```
projects.install("db_browser")
```

`projects.install` connects `recipes` automatically, ingests the project store, evaluates `project.lex` (pulling a signed cache realisation when available or building in a sandbox otherwise), validates and delivers the resulting `.module` into `module_files`, and returns a typed `Project_Install` record (`outcome`, `origin`, `signer`, `recipe`, `output`, `module`). Pass an optional second argument (`"prefer_cache"`, `"build_only"`, `"cache_only"`, or `"verify"`) to control cache behaviour, or call `help("projects.install")` to inspect it.

When you want to inspect or script each stage explicitly, the four underlying `recipes.*` commands return typed values and records:

| Command | Plain-English meaning | What it returns |
|---|---|---|
| `tree = "db_browser" \|> recipes.ingest_tree` | Freeze the project folder into immutable content-addressed BLAKE3 objects | The `MODTREE2` root hash (`Text`) |
| `pkg = "db_browser" \|> recipes.build_project("prefer_cache")` | Check the signed QUIC object cache for an exact input-tree match; download on hit or sandbox-build on miss | Typed `Project_Build` record (`outcome`, `recipe`, `output`) |
| `pkg.recipe \|> recipes.provenance` | Inspect who built and signed that output | Typed `Provenance` record (`origin`, `output`, `signer` Ed25519 key) |
| `mod = pkg.output \|> recipes.deliver_module("module", "db_browser")` | Validate the module binary format and store it into `module_files` for execution | Verified module BLAKE3 hash (`Text`) |

### Step 3: Explicit grants and the desktop `grants` window

Launch the delivered module by its verified hash (or by name once pinned in your disk grant table):

```
start("db_browser", mod)
```

Because `db_browser` starts with zero ambient grants, it cannot open any disk store and runs in memory only. Grant its one private store explicitly, inspect active grants in the console or the desktop `grants` window, and restart:

```
allow("db_browser", "store")
stop("db_browser")
start("grants")
stop("grants")
start("db_browser")
```

You can also inspect any running process's grants from the console as a filterable `Grant` table:

```
grants("notes") |> where(state = "held")
```

Inside the running `db_browser`:

- `sqlite.module` executes inside a zero-grant child call host (zero kernel handles and zero direct store access).
- Running `INSERT INTO tasks (title, done) VALUES ('ship modus', 1); SELECT id, title, done FROM tasks;` commits dirty 4 KiB database pages atomically to the private store on a worker thread so the UI thread stays responsive.
- Clicking a column header sorts rows off-thread.

### Step 4: Automatic copy-on-write versions (`Ctrl+H`)

Every commit in `notes`, `edit`, and `db_browser` writes modified 4 KiB blocks to fresh disk space and appends a new immutable, timestamped generation automatically whenever you pause:

1. Press `Ctrl+H` to open the **Versions** list (newest commit first).
2. Press `Down` to preview an earlier generation read-only.
3. Press `Enter` to restore that generation atomically as a brand-new commit while keeping earlier and later history intact.
