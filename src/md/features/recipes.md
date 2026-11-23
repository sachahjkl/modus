# Recipes, builders and the cache

A recipe names how an output is made: a builder, its inputs and its arguments, each by hash or as a typed record. The root service realises a recipe in a sandbox, or a machine takes its realisation from a cache: a signed record that says which output the recipe gave. One rule, the substitution policy, chooses between the two, with no hidden configuration. The service `recipes` gives the commands, `recipes.build` and `recipes.provenance` ([declarations.md](declarations.md), "The services of the declarations").

The terms Recipe, Realisation, Builder, Guest builder, Fetcher, Substitution policy and Object cache are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); Tree hash is in [`docs/glossary/storage.md`](../../../docs/glossary/storage.md). The declarations that name the recipes are in [declarations.md](declarations.md).

## Purpose

A system is a list of hashes (property 11). A hash says which bytes run. It does not say how the bytes were made, so a reader cannot make them again, and a machine cannot check a module that it received. A recipe gives each output its cause. A realisation lets a machine skip a build that another machine made, and trust only the signature of the realisation.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": a builder holds only what it was given.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module": a builder is a plain module.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": the build is deterministic, and the identity of a module is its hash.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": a recipe and a realisation are records, and the cache protocol carries records.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": no network at start, a grant names the hosts.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": a key that one principal trusts is no grant for another.
- **The kernel gets no operation.** A builder is a process; its sandbox is the sandbox of every process.

## The chosen form

### The recipe

A recipe is three things:

- the hash of a builder module;
- an input table: a name and a hash for each input, sorted by name, with no name twice;
- an argument record: a typed record of the builder, which its module describes.

The recipe hash is the BLAKE3 hash of the builder hash, then of each input name and hash in the order of the table, then of the bytes of the argument record. The recipe hash is the identity of the recipe: two recipes with one hash are one recipe.

In Lex, `recipe(builder, arguments)` is a lazy value. Its inputs are the hashes that the evaluation of its arguments gives. Forcing it gives its recipe hash; it builds nothing.

### Trees

The output of a recipe is a tree, never one file: one module, several modules, a module and its debug object, a boot image, data. A tree here is the tree of the storage service, with a hash: the tree hash is the BLAKE3 hash of the list of its entries, each the name, the kind and the hash of the entry, sorted by name. A tree that never changes after its commit has one tree hash.

The output hash of a recipe is the tree hash of its output. `recipe(...).server` names the entry `server` of the output.

### The builder

A builder is a plain module that exports one function with a fixed contract:

```
build(inputs: Table(Build_Input, Read), arguments: Build_Arguments) -> Build_Status
```

- `Build_Input` is a record: the name of an input and its place in the input store.
- `Build_Arguments` is a record that the builder declares under that name, so its module file describes it. The console checks the argument record of `recipe(builder, {…})` against that description before any build.
- `Build_Status` is an enum, with an error record when it is not `Done` ([api/export_error_records.md](../api/export_error_records.md)).
- The output is not a parameter. It is the store "out" of the context of the builder.

The root service starts a builder in a sandbox:

- an input store: a clone of each input tree under its name, with the right Read only (a clone shares its blocks, so no byte is copied);
- an empty store "out", with Write and a limit of blocks that the recipe states;
- no network, no root ring, no other grant;
- a random seed equal to the recipe hash;
- a frozen date page: the root service gives the builder a date page with the date of its recipe, never the clock. The date of a recipe is the field `source_date` of its argument record when the builder declares one, and 0 when it does not. The frozen date page is new: today the date page of every process is the one page that the process `date` writes.

The sandbox of modus removes the ambient causes of a different output already: no global file system, no `PATH`, no environment variables, no network without a grant. When the builder returns `Done`, the root service commits the store "out", computes its tree hash, and writes the realisation.

### The realisation

A realisation is a signed record:

- the recipe hash;
- the output hash;
- the hash of the builder;
- the public key of the signer and its signature over the three hashes.

A machine signs the realisations of its own builds with the key of the principal that asked, and keeps them in `module_files`. A realisation is trusted when the key of a publisher that the substitution policy names signed it.

### The three kinds of builder

1. **A native builder**, such as `catalog.odin_build`, which wraps a compiler that is itself a module.
2. **The guest builder**, `catalog.linux_build`, which uses the guest of [guest.md](guest.md). It runs a minimal Linux whose image is an object by hash. The inputs enter as a read-only disk, and the output leaves as a blank disk, which the guest builder reads into the store "out". Its argument record holds the command to run in the guest: `run = ["cargo", "build", "--release", "--offline"]`. The text of `run` goes into the guest, a foreign world, and not between two modus processes, so property 19 holds. It builds with any existing tool at once.
3. **A builder of your own**: a small module that exports `build`.

