# Declarations

A principal describes a system, a session, a project or an environment as one lazy value of the language of the console, in the manner of Nix. The evaluation of that value has no effect: it gives a typed record, the plan. An explicit command applies the plan, and the root service writes it as one applied plan, which a rollback can select again. The root service and the services never read the text of a declaration.

The terms are in [`docs/glossary/code.md`](../../../docs/glossary/code.md), "Plan", "Applied plan", "Declaration", "Catalog declaration", "Declaration input", "Pin", "Release pointer", "Project", and [`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md), "Environment", "Evaluation budget". The recipes that a plan names, the cache and the substitution policy are in [recipes.md](recipes.md).

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

Text exists only between the principal and the language of the console. The language has two readers, from one library module (property 10):

- **The console** reads the line that the principal types, as today.
- **The evaluation process** reads the text of a declaration object. The console starts it as a sandboxed child for each evaluation of a declaration: it holds a connection that reads only the trees of the declarations that the evaluation names, and nothing else. No network, no store that it can write, no root ring.

The console sends the evaluation process typed values only: the hash of a declaration, and the list of the field names to force. The evaluation process sends back typed values only: a plan, a table of recipes, a record of an environment, or an error record with its place. No line of the principal crosses to it, and no text comes back. The text of a declaration is a document that a principal wrote, as the source of a module is: a reader of its language reads it, as a compiler reads a source. No process sends text to another process for it to parse.

The root service and every service read the plan, a typed record, through one border of a contract package. None of them reads the text of a declaration.

### A declaration is an object

A declaration is a tree in a store, with its hash, as a module is. Its root holds one text object in the language of the console, whose value is one record. A project keeps its declaration in its source tree; a principal keeps the declaration of its session in a store of its own.

The value of a declaration is lazy: each field of a record is a thunk, which the evaluation forces only when a value needs it, and at most once. So `kernel.tools` forces the recipe of the tools and nothing of the image.

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

`plan { … }` is the only form of the language that describes an effect, and it has no effect by itself: it is a value. An explicit command applies it:

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

### The language: the console with five additions

The language of a declaration is the language of the console ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "The language of the console"), with five additions and no second language:

1. **`let` and record literals with thunks.** `let a = 1, b = a + 1 in { x = a, y = b }`. A field of a record literal can name the other fields of the same record, because each field is a thunk.
2. **Anonymous functions.** `(name) => odin.module(name)`. A function is a value; it can be a field, an argument and a result.
3. **A reference by hash.** `module(blake3:…)` is one exact module. `declaration(blake3:…)` is one exact declaration. A name of a catalog declaration, `catalog.odin`, is a field of its record; the plan records the hash that it gave.
4. **`recipe(builder, arguments)`.** A lazy value whose identity is its recipe hash. Forcing it does not build it: a build is a command ([recipes.md](recipes.md)).
5. **`plan { … }`.** The record of a plan, which `apply` takes.

No effect happens during an evaluation: no export runs, no network is read, no store is written, no recipe is built. A command with an effect is a command of the console line, outside the value: `apply`, `rollback`, `build`, `enter`, `exit`, `update`.

Recursion is allowed. An evaluation has an evaluation budget, a count of the steps of the evaluator. Past it, the evaluation stops with an error record that names the declaration, its line and column, and the chain of fields that it forced. The same declaration with the same budget gives the same error on every machine: the budget counts steps, never a time.

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

**Composition.** A declaration input can give a function that changes a catalog declaration: `catalog with gt.overlay`. `with` takes a record and either a record, whose fields replace the fields of the same name, or a function of a record. A function of a declaration input is called as any function: `gt.window_app(here())`.

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
| Change a catalog declaration with the function of an input | `catalog with gt.overlay` |
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
- **A second language beside the console.** Two languages for one principal, against property 22. The language of the console grows by five forms.
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
- **The bound of the evaluation budget**, and whether a declaration can ask for more.

## State

Designed, not built.
