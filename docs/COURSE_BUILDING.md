# Modus Practical Course — Part 2: Building, Reproducible Recipes, and Publishing

This guide is Part 2 of the hands-on `modus` course (following `docs/COURSE.md`). It explains how to prototype C code inside a zero-grant sandbox, create and iterate on projects, write reproducible build declarations in `project.lex`, run sandboxed local builds, publish signed closures over QUIC directly from the `modus` console, and verify, deliver, run, and version the resulting modules.

## About this guide

**The idea in plain words.** Every build on `modus` runs inside a deterministic, zero-network sandbox (`No_Clock`, fixed random seed derived from the recipe hash), identifies every input and output by its BLAKE3 content hash, and signs published realisations with Ed25519 keys whose private seed never leaves the `recipes` service. You move smoothly from a one-line C prototype (`compile_c`) to a project store (`projects.new`, `edit`, `build`, `run`) to a declarative, shareable, cryptographically verified `project.lex` build and QUIC object cache workflow.

**For whom.** A developer who completed Part 1 (`docs/COURSE.md`) and wants to build, test, verify, and publish programs on `modus`.

**Read before.** `docs/COURSE.md` (Part 1). Follow-up references: `docs/CONSOLE.md`, `docs/LEX.md`, `docs/MODULE_CONTRACT.md`, `docs/STORAGE.md`, and `docs/TOOLS.md`.

**The map of Part 2.**

| Lesson | What you learn |
|---|---|
| "Lesson 1: Instant sandboxed C prototyping (`compile_c`)" | Compiling C source inline into a zero-grant isolated module handle, inspecting with `help(a)`, calling exports, and unloading |
| "Lesson 2: Iterative projects (`projects.new`, `edit`, `build`, `run`)" | Creating a project store, editing C source with automatic copy-on-write commits, compiling in a sandbox, hitting local cache substitution, and enforcing declared grants |
| "Lesson 3: Reproducible build declarations in Lex (`project.lex`)" | Declaring inputs, `let ... in`, `with` overrides, typed size units (`2 MiB`, `4 MiB`), `here()`, `recipe(catalog.modules.c_builder, ...)`, and project console scopes |
| "Lesson 4: Content-addressed ingestion and sandboxed builds" | Freezing a source tree with `recipes.ingest_tree`, building locally with `recipes.build_project("build_only")`, and checking `recipes.provenance` |
| "Lesson 5: In-OS QUIC cache publishing and cryptographic verification" | Inspecting `recipes.publisher_key()`, uploading closures bottom-up with `recipes.publish`, verifying reproducibility with `recipes.build_project("verify")`, reading `recipes.status()`, and running `recipes.collect_garbage()` |
| "Lesson 6: Delivering, running, installing, and versioning modules" | Delivering verified modules into `module_files` with `recipes.deliver_module`, running them in a zero-grant call host, one-step `projects.install`, and browsing source history with `Ctrl+H` |

## Lesson 1: Instant sandboxed C prototyping (`compile_c`)

`compile_c(name, source)` compiles a freestanding C source string directly inside `modus` using the boot image's `c_compiler` and `assemble` modules, validates the resulting `.module` binary, spawns a zero-grant isolated child process, and binds its exports to a plain variable name:

```
a = compile_c("adder", "long add(long x, long y) { return x + y; }")
help(a)
a.add(19, 23)
unload(a)
```

What happens step by step:

1. `a = compile_c("adder", ...)` requires a top-level variable binding (`a = ...`). Calling `compile_c` without a binding is refused before any compiler or child process starts, keeping the global namespace clean (`src/md/features/module_handles.md`).
2. `compile_c` displays its `Loaded` handle record immediately (`binding: a`, `module: adder`, `commands: 1`, `call: isolated`).
3. `help(a)` lists only the commands exported by handle `a`, showing `a.add(x: Integer, y: Integer) -> Integer`.
4. `a.add(19, 23)` sends the two integers across the isolated call ring into `a`'s zero-grant child process and returns `42`.
5. `unload(a)` stops the disposable child process, removes `a.*` commands, and clears variable `a`. Reassigning `a` to another value also unloads the previous handle automatically once the new value succeeds.

## Lesson 2: Iterative projects (`projects.new`, `edit`, `build`, `run`)