### The inputs tree builder

One recipe runs no module: a recipe whose builder hash is `inputs_tree_builder_hash()` (the BLAKE3 key of the context `"modus builder inputs tree v1"`) gives one tree whose entries are its inputs, each under its name, a Blob as an object and a Tree as a tree. It takes no argument and gives a Tree only.

- **The recipes service builds it itself.** Its output is a function of the input table only, so no code of a caller runs and nothing needs a sandbox. A cache miss of such a recipe is a bounded step in the service: at most 32 entries, no network, no clock.
- **Why it exists.** It joins the outputs of several recipes into one tree, the output of a project with several parts, and it is the first recipe that `recipes.build` realises end to end before the root service starts builders in a sandbox.
- **Refused: a builder module for it.** A module that only joins hashes would need a start, a sandbox and a store "out" for 32 hashes, and its realisation would depend on the trust of its module hash. The service computes the same bytes with `tree_hash`, which each machine checks.
- **Refused: run any builder in the service.** Any other builder hash is refused with `Builder_Needs_Sandbox`: a builder runs foreign code, and only the root service starts it with the sandbox of "The builder".
- **The recipe of the inputs of a project.** `projects.build_recipe(project)` gives a recipe of this builder with one input for each pin of the project, a tree by the tree hash of the pin. `recipes.register` then `recipes.build` realise it, so the inputs of a project are one tree hash, and a moved pin gives another recipe.

### The recipe of a declaration

A declaration names a recipe with `recipe(module(builder), arguments)`; its hash is the hash of this service, `recipe_hash`, over the builder, the output kind, the source date, the input table and the argument bytes. One conversion of the contract, `plans_recipes.recipe_spec_of_arguments`, gives the record from the value: each first-level field that is a tree reference or a module file is an input with its kind, the other fields are the argument record ([application_projects.md](application_projects.md), "One identity for a recipe").

- **`register_evaluation`** takes the output of an evaluation whose value is a recipe, copies it into the memory of the service, converts it, and registers it under the hash that the evaluator wrote. `register` takes a recipe in its parts.
- **Its refusals**, each an error record with the refusal as its value: `Untyped_Hash` (a bare hash), `Nested_Input` (a tree or module file below the first level), `Not_A_Recipe` (another value, or a refused evaluation), `Damaged_Recipe` (bytes that do not decode, a form that is not canonical, a written hash that is not the hash of the record), `Unsupported_Argument` (a recipe, a follow, a store, a plan or a project among the arguments, a `source_date` that is not an integer of 0 or more).

### The local store of the realisations

The step 1 of the substitution policy reads the local store. The recipes service keeps it in its memory and in its private store: one object for each realisation, `realisation_` and the first 52 hexadecimal digits of the recipe hash (the name of an entry of a store has at most 64 bytes). The object holds the realisation record, its origin (a local build or a cache) and the bytes of its output.

- **The write comes before the memory.** A build or a fetch writes the object, then the memory takes the realisation. A store that refuses the write records nothing: the build is refused with `Store_Failed`, and the next build of the recipe builds again.
- **A read after a start checks the object whole.** At a miss in its memory, a build in a mode that takes the cache reads the object, checks the recipe hash against the one that it builds, the output kind, and the hash of the output bytes against the output hash, and takes it into the memory with no build. A damaged object is refused with `Store_Damaged`, and nothing builds: a store that gives a wrong output is a fault to read, not a miss.
- **Refused: one object for the realisation and one for the output.** Two writes, and a stop between them, leave a realisation that names an output that the store does not hold.

### The fetcher

The fetcher is the one builder with the network. Its argument record holds an address and the hash of the output, given in advance. Its network grant names the host of the address and nothing else. It refuses an output whose tree hash is not the hash given in advance: the root service discards the store "out" and writes no realisation.

Its realisation needs no signature: the recipe holds the output hash, so each machine checks it.

**Git enters through the fetcher.** `git_fetch(address, commit, tree)` reads a git repository, takes the tree of the commit, writes it as a modus tree, and checks that its tree hash is `tree`. Git is an import format and an export format, never a dependency of the system ([declarations.md](declarations.md), "Sources and the identity of a source").

### The substitution policy

The order of the realisation is a rule with no hidden configuration. For each recipe R that a command needs, in order:

