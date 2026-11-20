# Declarations

A principal describes a system, a session, a project or an environment as one lazy value of Lex, the language of the console, in the manner of Nix. The evaluation of that value has no effect: it gives a typed record, the plan. An explicit command applies the plan, and the root service writes it as one applied plan, which a rollback can select again. The root service and the services never read the text of a declaration.

The terms Plan, Applied plan, Declaration, Catalog declaration, Declaration input, Pin, Release pointer, Project and Declaration reference are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); Lex, Environment, Evaluation budget, Evaluation mode, Thunk, Record literal, Named argument and Anonymous function are in [`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md). The recipes that a plan names, the cache and the substitution policy are in [recipes.md](recipes.md).

## Purpose

A principal does each day the same few tasks: start the system that it chose, go back to the system before, work in a project with its tools, build an output of a project. Today each one is a sequence of console commands that the principal keeps in memory. A declaration states the result once, with the hashes that it resolves to, and one command applies it. A second machine with the same declaration and the same pins gets the same hashes.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system": no `PATH`, no shared configuration folder, no installer.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": a module is the BLAKE3 hash of its bytes, a system is a list of hashes, an upgrade writes a new list and a rollback selects an old one, both atomic.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM": the image that the publisher of the system signed stays the base, and each choice of principal 0 that changes the start is measured.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": no process parses the text of another. [start_policy.md](start_policy.md) refuses "a text configuration file with a parser in the root service" and scripts for the same reason.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": a new grant comes from a principal, as a record that it sees and can revoke.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": one language, and a plain expression for each frequent task.

## What the properties already give

The design adds little mechanism, because most of it exists:

- The identity of a module is the hash of its bytes, and an import names a hash.
- A system is a list of hashes: the system description, with an upgrade and a rollback.
- The disk grant table binds a nickname to a hash, as a profile of Nix binds a name to a store path ([processes_from_a_disk.md](processes_from_a_disk.md)).
- The start policy reads a start list of typed rows ([start_policy.md](start_policy.md)), and the wiring list of a start wires the record outputs ([module_outputs.md](module_outputs.md)).
- Each change of an object of a store is a version ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes").
- The roadmap entry of a cache of modules on the network is the substitution of Nix ([recipes.md](recipes.md)).

What is missing is one value that names all of these at once, a way to compute it, and one atomic step that applies it.

## The chosen form

### Text stops at the evaluation

Text exists only between the principal and Lex. Lex has two readers, with one parser and one evaluator from one library package (property 10):

- **The console** reads the line that the principal types, as today, and evaluates it in mode `console`.
- **The evaluation process** evaluates in mode `declaration`. It reads the text of a declaration object. The console starts it as a sandboxed child for each evaluation of a declaration: it holds a connection that reads only the trees of the declarations that the evaluation names, and nothing else. No network, no store that it can write, no root ring.

The console sends the evaluation process typed values only: a declaration reference, which is the hash of a declaration, the list of the field names to force, and the typed records that a `with` composed with it. The evaluation process sends back typed values only: a plan, a table of recipes, a record of an environment, or an error record with its place. No line of the principal crosses to it, and no text comes back. The text of a declaration is a document that a principal wrote, as the source of a module is: a reader of its language reads it, as a compiler reads a source. No process sends text to another process for it to parse.

The root service and every service read the plan, a typed record, through one border of a contract package. None of them reads the text of a declaration.

### A declaration is an object

A declaration is a tree in a store, with its hash, as a module is. Its root holds one text object in Lex, whose name has the extension `.lex`, and whose value is one record. A tree whose root holds no entry `.lex`, or two, is no declaration: `declaration(hash)` refuses it with an error record that names the tree. A project keeps its declaration in its source tree; a principal keeps the declaration of its session in a store of its own.

The value of a declaration is lazy: the evaluator reads it in mode `declaration` ("One parser, one lazy evaluator, two modes").

### The plan

The plan is the typed record that an evaluation gives and the root service applies. It holds hashes and typed rows, never a name to resolve:

- the hashes of the modules of the plan, each with the recipe that made it when one did;
- the rows of a start list, in the format of `start_list` ([start_policy.md](start_policy.md)), and the hash of a start policy;
- the wirings of the record outputs, in the format of the wiring list of `Start` ([module_outputs.md](module_outputs.md));
- the rows of the disk grant table: a nickname, a hash and its grants;
- the settings, each a member of `Setting` with its value;
- the substitution policy, `Substitution` ([recipes.md](recipes.md), "The substitution policy");
- the pins of each declaration input, with its publisher;
- the provenance of each realisation that it uses: the source and the signer ([recipes.md](recipes.md)).

A plan names each object by its hash, so it is complete in itself: the root service never asks what a name means.

### Apply, the difference and the rollback

`plan { … }` is the only form of Lex that describes an effect, and it has no effect by itself: it is a value. An explicit command applies it:

1. `apply(p)` forces the plan, and the console asks the root service for the difference between the plan and the current applied plan of the principal: the grants that it adds and removes, the wirings, the rows of the start list, the start policy. The root service computes it from its own copy of the current applied plan, not from the evaluation.
2. The console draws the difference as tables, and the principal accepts it with a key, as it accepts the grants of a role today. A difference with no new grant is still shown.
3. The console sends the root ring command `Apply` with the hash of the plan and the hash of the current applied plan that the difference read. The root service refuses the command when the current applied plan changed since: the principal accepted another difference.
4. The root service checks the plan at its border, checks that the store `module_files` holds each hash that the plan names and each import of each module, writes the plan as applied plan N + 1 in the store `plans` of the principal, then writes the hash of applied plan N + 1 in the row "current plan" of the disk grant table of the principal. That last write is the commit: before it, applied plan N is current; after it, N + 1 is.

`rollback()` sends `Rollback`, which writes the hash of the applied plan before the current one into the row "current plan". It writes no new plan. `rollback(n)` selects the applied plan n. A later `apply` writes the number after the highest one, so a rollback never loses a plan.

What changes when:

- The plan changes no process that runs. A grant of a disk process takes effect at its next start, as `allow` does today.
- The start list and the start policy of the plan of principal 0 take effect at the next start of the machine, as the choice of a start policy does today.
- An environment of the plan takes effect at the next `enter`.

So the authority is in `apply`, not in the evaluation. A foreign plan cannot take a grant in silence: its grants are in the difference that the principal accepts.

### The plan of principal 0

The plan of principal 0 is the system plan. It adds to the signed image and never replaces it (property 17): its modules are disk processes and a start policy from the disk, its start list is the list of that start policy, and the boot image stays the one that the publisher of the system signed.

- The row "current plan" of principal 0 is in its disk grant table, under the tag of the machine key, as the choice of a start policy is ([start_policy.md](start_policy.md), "A start policy from the disk").
- The root service reads it at step 4 of each start, before the start policy.
- The measure into PCR 12 stays one extend for each start policy. For a start policy of a system plan, its second hash is the hash of the plan, in place of the 32 zero bytes of a start policy from the disk with no list. So an attestation sees which plan ran, with no third extend.
- `apply` of principal 0 is refused where the machine key does not open with no passphrase, for the reason of the choice of a start policy: the table cannot be read before the start policy.

### Lex: the console with eight forms of grammar and the names of the evaluation

The language of a declaration is Lex, the language of the console ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "Lex"), with no second language. The declarations add eight forms to its grammar:

1. **`let`.** `let a = 1, b = a + 1 in { x = a, y = b }`.
2. **The record literal.** `{ field = value, … }`. It takes the type of the parameter or the field that receives it ("A record literal is typed by its use").
3. **The named argument.** `build(kernel, substitution = { mode = .Verify })`. A named argument follows the rule of the record literal: the parameters of the call are the fields of a record.
4. **The literals that a use types.** A list `[a, b]`, a member of an enum `.Verify`, and a hash `blake3:…`. A list and a member take their type from their receiver, as a record literal does.
5. **The anonymous function.** `(name) => odin.module(name)`. A function is a value: it can be a field, an argument and a result.
6. **`with`.** `a with b` composes two records: the result is `a`, with each field of `b` in place of the field of the same name ("Composition").
7. **The call on a record literal.** `plan { … }` is `plan({ … })`. `plan`, `project` and `env` are functions of the catalog declaration that take one record literal.
8. **The placeholder `_` of `|>`.** `compile(src, t) |> bytes(t, 0, _) |> assemble(f)`: the value on the left takes the place of `_`, one whole argument of the call on the right ([pipe_operator.md](pipe_operator.md), "The placeholder `_`").

The other forms of the declarations are names of functions and values, with no form of grammar of their own. Both modes know them; in mode `console`, a name that gives a value of a declaration gives a declaration reference:

- **A reference by hash.** `module(blake3:…)` is one exact module. `declaration(blake3:…)` is one exact declaration. A name of a catalog declaration, `catalog.odin`, is a field of its record; the plan records the hash that it gave.
- **`recipe(builder, arguments)`.** A lazy value whose identity is its recipe hash. Forcing it does not build it: a build is a command ([recipes.md](recipes.md)).
- **`plan { … }`, `project { … }`, `env { … }`.** The record of a plan, which `apply` takes; of a project; of an environment.
- **The values of the declaration inputs.** `catalog`, `inputs`, `keys` (the table of the publisher keys that the principal trusts), `follow(publisher, name)` and `here()` ("Declaration inputs, pins and release pointers", "Sources and the identity of a source").
- **`map(list, function)`.** It gives a list with the function applied to each item.

### One parser, one lazy evaluator, two modes

One grammar and one parser library read the line of the console and the text of a declaration. One lazy evaluator takes the tree that the parser gives. Each field of a record and each binding of a `let` is a thunk, which the evaluator forces when a value needs it, and at most once.

The evaluator runs in one of two evaluation modes, a closed set:

- **Mode `declaration`** runs in the evaluation process, in its sandbox. An export with an effect is refused at its border: the evaluator does not call it, and gives an error record that names the export, the declaration, its line and column, and the chain of fields that it forced. The evaluator forces nothing beyond the fields that the console asked for, so `kernel.tools` forces the recipe of the tools and nothing of the image.
- **Mode `console`** runs in the console. Exports with an effect are allowed. Each line is forced whole, each binding of its `let` too, so no effect is skipped because its value went unused.

The exports with an effect are the commands `apply`, `rollback`, `build`, `enter`, `exit` and `update`, and each export of a module or a service: the evaluator cannot know that an export of a module has no effect. The names of the evaluation (`module`, `declaration`, `recipe`, `catalog`, `inputs`, `keys`, `follow`, `here`, `map`, `plan`, `project`, `env`) have none. A Stream is a wiring, an effect: mode `declaration` refuses it, and mode `console` holds it while its line runs, as today.

**Why one meaning everywhere.** An export forces its arguments from the left to the right before it is called. So the effects run in the order of the data: `assemble(bytes(t, 0, compile(src, t)), f)` compiles, then reads, then assembles, as the eager console of today does. The one difference that laziness can make is a value that nothing uses, whose effect then never runs. That cannot happen in mode `console`, because the line is forced whole. So a line means the same thing in both modes; mode `declaration` only refuses the effects.

**What is shared.** The parser, the type rules, the literals, `with`, the functions, `where` and the evaluation budget are one code for both modes. A field that names another field of its record, and a `let` that names itself or a later binding, are accepted in both: a cycle with no end stops at the budget.

**The tests.** One evaluator has no second semantics to compare with. The tests check two claims:

- Mode `declaration` refuses each effect: each command with an effect, an export of a module, an export of a service, a Stream. Each case checks the error record, and that nothing changed: no call reached the export, no store was written.
- Mode `console` runs each effect of a line once, in the order of its data: an export whose result no other part uses, an export in a `let` binding that the result does not name, and an export whose result two parts use, which runs once.

**The cost.** The eager evaluator of the console of today is replaced by the shared evaluator in mode `console`. That is layer 2 of the build order ("The build order"), with no change of behaviour.

**A value of a declaration at the console.** The console evaluates no text of a declaration ("An evaluation in the console process" in the refused forms). `declaration(here())`, `catalog` and `kernel.tools` give a declaration reference at the console: the hash of the declaration, the chain of the field names, and the records that a `with` composed with it. Each part is a typed value. Forcing the reference in mode `console` gives the reference itself. A command that needs the value, such as `build` or `apply`, sends the reference to the evaluation process, which forces the fields in mode `declaration` and gives back typed values.

**The limits of the console on lazy values.** Mode `console` forces each line whole, so a variable keeps a value, never a thunk. The thunks of a declaration live in the evaluation process, which ends after its evaluation. So:

- A declaration reference takes one of the 16 variables, whatever the size of its declaration.
- A text field of a forced value keeps the bound of a text of a variable (96 bytes), and a table the bound of a table (`TABLE_KEPT`).
- No Stream reaches a variable through a declaration: mode `declaration` refuses a Stream.

The cost is a second evaluation of the same reference on a later line. The evaluation is pure, so it gives the same value ("Open questions").

### A record literal is typed by its use

A record literal has no type of its own. It takes the type of the parameter or the field that receives it:

- A field of the literal that the type does not have is refused: `error: Substitution has no field mdoe; its fields are sources, signers, mode`.
- A field that the type has, with no default, and that the literal does not give, is refused: `error: Substitution needs the field mode, which has no default`.
- A value of a field is checked against the type of that field, with the same rule, so a literal inside a literal is typed by its field.
- A field whose type is a table of names, such as `inputs`, `outputs` and `tools`, takes any name. The type of the table checks each value.

A named argument is the same rule on the parameters of a call. An unknown name, a parameter given twice, and a parameter with no default that the call does not give are refused, with the name of the command.

In mode `console`, the console knows the receiver from its command table before the run, so it refuses the literal before any call, as it refuses an argument of another kind. A literal with no receiver, such as `r = { a = 1 }`, is refused there: it has no type. In mode `declaration`, a literal is typed when a force passes it to its receiver. A `let` binding that two receivers take is checked against each one. The error record names the declaration, its line and column, and the chain of fields that the evaluation forced.

**Why typed by its use.** A literal with a type name, `Substitution { mode = .Verify }`, repeats a type that the parameter already states. A literal of no type, checked by the receiver only when it reads a field, accepts a field with a wrong name in silence.

### `where` keeps the form of a condition

`where(t, status >= 500)` takes a condition: a field, an operator and a value ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "Conditions"). It does not take an anonymous function.

The reason is the root service. On a record output of a module that is not started, `where` gives a condition that the root service turns into wiring terms and checks at its border ([module_outputs.md](module_outputs.md)). A condition is a typed record: a field of the description, an operator, a value. An anonymous function is code of the language, and the root service runs no language (property 19). So a function cannot cross to the root service as terms. The console also checks a condition against the record description before the run, and completes its field names.

Anonymous functions serve `map` and the declarations. Inside `where`, `=` is the comparison of the condition, never a named argument: the parser reads the argument of `where` as a condition.

### The evaluation budget

No effect happens during an evaluation in mode `declaration`: no export runs, no network is read, no store is written, no recipe is built.

Recursion is allowed. Each evaluation, in either mode, has the evaluation budget: a fixed count of the steps of the evaluator. The work of an export that the evaluator calls is not a step of the evaluator. Past the budget, the evaluation stops with an error record that names the declaration or the line, its line and column, and the chain of fields that it forced. The budget counts steps, never a time, so one declaration gives the same error on every machine. In mode `console`, the exports that ran before the stop keep their effects, as when an export of a line fails today.

The budget is one constant of the evaluator, the same in both modes:

- A measure sets it when the evaluator first runs a declaration: the largest count of steps over the declarations of the system (the catalog declaration, the system plan and the project of this repository) and the lines of the console tests, with a margin that the measure states.
- The tool prints the count of steps of each of these declarations as a measure, never as a condition.
- A declaration cannot ask for more: a foreign declaration then takes the processor time that it wants, and the bound protects nothing. A declaration that needs more is a declaration to change, or a change of the constant, with its measure.

### Declaration inputs, pins and release pointers

A project or a plan names its declaration inputs in one record:

```
project {
  inputs = {
    modus = catalog,
    gt    = follow(publisher = keys.gui_toolkit, name = "gui_toolkit"),
    wren  = declaration(blake3:…),
  },
  outputs = { default = gt.window_app(here()) },
}
```

- `catalog` is the catalog declaration of the system: a declaration whose value is a record of recipes, modules and functions. It is one catalog declaration among others, the default, with no mechanism of its own.
- `declaration(hash)` names one exact declaration.
- `follow(publisher, name)` names the newest release pointer that a publisher signed for a name. A release pointer is a record: the name, a number that only grows, the hash of a tree, and the signature of the publisher. It does the work of a channel of Nix, with no server of authority.

The bytes and the trust are two separate things. The bytes of a declaration come from any source of the substitution policy, because a hash checks itself. The trust comes from the key of the publisher, which the principal names in `keys`, its table of the publisher keys that it trusts.

**When the resolution happens.** An evaluation never reads the network to resolve a name, because it has no effect. It uses the pins: a typed record with the hash of each declaration input as it was resolved, kept in the store of the project or in the plan.

- `update()` resolves each `follow` again, from the release pointers that the sources of the substitution policy give, and writes new pins. `update(inputs.gt)` resolves one.
- The store keeps the pins before as a version (property 9), so the pins of each earlier state of a project stay readable.
- An evaluation with an input that has no pin stops with an error record that names the input and the command `update(inputs.<name>)`.

The pins are no text file to parse. They are a typed record, versioned by the store, and the plan records the same hashes.

**Composition.** `with` has one meaning: the composition of two records. `a with b` gives the record `a`, with each field of `b` in place of the field of the same name. A field of `b` that `a` does not have is refused, as in a record literal ("A record literal is typed by its use"): the type of `a` receives `b`. So `catalog with { odin = recipe(…) }` changes one recipe.

A declaration input can give a function that changes a catalog declaration. It is called as any function: `gt.overlay(catalog)`, or `catalog |> gt.overlay()` ([pipe_operator.md](pipe_operator.md)). `gt.window_app(here())` is a call of the same kind.

An option of a command is a named argument, never a `with` after the call: `build(kernel, substitution = { mode = .Verify })`. A `with` after a call composes the record that the call gives; it changes nothing of the call.

### A foreign declaration is safe to evaluate

- The evaluation is pure, and it runs in the sandboxed evaluation process.
- A builder runs in a sandbox of its own ([recipes.md](recipes.md), "The builder").
- A realisation signed by a publisher that the principal does not trust is not used: the recipe is built on the machine, and its builder can change nothing but its empty output store.
- The grants of a foreign plan reach the machine only through the difference that the principal accepts at `apply`.

### Sources and the identity of a source

The identity of a source is the hash of a tree in a store. `here()` gives the tree of the current version of the store of the current environment, as a hash, so the source of a project is an object with a hash. The versions of property 9 give the history of a source.

Git is an import format and an export format, never a dependency:

- A git repository enters through the fetcher, as a hash given in advance: the commit gives a tree, and the recipe of the fetch holds the hash of its modus tree ([recipes.md](recipes.md), "The fetcher").
- Two machines exchange sources as they exchange modules: a sync of stores by hash, with the protocol of the cache. A tree is an object, as a module is.

### Environments

An environment is a record of names and grants that a child console starts with: `env { tools = {…}, stores = [store("kernel", .Read, .Write)] }`.

- `enter(e)` asks the root service to start a child console of the principal. Its command table holds the exports of the modules of `tools`, each by its hash, and its context holds a connection to each store of `stores`, with the rights of the record. Each such store is a store of the principal, and each right is a right that the console that asks already holds.
- `exit()` stops the child console and gives the line back to the console before.
- Nothing is installed. The modules of `tools` are objects of `module_files`, which a build or the cache gave. Another console sees none of these names.

### Projects

A project is a record with a source, its declaration inputs and its outputs: `project { source = here(), inputs = {…}, outputs = {…} }`. `project` is the function `modus.project` of the catalog declaration, under a short name (property 22): it adds no mechanism.

- `outputs.default` is the output that `build(p)` realises.
- Each other output is a field: `build(kernel.tools)`.
- `enter(kernel)` enters the field `environment` of the project. With no such field, the environment holds the builders of its outputs as tools, and the store of its source with Read and Write.

An output names an entry of the source tree by the names of its entries from the root of the tree, separated by `/`: `odin.module("src/modules/server")`. The evaluation process takes each name in turn; a name is never `.` or `..`, so the text never reaches above the source tree.

### Storage

- **The store `module_files` of the machine** holds the objects by hash: module files, debug objects, trees, release pointers, realisations. A tree is the list of the name, the kind and the hash of each entry, and its hash is the hash of that list ([recipes.md](recipes.md), "Trees").
- **The store `plans` of each principal** holds its applied plans, each as an object named by its number.
- **The disk grant table** of each principal holds the row "current plan".

### The garbage collector

The garbage collector of `module_files` keeps an object only when a root reaches it. The roots:

- each applied plan that the store `plans` of a principal keeps;
- the signed system description;
- the hash of each row of each disk grant table;
- the modules of each environment that runs, and the recipe of each build that runs.

From each root it follows the imports of each module, the debug object of each module, the entries of each tree, and the output of each realisation. It deletes the rest. An object that two principals reach is kept while one of them reaches it.

## The frequent tasks

| Task | Expression |
|---|---|
| Apply a system | `apply(system)` |
| Go back to the system before | `rollback()` |
| Go back to one applied plan | `rollback(4)` |
| Declare an environment | `kernel_dev = env { tools = { odin = catalog.odin }, stores = [store("kernel", .Read, .Write)] }` |
| Work in an environment, then leave it | `enter(kernel_dev)`, then `exit()` |
| Change one recipe of the catalog declaration | `catalog with { odin = recipe(…) }` |
| Change a catalog declaration with the function of an input | `gt.overlay(catalog)` |
| Build with an option | `build(kernel, substitution = { mode = .Verify })` |
| Declare a project | `kernel = project { source = here(), outputs = { default = odin.module("src/modules/server"), tools = …, image = modus.image([…]) } }` |
| Read a project from its source tree | `kernel = declaration(here())` |
| Build a project, or one output | `build(kernel)`, `build(kernel.tools)` |
| Work in a project | `enter(kernel)` |
| Resolve each followed input again | `update()` |
| Resolve one input again | `update(inputs.gt)` |
| See each pin, with its publisher and its hash | `inputs` |
| See the difference before a change of the system | `apply(system)`: the difference comes first |

**The check for an incantation.** Each expression names its task: `apply`, `rollback`, `enter`, `build`, `update`. None names a store of the system, a number of a format, a hash to copy by hand, or an order of two commands.

## The refused forms

- **Environment variables, `PATH` and shared configuration files.** They are ambient state that each process reads (property 8, property 19). An environment here is a record that one child console starts with.
- **A text file that a service reads at its start.** A parser of text in a service, against property 19 and [start_policy.md](start_policy.md). The root service reads the plan, a typed record.
- **A second language beside the console.** Two languages for one principal, against property 22. Lex grows by eight forms of grammar, with one parser and one evaluator.
- **A second parser for the declarations.** Two grammars drift, and a line that the console accepts then means another thing in a declaration. One parser library reads both.
- **Two evaluators (eager console, lazy declarations).** Two semantics of one text, which a test must compare form by form. One lazy evaluator in two modes gives one meaning: the arguments of an export are forced from the left before it runs, and mode `console` forces each line whole.
- **A console that forces only what its result needs.** An export whose result goes unused then never runs, and a line skips an effect that the principal typed. Mode `console` forces each line whole.
- **`with` for the options of a command.** `build(kernel) with substitution = {…}` gives `with` a second meaning, and the option lands after the call that it changes. A named argument is checked against the parameters before the call.
- **`with` on a function.** `catalog with gt.overlay` gives `with` a second meaning, the call of a function. A call says it.
- **A record literal with a type name, or with no type.** The first repeats the type of its receiver; the second accepts a field with a wrong name in silence.
- **An anonymous function in `where`.** The root service cannot turn a function into wiring terms, and runs no Lex ("`where` keeps the form of a condition").
- **A budget that a declaration asks for.** A foreign declaration then chooses its own bound ("The evaluation budget").
- **A budget set by hand.** A guess has no measure; the measure over the declarations of the system gives the bound and its margin.
- **The resolution of a name during an evaluation.** Such an evaluation reads the network, so two evaluations of one declaration can give two plans. The pins hold the resolution, and `update` changes them.
- **A text lock file.** The resolution is recorded as typed pins, versioned by the store, never as a text to parse.
- **A central registry of names that the system trusts.** A server of authority for every name. A release pointer is trusted by the key of its publisher, and its bytes come from any source.
- **The grants of a foreign plan applied with no view of their difference.** With it, a plan takes a grant in silence. `apply` shows the difference first.
- **A signature on each object.** A hash checks itself. Only a realisation and a release pointer are signed ([recipes.md](recipes.md)).
- **A store at a fixed place.** Property 11: a module holds no place, so the store `module_files` needs none.
- **Git as the identity of a source.** One source then has two identities, and the system depends on a tool that it does not need.
- **An apply that changes the processes that run.** A process that runs holds the handles of its start. A start, or the next start of the machine, gives one state.
- **A rollback that writes a new plan.** Two plans with one content, and a history that a reader must decode.
- **An evaluation in the console process.** A foreign declaration then runs in the process that holds the grants of the principal. The evaluation process holds none.

## Subtle points and hazards

- **The difference is computed by the root service.** The evaluation process runs foreign code; if it computed the difference, it can hide a grant. The root service compares the plan with its own copy of the current applied plan.
- **The commit is the write of the row.** `Apply` writes two stores: `plans`, then the disk grant table. A stop between them leaves a plan that no row names, which the garbage collector removes. It never leaves a row that names no plan.
- **An `Apply` against an old difference is refused.** The command holds the hash of the current applied plan that the principal saw.
- **A plan never names a module that the store lacks.** `Apply` checks the closure: each hash, each import, each debug object.
- **`here()` needs the hash of a tree.** Today a tree that changes has no hash ([`docs/glossary/storage.md`](../../../docs/glossary/storage.md), "Tree"). The design needs it ([recipes.md](recipes.md), "Trees").
- **A lazy record can refer to itself.** `outputs.image` can name `outputs.default`. A cycle with no end stops at the evaluation budget, with its chain of fields.
- **The plan of principal 0 is measured as the list of its start policy.** A plan with no start policy of its own changes no measure. Its disk processes are measured at their start, as today.
- **The store `module_files` of the machine is shared.** Two principals with one module store it once. A question `Has` from one principal tells it whether another holds an object: the cache protocol answers only for the objects that the principal of the connection reaches.

## Open questions

- **The merge of two versions of a store.** Two machines that change one source give two trees; how a principal merges them, and in which process.
- **Where the pins of a plan of a session live** when the plan has no project store: in the plan only, or in a store of the principal.
- **The form of the acceptance of a difference** at a console that a remote client drives: the same key, or a second proof of the principal.
- **The forced values of a declaration reference across lines.** The console evaluates a reference again on each line that needs it. An evaluation process that stays between the lines keeps the forced thunks, and holds their memory with no line that runs.
- **Where the default of a field is written.** A field of a contract record has no mark of a default today, so a record literal must give each field. The mark goes in the record description, or in the function of the catalog declaration that takes the record. The frequent tasks need it: `{ mode = .Verify }` takes the sources and the signers of the plan of the principal.
- **The bounds of a record literal and of a list at the console.** A call takes 12 arguments at most; a literal and a list have no bound of their own yet.

## The build order

Each layer adds one capability to a system that works, and each is a tested commit:

1. **The parser in one library package.** The parser leaves the console for one library package, with no change of behaviour: the same trees and the same refusals.
2. **The shared lazy evaluator in mode `console`.** It replaces the eager evaluator of the console, with no change of behaviour: each line is forced whole, and the effects run in the order of their data.
3. **The record literal, named arguments, `let`, `with`, and the placeholder `_` of `|>`.**
4. **Functions `(x) => …`**, used by `map`.
5. **Mode `declaration` and the evaluation process.**
6. **`module(...)`, `recipe` and `plan`**, and the evaluation budget measured.
7. **`apply` and `rollback`.**

## State

Designed, not built.