When a program grows past one expression, create a dedicated project store and iterate with `edit`, `build`, and `run`:

```
projects.new("hello")
edit("hello", "hello.c")
```

In the `edit: hello.c` window, type your C program and press `Enter`:

```c
long main(void) { return 42; }
```

When you pause typing, `edit` commits the updated source file to the `"hello"` store as a new copy-on-write generation automatically. Switch back to the console and build and run it:

```
build("hello", "hello.c")
run("hello")
build("hello", "hello.c")
run("hello", "store")
```

What each step demonstrates:

- **First `build("hello", "hello.c")`:** `recipes` compiles `hello.c` inside a deterministic sandbox (`No_Clock`, zero network, zero disk access outside staged inputs), validates the output `.module`, stores its content-addressed realisation, and delivers the module into `module_files` under `"hello"`.
- **`run("hello")`:** loads `"hello"` from `module_files`, checks its BLAKE3 hash against the last build, executes `main()` inside a zero-grant call host, and prints `42`.
- **Second `build("hello", "hello.c")`:** hashes the unchanged source and recipe inputs, finds the existing local realisation, and substitutes the verified module immediately without recompiling.
- **`run("hello", "store")`:** refuses before starting any call host because `"hello"` declares no `store` grant (`error: run: the project hello declares no grant store`).

## Lesson 3: Reproducible build declarations in Lex (`project.lex`)

For multi-file projects, explicit builder versions, and cacheable builds shared across machines, describe the project in `project.lex` using pure Lex (`docs/LEX.md`). Open a project's declaration in the editor with `edit("calc", "project.lex")`:

```
let
  default_build = {
    source    = here(),
    path      = "main.c",
    compiler  = catalog.modules.c_compiler,
    assembler = catalog.modules.assemble,
    host      = catalog.modules.host,
    heap      = 2 MiB,
  },
  release_build = default_build with { heap = 4 MiB },
in
  project {
    source = here(),
    inputs = { modus = catalog },
    outputs = {
      default = recipe(catalog.modules.c_builder, release_build),
      source  = here(),
    },
    console = {
      modules = [catalog.modules.c_builder],
      stores  = [store("calc", .read, .write)],
    },
  }
```

Every piece has one explicit role:

- **`let ... in`** binds reusable local records (`default_build`, `release_build`) inside the pure declaration.
- **`here()`** resolves to the canonical `MODTREE2` BLAKE3 hash of the project's source tree (`"calc"`). Changing even one byte of `main.c` changes `here()` and therefore changes the recipe hash.
- **`2 MiB` and `default_build with { heap = 4 MiB }`** attach checked size units directly to numbers and override record fields strictly (misspelled field names refuse during evaluation).
- **`catalog.modules.*`** pins the exact BLAKE3 hashes of `c_builder`, `c_compiler`, `assemble`, and `host` from the system catalog (`catalog.lex`).
- **`recipe(catalog.modules.c_builder, release_build)`** constructs a content-addressed build recipe naming its exact builder module, inputs, and arguments.
- **`console = { modules = [...], stores = [store("calc", .read, .write)] }`** declares the least-privilege modules and store scopes for a project console.

## Lesson 4: Content-addressed ingestion and sandboxed builds

Once a project has `project.lex`, the console connects to `recipes` and drives content-addressed ingestion, sandboxed building, and provenance inspection through typed records:

```
tree = "calc" |> recipes.ingest_tree
tree
pkg = "calc" |> recipes.build_project("build_only")
pkg
pkg.recipe |> recipes.provenance
```

What happens internally:

1. **`recipes.ingest_tree`** walks the `"calc"` store recursively in sorted byte order, hashes every file and canonical `MODTREE2` directory node, uploads them into `recipes` via `recipes.put_memory`, and returns the 64-hex root tree hash.
2. **`recipes.build_project("build_only")`** evaluates `project.lex` (`outputs.default`) inside a zero-grant `declaration_eval` call host, registers the resulting recipe with `recipes`, and runs `c_builder` in a sandbox with `Process_Flag.No_Clock`, a deterministic random seed derived from the recipe hash, a read-only staged input store, and an empty writable output store. It returns a typed `Project_Build` record (`outcome: built`, `recipe`, `output`).
3. **`pkg.recipe |> recipes.provenance`** queries `recipes.realisations()` for `pkg.recipe` and returns a `Provenance` record showing `origin: local_build`, the `output` hash, and the `signer` public key.