1. The store `module_files` holds a realisation R → H and the objects of H: use it.
2. Else, ask each source of the policy, in its order, for `Realisation(R)` signed by a key that the policy trusts, then fetch H by `Object`, which checks itself.
3. Else, build R in the sandbox.

The policy is a typed record, `Substitution`:

- `sources`: the endpoints of the object caches, each with its key;
- `trusted_signers`: the keys whose realisations it trusts;
- `mode`, a member of `Substitution_Mode`.

The modes:

- `Prefer_Cache`, the default: the order above.
- `Build_Only`: no realisation of another machine is used. It is the mode of a bootstrap and of a verifier.
- `Cache_Only`: never build. A small device refuses a recipe that no source has, with an error record that names the recipe.
- `Verify`: use the cache, build too, and compare. A disagreement is the log fact `Realisation_Disagreement`, with the recipe, the two output hashes and the signer.

The policy has one place, never a global file:

- The plan of each principal holds its `Substitution`. The plan of principal 0 holds the policy of the system plan.
- A named argument of `recipes.build` changes it for one build: `recipes.build(kernel, substitution = { mode = .Verify })` ([declarations.md](declarations.md), "A record literal is typed by its use").
- The plan records, for each realisation that it uses, its source and its signer, so an audit reads where each output came from.
- A key that a principal trusts is valid for that principal only. The system plan trusts the publisher of the system alone.

### The object cache and its protocol

An object cache serves two things:

- **objects by hash**, which check themselves, so any transport works, also one that nobody trusts;
- **realisations and release pointers**, the only things that are signed.

The protocol runs over QUIC, as `remote` does, with records and no text. The client pins the key of the endpoint that the policy names. Each request is one record, and each answer is one record and its bytes:

| Request | Answer |
|---|---|
| `Object(hash, offset, count)` | the bytes of the range, or `Absent` |
| `References(hash)` | the hashes that the object names: the imports of a module, the entries of a tree, the output of a realisation |
| `Realisation(recipe)` | the signed record, or `Absent` |
| `Release_Pointer(publisher, name)` | the newest signed release pointer, or `Absent` |
| `Has(hashes[64])` | a bitset of 64 bits |

**What runs today is not this form.** `modustool cache-serve` speaks binary frames over TCP (`modus:contract/object_cache`): a request starts with the magic `MOCQ`, an answer with `MOCR`, then a version, a kind, a status and a body length. Its requests are `Has`, `Get_Object` (a whole object, no range), `Get_Realisation`, and `Put_Object` and `Put_Realisation`, which need a key of `--authorized-key` and its signature. QUIC with the key of the endpoint pinned, the ranges of `Object`, `References` and `Release_Pointer` are the planned form, and no machine of `modus` reads an object cache over the network yet. The page of a public object cache is [../infrastructure/public_object_cache.md](../infrastructure/public_object_cache.md).

An object cache can be a mirror that nobody trusts, a peer on the local network, or a removable disk. The trust never comes from the source: it comes from a hash, or from the key that signed a record. Two machines exchange their stores with the same protocol, as an object cache of each other.

### Two machines compare

A machine in the mode `Verify` builds a recipe that it also fetched. The same recipe with two output hashes is the log fact `Realisation_Disagreement`. A disagreement is a fault of the recipe or of a builder, which a developer reads to its cause, as a distinct result of the build is today ([`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "6. What is proved, and what is not").

### Builds across paired machines

A principal with several machines builds a graph of recipes on all of them: a laptop asks the machine at home, with its large disks and its many cores, to build, and asks a paired machine that holds the realisations to give them. The **distributed builder** (`internal:recipes/recipes_core`, `distributed_builder.odin`) schedules such a graph. It is a pure state machine over the outbound link of [several_machines.md](several_machines.md), "The outbound link": it reads no clock and allocates nothing.

- **The graph.** At most 32 recipes, each added after the recipes whose outputs it takes (`dag_recipe_add`): a dependency names an earlier recipe and an input of this one. So the graph has no cycle by its order, and the check is one comparison. Before a recipe runs, each such input takes the output hash of its producer, after the scheduler computed that hash again over the kept bytes; an input whose kind is not the output kind of its producer is refused.
- **The pool.** At most 4 machines, each a builder or a cache. Each must be a paired machine, and the plan must give this machine the uses `Roles` and `Objects` of it; else the pool is refused before any work (`Peer_Not_Paired`, `Peer_Lacks_Use`).
- **The rounds.** A round takes each recipe whose producers are done. In the modes `Cache_First` and `Cache_Only`, it reads the local store, then asks each cache by a role call `Realisation_Lookup` of the role `Recipes`, then (in `Cache_First`) gives the recipe to the next builder in turn by a role call `Build`, then builds it on this machine. `Build_Only` builds on this machine only. So two leaves of one round go to two builders.
- **Nothing is kept before its checks.** A realisation of another machine must name the recipe and its output kind, and carry a signer of the policy and a signature that verifies. Then the output is fetched by `Object_Request` from the same machine, and its BLAKE3 hash or its tree hash must be the output hash. A cache whose signer is not trusted is passed over in `Cache_First`, as the local pipeline does, and refused in the other modes. A changed bit of an output is `Hash_Mismatch`, and no byte of it is kept.
- **One faulty cache never stops a build.** A cache that gives a realisation that does not decode, names another recipe or kind, or has a bad signature, that withholds the output, or whose output does not hash to its output hash, leaves the run and is counted (`cache_faults`). The next cache, then a builder, then this machine gives the output. `Cache_Only` with no hit names the last fault, not `Cache_Miss`, so the fault is still read. Refused: the end of the whole build at the first faulty cache. A cache is a machine that the principal paired for speed, not for trust, and its output passes the same checks from any source; ending the build lets one cache refuse every build of the principal.
- **A lost builder.** A build call that ends `Unknown_Outcome` or `Unreachable` can have run. A build is a function of its recipe, so the recipe goes to the next builder, and then to this machine; the lost builder takes no more work in this run. A builder that refuses the call (`Use_Not_Granted`, `Role_Refused`) leaves the run the same way. A recipe that no machine built is `No_Builder`, and each recipe that needs its output is `Dependency_Failed`.
- **`Verify` across machines.** Two distinct machines build the recipe: two builders, or a builder and this machine; the second build excludes the first builder, the pool refuses a key twice, and the scheduler checks once more that the two keys differ. Each remote output passed its realisation check and its hash check, and both outputs are hashed again over the kept bytes before the comparison. Two output hashes refuse the recipe with `Determinism_Mismatch`, with both hashes and both machines in its result. One machine alone cannot verify: a pool of one builder with no builder on this machine, or a second builder that fails during the build with none on this machine, is `Verify_Needs_Two_Machines`, and nothing is kept.
- **The holder on the other machine.** `remote_recipes_serve` answers the two exports for a paired machine: `Build` reads a recipe at its border (`remote_build_arguments_read`: each count against its bound and its bytes, each reserved byte zero, then the validation of the recipe), builds it in the sandbox, signs its realisation and publishes its output by hash; `Realisation_Lookup` gives a realisation of the local store. A recipe whose arguments pass the 1024 bytes of one role call is built on the machine that asks.

**Refused: a scheduler with threads and a queue of the network.** The rounds and the turn of the builders give the same order of work on each run, so a test replays it. The transport of the link answers each call; `remote` keeps several streams of one link in flight.

**Refused: a retry of a refused realisation on the next machine.** A wrong signature or a changed byte says that a machine or a path is hostile; the result names it, and the principal decides.

**Refused: a builder that a principal did not pair.** A build service open to the network would run the recipes of anyone on the machine of the principal.

### A proposed change of property 11

This is a proposal, not a rule. Property 11 keeps its text until a change of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md) takes it.

> **Rule (proposed)**: each module of the list of a system has a recipe, and its realisation can be built again. The system description names, beside the hash of each module, its recipe hash. A module with no recipe is a module that no machine can check.

## What this takes from Nix and what it does not

Nix has:

- `nix.conf`, global, which root edits;
- a daemon that runs as root;
- a trust of a whole store, in place of a trust of each realisation;
- derivations as text files (ATerm);
- a fixed place, `/nix/store`;
- a sandbox to build, on Linux;
- a separate language.

modus has:

- a typed policy in the plan of each principal;
- no daemon with authority: a builder is a process with handles;
- a trust of each signed realisation;
- a recipe as a typed record whose hash is its identity;
- no place;
- the sandbox as the default of every process;
- Lex, the language of the console.

The ideas taken from Nix are the closure, the content address and the substitution. The design is not a copy.

## The frequent tasks

| Task | Expression |
|---|---|
| Build an output | `recipes.build(kernel)` |
| Build with no cache | `recipes.build(kernel, substitution = { mode = .Build_Only })` |
| Check a cache against a local build | `recipes.build(kernel, substitution = { mode = .Verify })` |
| See where each output of the system came from | `recipes.provenance(system)` |
| Fetch a git repository at one commit | `git_fetch("https://…", commit = "…", tree = blake3:…)` |
| Name the output of a guest build | `catalog.linux_build({ inputs = { source = here() }, run = ["cargo", "build", "--release", "--offline"] })` |
| Name one entry of an output | `recipe(…).server` |

## The refused forms

- **A recipe as a text file.** A reader parses it, and two writers print it in two ways. A recipe is a typed record, and its hash is over its bytes.
- **A trust of a whole store or of a whole cache.** One bad source then gives every output. A realisation is trusted one at a time, by its signer.
- **A signature on each object.** A hash checks itself.
- **A daemon with authority that builds for everyone.** A builder is a process with the handles of one recipe.
- **A builder with the network.** Its output then depends on the network at the time of the build. Only the fetcher has it, and its output hash is given in advance.
- **A fetch with no hash given in advance.** Its output is what the network gave that day.
- **A global configuration of the cache.** The policy is in the plan of each principal.
- **The output as one file.** A build that gives a module and its debug object, or several modules, then needs several recipes.
- **A key that one principal trusts, valid for the machine.** A principal then grants its trust to the others.
- **The clock in a builder.** The date in the output then changes at each build.
- **Git inside the system as the identity of a source.** Two identities for one source.
- **Text in the cache protocol.** Each side then parses the text of the other (property 19).

## Subtle points and hazards

- **The builder contract keeps the border rule.** An export takes no slice by value and no address in a record ([api/library_modules.md](../api/library_modules.md), and [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Tables and bytes as parameters"). So the inputs are a table parameter, the arguments a record, and the output a store of the context.
- **The bytes of an argument record are canonical.** A record of the system holds no padding and no handle, and a Text field is filled with zeros past its length. So one argument value gives one recipe hash.
- **The sandbox does not make a builder deterministic.** A builder can read the cycle counter, the order in which its threads run, and `rdrand`. The kernel does not hide them. A recipe is checked by comparison (`Verify`, two machines), not by a proof.
- **The seed of a builder is public.** It is the recipe hash. A builder that needs a secret is a fault: an output must not depend on a secret.
- **A fetch is the only realisation that needs no signer.** Its recipe holds its output hash.
- **`Has` tells a source which objects a machine wants.** A machine that does not want to tell asks only the sources that it trusts with that fact.
- **A realisation of a builder that has a fault is still signed.** The signature says who built it, not that it is right. `Verify` finds a disagreement; it does not say which side is right.
- **The guest builder trusts its Linux image.** The image is an object by hash, so the recipe names it; its own build is a recipe of the bootstrap ([bootstrap.md](bootstrap.md)).

## Open questions

- **The date of a recipe**: a field of the argument record, as above, or a fourth part of the recipe.
- **The key that signs the realisations of the publisher of the system**: the release signing key, or a key of its own.
- **Whether the garbage collector keeps the inputs of a realisation** when a plan keeps its output.
- **The bound of the blocks of the store "out"**: stated in the recipe, or from the budget of the builder module.

## State

Built: the binary wire protocol, signed realisations, substitution policy, host cache server, the `plans`/`recipes`/`projects` contracts and delegated service modules, and the sandboxed guest builder layer. `src/library/modus/contract/object_cache` defines the closed wire enums (`Cache_Request_Kind`, `Cache_Response_Status`, `Cache_Object_Kind`, `Substitution_Decision`, `Substitution_Mode`, `Wire_Refusal`), strict binary framing (`encode_request`, `decode_request`, `encode_response`, `decode_response`), the `Realisation_Record` with domain-separated canonical signing bytes (`"modus realisation v1"`), and the pure `substitution_check` that trusts content-addressed blobs and trees by recomputing BLAKE3 or `tree_hash` with no signer and requires an explicit trusted Ed25519 signer for realisations. `src/library/modus/contract/plans_recipes` adds `Recipe_Spec`, input-order-independent domain-separated BLAKE3 `recipe_hash` (`"modus recipe v1"`), `Build_Mode` (`Cache_First`, `Build_Only`, `Cache_Only`, `Verify`), `Builder_Sandbox_Spec` (read-only inputs, empty output store, frozen `source_date`, zero network, seed equal to `recipe_hash`), and strict cache realisation verification against `object_cache.Substitution_Policy`. `src/library/internal/recipes/recipes_core` implements the local-store -> remote-cache -> sandboxed-builder -> `tree_hash` -> provenance pipeline, wired into the freestanding `src/modules/system/recipes` service. `src/library/modus/contract/guest_builder` defines the fixed-layout `Guest_Build_Spec`, closed border enums (`Guest_Build_State`, `Guest_Disk_Role`, `Guest_Builder_Refusal`), the canonical `MODGBD1` disk image format (`pack_input_disk`, `unpack_output_disk`) with exact recursive `tree_hash` extraction, and the pure `Guest_Sandbox_Runner` enforcing read-only input disks, zero network, frozen epoch time, and exit-code-0 output extraction; `src/modules/system/guest_builder` wires that contract to `Guest_Run` in a freestanding module. `tools/modusto... (line truncated to 2000 chars)

Built with the exports of the services: `src/library/modus/contract/plans_recipes/service_records.odin` holds the rows that the exports take and give (`Recipe_Head`, `Recipe_Input_Row`, `Recipe_Reference`, `Recipe_Build_Row`, `Realisation_Row`) with the border `recipe_spec_of_parts`, and the inputs tree builder (`inputs_tree_builder_hash`, `inputs_tree_build`). `src/library/internal/recipes/recipes_core/registry.odin` keeps the registered recipes by hash (16 at most) and the newest 32 builds. The service `recipes` exports `register`, `register_evaluation`, `build`, `cache_lookup`, `builds` and `realisations`: a build in a mode that takes the cache gives a realisation of the local store with no build, and a miss of an inputs tree recipe builds, keeps its output and its realisation, so the next build of it is a hit. The guest builder exports `status` and `disks_check`, which checks a spec, its read-only input disk and the bound of its blank output disk with no guest. Each has host tests of its refusals.

Built with the private store: each realisation is an object of the private store of `recipes` ("The local store of the realisations"), read back and checked after a start, so a build of a recipe that the service realised before builds nothing; `projects.build_recipe` gives the recipe of the inputs tree of a project. Host tests check the hit after a start, the determinism of the recipe hash, each damage of a stored object, a store that refuses the write, and the refusals of a corrupt recipe.

The guest builder boots a Linux kernel of 64 bits (a bzImage or a vmlinux whose BLAKE3 hash is `kernel_hash`) in its guest by the boot protocol of Linux, with the machine of [foreign_systems.md](foreign_systems.md), "The machine of a Linux guest": a serial port and a virtio console, the inputs as a read-only virtio disk, and the output as a blank writable virtio disk. The command of the spec goes to init after `--` on the command line; the guest ends a build with its exit status on the port `Build_Exit_Status`. The report gives the BLAKE3 hash of the whole output disk beside the tree hash of its MODTREE1 extraction. Checked by host tests only. One of them runs a whole build through the loop of the builder: a program of 64 bits that boots by the boot protocol, on the software processor of `modus:contract/software_machine`, reads its input disk, writes its output disk and exits with 0, and the builder gives the tree hash of the disk that the host packed; a write of the program to its input disk refuses the build ([foreign_systems.md](foreign_systems.md), "State"). The spec can name an initial archive by its BLAKE3 hash and its size; the builder checks the hash on its copy in the memory of the guest before the boot, so a kernel of Nixpkgs runs the `init` of the recipe ([foreign_systems.md](foreign_systems.md), "The chosen form").

Built in `recipes_core`: the distributed builder of "Builds across paired machines", with a host test of four machines in memory (a laptop, two builders, a cache) that realises a graph of six recipes, takes one from the cache with no build, gives two leaves of one round to two builders, refuses a changed bit, an untrusted signer and a bad signature, passes over a cache that withholds its output or gives a bad realisation to the next cache, a builder or this machine, moves a recipe to the second builder when the link of the first breaks during its build, falls back to this machine, and refuses a builder that is not deterministic with `Determinism_Mismatch`.

Left: the connection of the service `recipes` to the outbound links of `remote`, which the root service gives, so that `recipes.build` runs a distributed build on a machine; the grant Store of the service `recipes` at its start ([declarations.md](declarations.md), "State": until then a realisation is refused with `Store_Failed`), live sandboxed builder and fetcher process invocation from `recipes` (the root service starts a builder module in a sandbox; until then any builder but the inputs tree builder is refused with `Builder_Needs_Sandbox`), the signature of a local realisation with the key of the principal, a machine test that boots Linux inside the guest builder, the QUIC cache client inside modus, console wiring for `recipes.build`/`recipes.provenance`, and deployment of the public cache at `cache.modus.froment.software`.