Because `pkg` is a typed `Record`, you pass `pkg.recipe` and `pkg.output` directly into subsequent commands through dot field access without ever copying 64-character hashes by hand.

## Lesson 5: In-OS QUIC cache publishing and cryptographic verification

The `recipes` service supports per-principal Ed25519 publisher keys and signed QUIC cache uploads directly from the running `modus` console (`src/md/features/recipes.md`).

### Inspecting your publisher public key

```
recipes.publisher_key()
```

`recipes.publisher_key()` returns only your principal's 64-hex Ed25519 **public** key. If no publisher key exists yet, `recipes` generates a seed and persists it inside its private store; the private seed never crosses a call ring or appears in console history. To import an existing key seed, call `recipes.configure_publisher("<64-hex-seed>")` (which also returns only the public key).

### Publishing a signed closure over QUIC

```
pub = pkg.recipe |> recipes.publish
pub
```

`recipes.publish` performs a verified bottom-up upload over QUIC to the principal's configured object cache:

1. Reads the local realisation for `pkg.recipe` and walks its output tree bottom-up, uploading every child blob before its parent `MODTREE2` tree node so the cache never exposes a dangling root.
2. Verifies each object's BLAKE3 hash before signing its upload envelope with the principal's Ed25519 publisher key.
3. Uploads the signed `Realisation_Record` binding `recipe_hash -> output_hash`.
4. Returns a typed `Publish_Result` record (`recipe`, `output`, `signer`, `objects_uploaded`, `objects_skipped`, `bytes_uploaded`).

### Verifying byte-for-byte reproducibility against the cache

With the realisation published on the QUIC cache server, run `"verify"` mode:

```
verified = "calc" |> recipes.build_project("verify")
verified
recipes.status()
recipes.collect_garbage()
```

- **`recipes.build_project("verify")`** pulls the freshly published signed realisation over QUIC, verifies its Ed25519 signature and BLAKE3 output closure, **rebuilds the recipe locally in the sandbox**, and compares the two output hashes byte-for-byte. Matching outputs succeed and increment `verify_agreements`.
- **`recipes.build_project("cache_only")`** pulls a trusted signed realisation over QUIC without running a local compiler — refusing if no trusted cached realisation exists.
- **`recipes.status()`** returns a `Recipes_Status` record with aggregate counters (`total_builds`, `cache_hits_local`, `cache_hits_remote`, `local_builds`, `verify_agreements`, `verify_disagreements`, `total_refusals`).
- **`recipes.collect_garbage()`** runs mark-and-sweep collection over `recipes`'s private store and reports how many objects were marked, kept, and removed.

## Lesson 6: Delivering, running, installing, and versioning modules

Deliver a verified output tree entry (`"module"`) into `module_files` and run it directly in a zero-grant call host:

```
mod = pkg.output |> recipes.deliver_module("module", "calc")
run("calc")
```

- **`recipes.deliver_module("module", "calc")`** reads `"module"` from the verified `pkg.output` tree, validates the `.module` binary format, writes it into `module_files` under `"calc"`, and returns its BLAKE3 hash.
- **`run("calc")`** executes `"calc"` in a zero-grant child call host and returns `84`.

For everyday workflows, one command combines ingestion, evaluation, cache pull or local build, provenance check, format validation, and delivery:

```
projects.install("calc", "prefer_cache")
```

`projects.install` accepts an optional mode (`"prefer_cache"`, `"build_only"`, `"cache_only"`, or `"verify"`) and returns a typed `Project_Install` record (`outcome`, `origin`, `signer`, `recipe`, `output`, `module`).

### Automatic copy-on-write source history (`Ctrl+H`)

Every project file edited in `edit` is stored in a copy-on-write store where each pause appends an immutable, timestamped generation:

```
edit("hello", "hello.c")
```

1. Press `Ctrl+H` inside `edit` to toggle the **Versions** pane on the right, listing every committed generation and byte count newest-first.
2. Press `Ctrl+Z` to restore the previous committed generation atomically through `storage.restore` (and `Ctrl+Y` to step forward), keeping all earlier and later revisions intact in the store.
