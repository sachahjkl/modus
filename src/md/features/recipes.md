# Recipes, builders and the cache

A recipe names how an output is made: a builder, its inputs and its arguments, each by hash or as a typed record. The service `recipes` realises a recipe in a sandbox, or a machine takes its realisation from a cache: a signed record that says which output the recipe gave. One rule, the substitution policy, chooses between the two, with no hidden configuration. The service `recipes` gives the commands, `recipes.build` and `recipes.provenance` ([declarations.md](declarations.md), "The services of the declarations").

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
build(inputs: Table(Recipe_Input_Row, Read), arguments: Bytes) -> Integer
```

- **inputs**: one row for each input of the recipe, in the order of their names: the name, the kind (a tree or an object) and the hash. The objects of each input are in the input store under their hexadecimal hash, so the hash of a row is its place in the input store.
- **arguments**: the argument record of the recipe, in the canonical form of the output of an evaluation (`declaration_eval`), which the builder reads with `Output_Reader`. The evaluator writes this form and the recipe hash covers it, so a second encoding of the arguments would be a second identity of one recipe.
- **The result** is 1 when the store "out" holds the output, or a negative number with an error record ([api/export_error_records.md](../api/export_error_records.md)).
- The output is not a parameter. It is the store "out" of the context of the builder.

**The service `recipes` starts a builder** as a call host: the module `host` of the boot image, with the file of the builder mapped read-only, as the console starts a module with `isolate`. The kernel gives a process only the handles that its starter gives it, so a call host of `recipes` has the same sandbox as a process of the root service. The context of a builder (`modus:contract/builder`) holds:

- the call ring and the call region, as each call host;
- an input store: a share of the place `build/in` of the private store of `recipes`, with `read_only`: a copy, by clone, of the objects of each input and of nothing else;
- the store "out": a share of the place `build/out`, empty, that can be changed; a share never reaches above its root;
- the storage service with Read, and the file of the storage service, which describes its exports. The handles of a share carry Give, and the term `store_gives` of the start grant set of `recipes` gives it the storage service with Give, so the service can pass both on;
- the log;
- a seed equal to the recipe hash, with the strength `None`: the seed is public, so the random generator refuses to make a key from it;
- no date page: a read of the date gives no date. The date of a recipe is the field `source_date` of its arguments.

No network, no root ring, no boot image, no window, no other grant: none has a slot in the context.

**What the sandbox does not take away yet**, each an entry of `ROADMAP.md`:

- **The clock.** The kernel maps the time page in each process, and the processor gives its cycle counter, so a builder can read a time and write it in its output. The date page is not mapped; the time is.
- **A limit of blocks of its own.** The store "out" is a share of the store of `recipes`, with its limit. A builder can fill that store; at the limit, a write of `recipes` frees the oldest versions of its objects to make room. The output of a build stays in the place `objects`: no collection removes an output that no realisation names.
- **The places of the storage service.** The 512 places are one table of the service. A builder can hold each of them, for up to the bound of a build, and other callers then get Full until its call host ends.

**One build.** The service prepares the place `build` (`in` with the objects of the inputs, `out` empty), makes the two shares, starts the call host and calls `build`, with a bound of `BUILD_TIME_BOUND_MILLISECONDS`. Then, whatever the outcome, it ends the call host and the two shares. Only then, after a result of 1, it freezes `build/out` into the place `objects` (`storage.freeze_tree`): the output hash is the tree hash that the storage service computes over the store, never a claim of the builder. The canonical bytes of the root tree of the output are the output of the pipeline, and the place `objects` keeps each object of the tree, so a later recipe takes the output as an input.

**What a builder cannot do**, each with its refusal:

- **change its inputs**: the input store reads only, and the storage service refuses each change with `No_Grant`;
- **write outside its store "out"**: the share of `build/out` has no name above its root;
- **reach the network or the root service**: it holds no handle of either;
- **run past the bound**: the service ends the call host, refuses the build with `Builder_Timed_Out`, and keeps nothing;
- **fail, or stop**: a negative result, a refusal of the call, or a process that stops is `Builder_Failed`, and nothing is kept;
- **give an output whose hash differs**: a builder gives no hash; the service freezes the store after the call host and the shares ended, so the hash is the hash of what stays. A build of `Verify` whose output differs from the realisation of a cache is `Verify_Disagreement`: no realisation is written, but the objects of the output stay in the place `objects`, frozen before the comparison.

The refusals before a start: a builder that no module of the boot image is (`Builder_Absent`), an input whose objects are not in the place `objects` (`Input_Absent`), and a step of the stores that fails (`Store_Failed`).

The sandbox of modus removes the ambient causes of a different output already: no global file system, no `PATH`, no environment variables, no network without a grant. It does not remove the clock yet (above).

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

- **The recipes service builds it itself.** Its output is a function of the input table only, so no code of a caller runs and nothing needs a sandbox. A cache miss of such a recipe is a bounded step in the service: at most 256 entries (`MAX_RECIPE_INPUTS`), no network, no clock.
- **Why it exists.** It joins the outputs of several recipes into one tree, the output of a project with several parts, and it was the first recipe that `recipes.build` realised end to end, before builders ran in call hosts.
- **Refused: a builder module for it.** A module that only joins hashes would need a start, a sandbox and a store "out" for 32 hashes, and its realisation would depend on the trust of its module hash. The service computes the same bytes with `tree_hash`, which each machine checks.
- **Refused: run any builder in the process of the service.** Each other builder runs foreign code, so `recipes` starts it in its own call host with no grant, with the sandbox of "The builder". The guest builder runs its foreign code in a guest ("The guest builder in the service").
- **The recipe of the inputs of a project.** `projects.build_recipe(project)` gives a recipe of this builder with one input for each pin of the project, a tree by the tree hash of the pin. `recipes.register` then `recipes.build` realise it, so the inputs of a project are one tree hash, and a moved pin gives another recipe.

### The guest builder in the service

A recipe whose builder hash is `guest_builder_hash()` (the BLAKE3 key of the context `"modus builder guest linux v1"`) builds in a Linux guest that the service `recipes` makes. Its argument bytes are one guest build spec (`guest_builder.encode_build_spec`): the kernel, the initial archive, the memory, the command, the frozen time, the bound of the output, the bound of the exits and the time bound. The inputs of the recipe are the inputs of the build: the spec names no mount of its own, and a spec that names one is refused with `Damaged_Recipe`. The guest image of the machine test is [guest_build_image.md](guest_build_image.md).

A build takes these steps, each in `recipes_core` (`guest_builder_bridge.odin`), the memory, the store and the thread in the service (`guest_build.odin`):

1. The checks of the spec: the frozen time is the source date of the recipe, the guest gets zero network devices, and the bound of the output disk fits the blocks of the recipe. A spec whose output bound passes the blocks of the recipe is refused with `Output_Too_Large`, never cut; a recipe with a block limit of 0 sets no bound of its own, and the bound of the spec holds alone.
2. The guest is prepared before any input is read: its memory and its nested page table against the pages that the budget of the service has left (`Memory_Past_Bound`), then its kernel and its initial archive from the store by their hashes (`Cache_Miss` when the store lacks one).
3. Each input is read from the private store by its hash, and its bytes must give that hash. A blob becomes one file under its name; a tree becomes each file under it, under its full path, to the depth of `MAX_PATH_DEPTH`.
4. The files are sorted by path and packed into one read-only MODGBD1 disk. The output disk is blank.
5. The guest runs on `Guest_Run` through `modus:guest_regions`, the same loop as the module `guest_builder`, on the build thread of the service.
6. The build ends with exit status 0, the output disk unpacks to a tree, and each file and each directory node of that tree is kept in the private store by its hash. The realisation then names the tree hash.

Each other end refuses the build, and no realisation is kept: an exit status that is not 0 (`Builder_Failed`), an output disk that is no MODGBD1 disk (`Malformed_Output`), a write past the bound of the output disk (`Output_Too_Large`), the bound of the exits or the time bound (`Builder_Timed_Out`), a write to the input disk or an input disk whose hash changed during the run (`Sandbox_Violation`), an input that the store lacks (`Cache_Miss`) or whose bytes do not give its hash (`Hash_Mismatch`).

- **The service runs foreign code only inside a guest.** "Refused: run any builder in the service" still holds: no builder module runs in the service. The code of a guest build runs on a guest processor, with no device but its two disks, its serial port and its console, and the service reads its output as hostile bytes.
- **Two bounds end a guest that does not end.** The bound of the exits of the spec counts the exits that the guest causes, the same in each run of one spec. A guest that never exits by itself (its interrupts off, a jump to itself) gives only the exits Interrupted of the timer of the host, which count in no bound of the exits: their count depends on the speed of the host. The time bound of the spec (`time_bound_seconds`, 0 for `DEFAULT_BUILD_TIME_BOUND_SECONDS`, at most `MAX_BUILD_TIME_BOUND_SECONDS`) ends it on the clock of the system, from the start of the guest. It is a deadline of the contract of a build, not the hang bound of a test. Each exit counts in `guest_runs`, a measure in the log.
- **The build thread.** A build of a guest recipe runs on a second thread of the service, so the service answers each other call while the guest runs. `recipes.build` of such a recipe answers `Building` at once, and the history (`builds`), the realisation (`cache_lookup`) and the log give its end; a command of the delegated ring gets its completion at the end. One lock guards the state of the service, the queue and its store client: the service thread holds it for each call and each ring command, and the build thread for its build, except while the guest runs. The build thread says that it ended before it leaves the lock, so a call that waited for the lock never takes the ended build for a running one. `Cache_Only` never builds and answers in the call. Refused: the build in the call of the service thread, which leaves each other call of the service without an answer for the time of a build; a guest build in a process of its own, which needs a starter and a second store client for what one thread does.
- **The queue of the guest builds.** One guest build runs; at most `GUEST_QUEUE_MOST` (8) are held, running or waiting, and each principal holds at most `GUEST_QUEUE_PER_PRINCIPAL_MOST` (2) of them (`guest_queue.odin`). A build past either bound is refused with `Builder_Busy`, and nothing changes. At the end of a build, the next is the oldest build of a principal other than the one whose build just ran, when one waits: a principal that queues many builds does not keep the builder from the others for longer than its own two builds. `recipes.build_cancel` cancels a build of the principal of the caller, by its recipe hash: a waiting build leaves the queue, and a running build ends at the next exit of its guest, refused with `Build_Cancelled`. A build of another principal gets the answer of no build, `Unknown_Recipe`, so a caller learns nothing of the builds of others; the builds of the delegated ring are of no principal and no call cancels them. A build whose thread does not start ends refused with `Builder_Failed`, and the history keeps its row. Refused: more than one guest at once. Each guest build takes most of the budget of the service, and a second one would halve the memory of each.
- **The memory of a guest build follows the budget.** The service states the budget of one build of a typical guest: 128 MiB of guest memory, its nested page table and its process, a kernel of 16 MiB, an archive of 4 MiB, an output disk of 32 MiB and two input buffers of 8 MiB, beside the pages of the service and of one builder that it starts, and the stack of the build thread. The starter grants up to the largest budget of a process, a share of the memory of the machine ([module_budget_request.md](module_budget_request.md)). No row of the root service gives it pages, and no buffer is fixed: each build plans its buffers (`guest_build_plan`) from its spec, the sizes of its kernel and its archive in the store, and the pages that the granted budget has left, less a reserve of the service (`SERVICE_RESERVE_PAGES`) and the records of the guest process (`GUEST_PROCESS_RESERVE_PAGES`). The guest, its table, its kernel, its archive and its output disk are what the spec asks; the two input buffers take the rest, half each, from 1 MiB up to the most of an input disk. A build whose fixed needs do not fit is refused with `Memory_Past_Bound` before anything is made, and its buffers go back to the budget at its end. So a smaller machine runs each guest build that its share holds, and a larger one gives larger inputs. The memory of the guest is never cut below its spec: it is a part of the recipe, and a build with less memory is another build.
- **A failed build keeps nothing.** Each object that the keep of the output wrote, and that the store did not hold before, is removed when the keep fails. A realisation that the store refuses after the keep leaves objects that nothing names, which the next pass of the retention removes.
- **`recipes.put` keeps an object by its hash.** A blob or a canonical tree of at most 32 KiB goes into the private store, so a recipe names it as an input. A principal keeps at most `PUT_OBJECTS_PER_PRINCIPAL_MOST` (256) objects in one window of an hour (`Put_Quota_Reached` past it), whichever connection it calls from, and the service counts 16 principals in a window. A kernel or an initial archive of more than 32 KiB reaches the store by a writer of the store, as the machine test writes the data disk.
- **A recipe kept in the store registers at its first build.** A writer of the store keeps a recipe as the object `recipe_<hash>` (the recipe object of the cache, `recipe_object_encode`: its magic, then the canonical bytes of the recipe); `recipes.build` of that hash reads it, checks that it decodes to the hash, and registers it. `recipes.build_stored` takes the hash as 64 hexadecimal digits, the form in which the console types a hash: a record with a hash field has no command that makes it.
- **Objects larger than one call.** The port of the private store reads and writes a whole object of any size in ranges of at most the bytes of one call (`storage_port.read_large`, `storage_port.write_large`): a kernel of 13 MB and an output file of any size. A write commits in steps of 1 MiB and sets the size at its last commit; a write that fails drops its pending changes. Each writer of the port names an object by the hash of its bytes, or writes its head after it, so a reader checks what it reads. Refused: a second copy of these loops in the contract (`plans_recipes`), beside the port: one implementation of each operation.

### The retention of the store

The objects that a guest build keeps and that `put` keeps are named `blob_<hash>`. One pass (`retention.odin`) marks each object that something names, to the leaves of its trees: each realisation object of the store (its output), each recipe object of the store and each registered recipe (its inputs, and the kernel and the initial archive of a guest spec), and each put of the window of now and of the window before. Then it removes each object `blob_` that is not marked. The realisations and the recipes stay. A mark and a walk are apart: a tree that one namer marked is still walked when another names it as a tree, so its children stay whatever named it first; a put names an object of any kind, which the pass reads to know if it is a tree.

- **When.** At the start of the service, and at the end of each guest build, under the lock of the state.
- **Its bounds.** At most `RETENTION_MARKS_MOST` (16 384) marked hashes and trees of `RETENTION_DEPTH_MOST` (16) levels. A pass that passes a bound, or that cannot list or read the store, removes nothing: a pass never removes an object that it could not prove unnamed.
- **A put lasts two windows.** An object of `put` that no recipe names stays for the window of its put and the window after, then the next pass removes it.
- **Refused: a count of the references of each object.** Each write of a realisation, of a recipe and of an output would change counts of other objects, and a stop between two writes leaves a count that names nothing. The marks are computed again from what the store holds.

### The recipe of a declaration

A declaration names a recipe with `recipe(module(builder), arguments)`; its hash is the hash of this service, `recipe_hash`, over the builder, the output kind, the source date, the input table and the argument bytes. One conversion of the contract, `plans_recipes.recipe_spec_of_arguments`, gives the record from the value: each first-level field that is a tree reference or a module file is an input with its kind, the other fields are the argument record ([application_projects.md](application_projects.md), "One identity for a recipe").

- **`register_evaluation`** takes the output of an evaluation whose value is a recipe, copies it into the memory of the service, converts it, and registers it under the hash that the evaluator wrote. `register` takes a recipe in its parts.
- **Its refusals**, each an error record with the refusal as its value: `Untyped_Hash` (a bare hash), `Nested_Input` (a tree or module file below the first level), `Not_A_Recipe` (another value, or a refused evaluation), `Damaged_Recipe` (bytes that do not decode, a form that is not canonical, a written hash that is not the hash of the record), `Unsupported_Argument` (a recipe, a follow, a store, a plan or a project among the arguments, a `source_date` that is not an integer of 0 or more).

### The local store of the realisations

The step 1 of the substitution policy reads the local store. The local store is the private store of the recipes service, with an index of it in the memory of the service (`recipes_core`): two objects for each realisation, both named by a hash.

- **The output is the object `blob_<output hash>`** (the first 52 hexadecimal digits; the name of an entry of a store has at most 64 bytes), of any size up to `plans_recipes.RECIPE_OUTPUT_BYTES_MOST`, one object of a cache, 16 MiB today: a realisation is shared through a cache. A cache that carries an object of any size in frames of 1 MiB checked against its BLAKE3 root raises the bound to the bound of its protocol; the remote lookup of a build then reads an output frame by frame into the store, not into the staging of 64 KiB. It is the name that the guest builder uses for its inputs and the objects of its outputs: an output of one build is an input of the next with no copy.
- **The realisation is the object `realisation_<recipe hash>`**: its head only, the realisation record, its origin (a local build or a cache) and the count of the bytes of its output.
- **The output comes before its realisation.** A build or a fetch writes the output, then the realisation, then the index takes them. A stop between the two leaves an output that no realisation names, which the next build of the recipe writes again under the same name; a realisation never names an output that the store did not hold whole. A store that refuses a write records nothing: the build is refused with `Store_Failed`.
- **Each hit reads the output and checks its hash.** A blob is read by pieces of 32 KiB into an incremental BLAKE3 hash, so an output costs the service no memory of its size; a tree, whose hash needs its encoding whole, has at most 64 KiB. The index holds no bytes.
- **A realisation that does not decode is refused** with `Store_Damaged`, and nothing builds: a damaged head is a fault to read. **An output that is absent, or whose bytes are not its hash, is a miss**: the build runs again and writes it again. An absent output is the normal end of an output that two recipes shared, when the retention rule removed it with the other one.
- **The index forgets, the store remembers.** The index holds 1024 outputs and 1024 realisations; a full index forgets the one used least recently, and a later build of it reads it back from the store, also when the index still holds the realisation and forgot only its output.
- **The retention rule.** The outputs and their realisations keep at most 75 % of the blocks of the store (`RETENTION_PERCENT`); the rest holds the recipes, the inputs that a writer keeps, and the blocks that a commit writes. Before it writes an output, the service reads the counts of its store. When the output does not fit, it lists the store once and reads the head of each realisation: if even the removal of each realisation that it may remove, with its output, cannot make room, the output is refused with `Store_Full`, and nothing is removed. Else it removes the oldest realisations by the commit of their object, each with its output, until the output fits. An output that a recipe names as an input is never removed, nor its realisation: an input of a registered recipe, of the build that runs, or of a holder that the service names (`retention_keep`, the queue of the guest builds). A hit writes nothing, so the oldest is the one built or fetched first, not the one used least: a hit that wrote would make each read a write of the disk. The rule removes no input that a writer kept: those are the inputs of a recipe, not its cache.
- **The C module is a view of the memory of its build.** A builder gives its output as a view: the inputs tree builder in the staging of 64 KiB of the service, the native C builder in the memory object of its module, of the size that the assembler gives. The service writes it to the store by pieces of 32 KiB in commits of 1 MiB (`storage_port.write_large`).
- **Refused: the bytes of each output in the memory of the service.** 32 slots of 64 KiB held 2 MiB for 32 outputs and refused a module of SQLite; the store already holds objects of any size, and the memory of the service then grows with nothing.
- **Refused: one object for the realisation and its output.** A realisation could not then share its output with another, nor an output be read by its hash as an input; and a stop between the steps of the write of a large object left a head whose bytes no reader could tell from the whole.
- **Refused: a ledger of the uses for a retention by the last use.** One more object written at each hit, which a stop can leave behind the store.

### The fetcher

The fetcher is the one builder with the network. Its argument record holds an address and the hash of the output, given in advance. Its network grant names the host of the address and nothing else. It refuses an output whose tree hash is not the hash given in advance: the service `recipes` discards the store "out" and writes no realisation.

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

**What runs today is not this form.** `modustool cache-serve` speaks binary frames over TCP (`modus:contract/object_cache`, version 2): a request starts with the magic `MOCQ`, an answer with `MOCR`, then a version, a kind, a status and a body length. Its requests are `Has`, `Get_Object` (one frame of an object and its proof), `Get_Realisation`, `Put_Object` (the signed head of an upload), `Put_Object_Frame` (one frame of the upload) and `Put_Realisation`. A put needs a key of `--authorized-key` and its signature. QUIC with the key of the endpoint pinned, `References` and `Release_Pointer` are the planned form, and no machine of `modus` reads an object cache over the network yet. The publisher of the system signs its realisations with a key of its own, the cache signing key; `modustool cache-put` and `cache-get` are the client of the host ([../infrastructure/cache_publication.md](../infrastructure/cache_publication.md)). The page of a public object cache is [../infrastructure/public_object_cache.md](../infrastructure/public_object_cache.md).

#### Objects of any size

The protocol carried an object in one frame, held whole in memory at each side, with a bound of 16 MiB on the object. A release disk, the kernel and the initial archive of a guest, and a large build output passed it. The bound protected the memory. Now the bound is on each frame, and an object has no bound but the disk.

- **One name: the BLAKE3 hash of the whole blob.** BLAKE3 is a tree hash: the hash of a blob is the root of a binary tree over its chunks of 1 KiB, and each subtree has a chaining value (`blake3.subtree_chaining_value`). So a part of a blob is checked against the root with the chaining values of the subtrees beside its path, and with nothing else of the blob. This is the verified streaming of Bao ([the Bao specification](https://github.com/oconnor663/bao/blob/master/docs/spec.md)). The loader, the guest builder and the cache name a blob by the one hash (property 11).
- **A frame.** An object travels in frames of 1 MiB (`FRAME_PAYLOAD_BYTES`), 1024 chunks. Frame k holds the bytes from k × 1 MiB. Each frame holds 1 MiB but the last one, which holds the rest; the empty blob is one frame of 0 bytes. Because 1 MiB is a power of two of chunks, each frame is a node of the tree of BLAKE3. The tree above the frames has the shape of the tree of BLAKE3: the left child of a node of m frames holds the largest power of two of frames less than m (`object_frames.odin`).
- **The proof of a frame** is the chaining value of each sibling on the path from the root down to the frame: 32 bytes for each level, at most 32 levels (`MAX_PROOF_DEPTH`). The reader computes the chaining value of the frame, joins it with each sibling up to the root, and compares the root with the hash (`object_frame_verify`). A blob of one frame has no proof and is checked with `blake3.hash`. A tree is at most 50 192 bytes, so it is always one frame, checked with `tree_hash`.
- **The size.** The shape of the tree comes from the size that the sender states. Two sizes can give one path to a frame in the middle, so such a frame proves its bytes and not the size. The last frame proves the size: its length, the end flags of its last chunk and its path on the right edge are in the root. So a reader keeps an object only when every frame, the last one too, verified under one stated size. An answer that states another size than the first answer is refused (`Damaged_Answer`).
- **Get: one frame for each request.** `Get_Object(hash, kind, offset)` names one frame by its first byte, a multiple of 1 MiB. The length is the length of that frame, so no length travels. The answer holds the size of the object, the offset, the proof and the bytes. The decoder refuses an offset that is not a multiple of 1 MiB, bytes of another length than the frame at that offset, and a proof whose count of levels is not the depth of that frame. A frame past the end is `Out_Of_Range`. The client checks each frame before it writes it.
- **The outboard.** Beside each blob of more than one frame, the server keeps its outboard, `outboards/<hash>`: the chaining values of the two children of each parent of the tree of frames, 64 bytes each, in pre-order. This is the outboard of Bao with frames of 1 MiB in place of chunks of 1 KiB: (n − 1) × 64 bytes for n frames, 6 336 bytes for 100 MiB. The proof of a frame is one entry for each level, read at its place: no work in proportion to the blob. The server builds the outboard during the put. An object with no outboard (a store of version 1, a file copied in by hand) gets its outboard at its gets: each get of the object builds at most 16 more frames of it (`OUTBOARD_BUILD_FRAMES_PER_EXCHANGE`) and answers `Busy` with the frames built and the count of frames, until the build reaches the last frame; the outboard is renamed into the store only when the root matches. The client asks again after each `Busy`, and refuses a `Busy` that shows no more frames built of the same count, so a server that never ends its build holds the client for at most one answer for each frame. The server builds at most 4 outboards at once; a fifth build ends the build that waited longest.
- **The server checks what it serves.** Each frame is checked against the root before it leaves, as the client checks it. A frame that does not verify is checked once more with an outboard built again from the object, by the same bounded steps: a damaged outboard is repaired. An object whose bytes do not hash to its name moves at the first mismatch from `objects/` to `damaged/`, and its outboard is removed: `Has` stops answering present, the next get answers `Not_Found` with no read, the next put writes it again, and the page counts it.
- **The work of one exchange is bounded.** No exchange hashes more than 18 frames, 18 MiB, whatever the size of the object: at most 16 frames of a build of an outboard, the frame that it answers, and the frame that it checked before a build again. A put checks one frame for each exchange, and the check that an object is present reads one frame (see Put). So the deadline of one exchange at the client holds for an object of any size.
- **Put: a signed head, then the frames in order.** `Put_Object(hash, kind, size, key, signature)` opens an upload; the signature covers the kind, the hash, the size and the key. The server answers `Already_Present` when it holds an object of that size and its last frame verifies with the proof of its outboard (or, for an object of one frame, the frame hashes to the name), else `Accept_Frames` from offset 0. The last frame proves the size; a damaged frame in the middle is found by the get of that frame, which moves the object to `damaged/`, and the next put writes it again. A blob with no outboard is not present: the put writes it again with its outboard. The client refuses an `Accept_Frames` from another offset than 0 (`Damaged_Answer`), since a put does not resume. `Put_Object_Frame(hash, offset, bytes)` gives one frame, and the server answers each frame. The server refuses a frame with no open upload, a frame out of order, and a frame of another length than its offset demands; each refusal ends the upload. It writes the frames to a temporary file, adds each frame to the tree of frames (`Frame_Tree_Builder`, at most 33 chaining values), and writes each parent that the tree completes to its place in a temporary outboard. At the last frame it compares the root with the hash. Only on a match does it rename the outboard, then the object, into the store: the rename of the object is the moment when the object exists. A root that differs is `Bad_Hash`. A put that ends before its last frame (a closed connection, a refused frame, a new put) removes both temporary files: the store never holds a part of an object. A temporary file of an earlier run of the server is removed at its open, since the server is the one writer of its folder. Each file reaches the disk (`fsync`) before its rename, and its folder after the rename, so a crash never leaves a name with bytes that did not reach the disk. An outboard whose object was not renamed is removed.
- **A head played again opens nothing that matters.** The signed head carries no nonce: anyone who saw it can send it again and open an upload of the same hash and size. The server then keeps the bytes only when their root is that hash, so the bytes kept are the object that the signer authorised, and nothing else. The cost to the server is the disk of one upload in progress for each connection, as for an upload of the signer.
- **Why a put is checked at its end, and a get at each frame.** A get reads from a server that nobody trusts, so the client checks each frame before it writes it. A proof for each frame of a put needs the outboard of the file before the first frame: a whole pass over the file, and (n − 1) × 64 bytes that the client keeps or writes. The uploader is a key that the server authorises, and its bytes reach no reader before the root matches. So the server hashes the frames as they arrive and keeps nothing that does not match.
- **The memory.** For any size of object, each side holds a few buffers of one frame. The server holds one request buffer and one answer buffer for each connection, about 2 MiB, and the tree of frames. The client holds one frame to send or to receive, and the tree of frames. The host test of 100 MiB measures the peak of each side and refuses more than 8 MiB.
- **The largest object.** The protocol bounds an object at 1 MiB × 2^32 = 4 PiB (`MAX_OBJECT_BYTES`), so that a proof has at most 32 levels. The bound that holds in practice is the disk. Before the first frame, the server refuses with `Too_Large` a put whose object and outboard do not fit on the free space of its store. The client refuses a get whose object does not fit on the free space of the folder of its output. A get into memory (the output tree of a recipe) has a bound of its caller, 64 MiB by default.
- **Resume.** A get resumes. `cache-get <host:port> blob <hash> <file>` writes the frames to `<file>.<hash>.part`, each frame after its check. A new run with the same output keeps the whole frames of the part file and asks for the frames after them; a part file at or past the end of the object starts again at offset 0. It hashes the whole file once more before the rename, because a file on the disk is not a check, compares its size with the size of the object on every path, and renames it to `<file>` only when both match. A part file that the system does not cut to whole frames refuses the get. A cut transfer keeps the part file for the next run; a false answer of the server (`Damaged_Answer`, `Hash_Mismatch`) removes it. A put does not resume: an upload that ends halfway starts again at offset 0, because the server keeps no part of an object that the root did not check.
- **One request in flight.** The client waits for the answer to each frame before it sends the next request. A round trip of 50 ms then bounds one connection to 20 MiB/s. A window of several frames in flight is planned work (`ROADMAP.md`).
- **`Has` and the page.** `Has` answers present only for an object whose root matched: an upload in progress is not in the store. The page and `status.json` count an object when its rename ends, and show the size of the largest object.

Refused forms of objects of any size:

- **A higher bound on one object.** It moves the limit and keeps the whole object in memory at each side: a disk of 8 GiB needs 8 GiB of memory.
- **A large blob as a tree of chunk objects with a hash of its own.** A file cut in chunks of a fixed size, or cut by its content (content-defined chunking, which shares the chunks of two versions of one disk), has a hash that is not the BLAKE3 hash of its bytes. The blob then has two names: the loader names a module and a disk by the hash of its bytes (property 11), and the cache names it by its tree. A tree of objects stays the form of an output whose parts a recipe names (the kind Tree). Two versions of one disk share their blocks in the storage engine, which keeps the chaining value of each block (`docs/STORAGE.md`, "The hash of an object"). A transfer that sends only the changed frames of a new version changes no name, and stays possible.
- **A tree of chunks only for the blobs past a size.** A blob then changes its name when it grows past the size.
- **The size that the sender states, trusted.** A size that is not the true size gives a path that a frame in the middle satisfies. Only the last frame proves the size, so the reader checks every frame under one size.
- **A whole-object stream with the outboard sent first.** The reader then holds (n − 1) × 64 bytes before the first byte of the object, and the server keeps the state of each stream. A request for each frame keeps no state at the server, resumes at any frame, and lets several mirrors serve one object.
- **A frame of 1 KiB, as Bao checks each chunk.** Each KiB then costs a request and a proof. A frame of 16 MiB is the old bound in memory. A frame of 1 MiB keeps each side near 2 MiB, and the proofs and the outboard under 0.01 % of the object.

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
- **A lost builder.** A build call that ends in doubt (`Connection_Ended_During_The_Call`, `Deadline_Passed_During_The_Call`, `Answer_Unreadable`) can have run, and a call that never left (`Callee_Unavailable`) leaves the builder out too. A build is a function of its recipe, so the recipe goes to the next builder, and then to this machine; the lost builder takes no more work in this run. A builder that refuses the call (`Grant_Or_Right_Missing` for a use that the pairing does not grant, `Callee_Unavailable` for a role that it does not hold) leaves the run the same way. A recipe that no machine built is `No_Builder`, and each recipe that needs its output is `Dependency_Failed`.
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
- **The root service as the starter of a builder.** A command of the root ring would carry four handles of stores and a page of the request, and the root service would start a process that waits up to 5 s for its load without blocking its loop: more authority and one more border in the root service. The kernel gives a call host of `recipes` the same sandbox.
- **A date page with the source date and the clock.** The date of a date page is the date at the time 0 of the system and the clock, so it moves during a build, and a builder that writes the date writes another output at each build. A builder has no date page; the date of its recipe is in its arguments.
- **The whole place `objects` as the input store.** A builder could list it and read outputs that are no input of its recipe: an input that the recipe does not name.
- **An output hash that the builder gives.** The service would trust a claim; it computes the hash over the store that the builder left.
- **An argument record that the module of the builder describes, checked by the console.** The evaluator writes the canonical form of the output, and the recipe hash covers those bytes: a second encoding would be a second identity of one recipe.
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
- **Whether the garbage collector keeps the inputs of a realisation** when a plan keeps its output.
- **The bound of the blocks of the store "out"**: stated in the recipe, or from the budget of the builder module.

## State

Built: the binary wire protocol, signed realisations, substitution policy, host cache server, the `plans`/`recipes`/`projects` contracts and delegated service modules, and the sandboxed guest builder layer. `src/library/modus/contract/object_cache` defines the closed wire enums (`Cache_Request_Kind`, `Cache_Response_Status`, `Cache_Object_Kind`, `Substitution_Decision`, `Substitution_Mode`, `Wire_Refusal`), strict binary framing (`encode_request`, `decode_request`, `encode_response`, `decode_response`), the `Realisation_Record` with domain-separated canonical signing bytes (`"modus realisation v1"`), and the pure `substitution_check` that trusts content-addressed blobs and trees by recomputing BLAKE3 or `tree_hash` with no signer and requires an explicit trusted Ed25519 signer for realisations. `src/library/modus/contract/plans_recipes` adds `Recipe_Spec`, input-order-independent domain-separated BLAKE3 `recipe_hash` (`"modus recipe v1"`), `Build_Mode` (`Cache_First`, `Build_Only`, `Cache_Only`, `Verify`), `Builder_Sandbox_Spec` (read-only inputs, empty output store, frozen `source_date`, zero network, seed equal to `recipe_hash`), and strict cache realisation verification against `object_cache.Substitution_Policy`. `src/library/internal/recipes/recipes_core` implements the local-store -> remote-cache -> sandboxed-builder -> `tree_hash` -> provenance pipeline, wired into the freestanding `src/modules/system/recipes` service. `src/library/modus/contract/guest_builder` defines the fixed-layout `Guest_Build_Spec`, closed border enums (`Guest_Build_State`, `Guest_Disk_Role`, `Guest_Builder_Refusal`), the canonical `MODGBD1` disk image format (`pack_input_disk`, `unpack_output_disk`) with exact recursive `tree_hash` extraction, and the pure `Guest_Sandbox_Runner` enforcing read-only input disks, zero network, frozen epoch time, and exit-code-0 output extraction; `src/modules/system/guest_builder` wires that contract to `Guest_Run` in a freestanding module. `tools/modustool/cache_server` provides the content-addressed on-disk store (`objects/` and `realisations/` with atomic writes via temporary file and rename), authenticated upload verification, request handler (`cache_server_handle_frame`), framed stream listener (`cache_server_serve`), and the `modustool cache-serve` command, with host tests for each package.

Built with the exports of the services: `src/library/modus/contract/plans_recipes/service_records.odin` holds the rows that the exports take and give (`Recipe_Head`, `Recipe_Input_Row`, `Recipe_Reference`, `Recipe_Build_Row`, `Realisation_Row`) with the border `recipe_spec_of_parts`, and the inputs tree builder (`inputs_tree_builder_hash`, `inputs_tree_build`). `src/library/internal/recipes/recipes_core/registry.odin` keeps the registered recipes by hash (16 at most) and the newest 32 builds. The service `recipes` exports `register`, `register_evaluation`, `build`, `cache_lookup`, `builds` and `realisations`: a build in a mode that takes the cache gives a realisation of the local store with no build, and a miss of an inputs tree recipe builds, keeps its output and its realisation, so the next build of it is a hit. The guest builder exports `status` and `disks_check`, which checks a spec, its read-only input disk and the bound of its blank output disk with no guest. Each has host tests of its refusals.

Built with a builder in its sandbox: the service `recipes` starts the module of each builder but the inputs tree builder as a call host, with the context of `modus:contract/builder` (`context_check` refuses a slot more or less, a seed that is not the recipe hash, a strength that is not `None`, and a value more), its inputs cloned into `build/in` by a walk of their objects (`recipes_core.input_closure_take`, which refuses an absent object, a damaged tree, more than 4096 objects (`builder.MAX_INPUT_OBJECTS`) and a tree deeper than 32, and finds a seen hash in a set of the walk, not by a scan), two shares of the storage service, and a bound of 60 s on the call (`call_isolated` with a deadline, the call status `Deadline_Passed`). The store "out" is frozen into `objects` after the call host and the shares ended. The machine test `main` runs it with the test builder `builder_probe` and the module `build_check`: an output becomes a realisation, a second build takes it with no start, that output is the input of the next build, and a write in the input store (`No_Grant`), a name above the store "out", a look for a handle past the context, an error record, a stop, a builder that no module is, an input that no build gave and a builder that never answers are each refused, with nothing kept.

Built with the private store: each realisation is an object of the private store of `recipes` ("The local store of the realisations"), read back and checked after a start, so a build of a recipe that the service realised before builds nothing; `projects.build_recipe` gives the recipe of the inputs tree of a project. Host tests check the hit after a start, the determinism of the recipe hash, each damage of a stored object, a store that refuses the write, and the refusals of a corrupt recipe.

The guest builder boots a Linux kernel of 64 bits (a bzImage or a vmlinux whose BLAKE3 hash is `kernel_hash`) in its guest by the boot protocol of Linux, with the machine of [foreign_systems.md](foreign_systems.md), "The machine of a Linux guest": a serial port and a virtio console, the inputs as a read-only virtio disk, and the output as a blank writable virtio disk. The command of the spec goes to init after `--` on the command line; the guest ends a build with its exit status on the port `Build_Exit_Status`. The report gives the BLAKE3 hash of the whole output disk beside the tree hash of its MODTREE2 extraction. Checked by host tests only. One of them runs a whole build through the loop of the builder: a program of 64 bits that boots by the boot protocol, on the software processor of `modus:contract/software_machine`, reads its input disk, writes its output disk and exits with 0, and the builder gives the tree hash of the disk that the host packed; a write of the program to its input disk refuses the build ([foreign_systems.md](foreign_systems.md), "State"). The spec can name an initial archive by its BLAKE3 hash and its size; the builder checks the hash on its copy in the memory of the guest before the boot, so a kernel of Nixpkgs runs the `init` of the recipe ([foreign_systems.md](foreign_systems.md), "The chosen form").

Built with the guest builder in the service `recipes` ("The guest builder in the service"): a recipe of the guest builder prepares its guest, packs its inputs, runs its guest on the build thread under the time bound, unpacks its output and keeps its realisation; the service exports `put` and `build_stored`, and a pass of "The retention of the store" runs at its start and after each guest build. Host tests run the steps with a scripted guest in place of `Guest_Run`: the success, the next build from the cache, the expansion of a tree input, each refusal of the list, a guest of interrupts only, the edges of the inputs (the depth of a tree, a cycle of hashes, the most files and one more, a full arena of paths, the longest path and one byte more, two inputs of one name, a full staging), a keep that fails, the retention, the refusals and the quota of `put`, and the ranges of the store. Built: the machine test part `guest_build` ([guest_build_image.md](guest_build_image.md)), which builds a recipe with the guest image of a build and checks the tree hash of its output.

Built in `recipes_core`: the distributed builder of "Builds across paired machines", with a host test of four machines in memory (a laptop, two builders, a cache) that realises a graph of six recipes, takes one from the cache with no build, gives two leaves of one round to two builders, refuses a changed bit, an untrusted signer and a bad signature, passes over a cache that withholds its output or gives a bad realisation to the next cache, a builder or this machine, moves a recipe to the second builder when the link of the first breaks during its build, falls back to this machine, and refuses a builder that is not deterministic with `Determinism_Mismatch`.

Built in `modus:contract/object_cache` and `tools/modustool/cache_server`: objects of any size ("Objects of any size"). `object_frames.odin` holds the frames, the proof of a frame and the tree of frames; host tests compare the root of the tree of frames with `blake3.hash`, which the official vectors check, for each size of the vectors, with frames of 1 KiB and of 1 MiB, and refuse a changed byte, a changed level of a proof, a proof cut short and a false size. `cache-serve` keeps the outboards, checks each put at its last frame and each get at each frame; `cache-put` and `cache-get` stream a file of any size, and `cache-get` resumes. Host tests on loopback give a frame past the bound, an offset that is not a multiple of 1 MiB, a frame out of order or of a false length, a server that cuts a proof, states a false size or changes the size between two frames, a server whose `Busy` shows no progress, a head whose size passes the free space, a frame with no open upload, for another hash or after the last, a put stopped halfway, a temporary file of an earlier run, a damaged object (moved to `damaged/`) and a damaged or missing outboard (built again by bounded steps), a part file changed on the disk, at the end of the object or past it, then put and get blobs of 0 bytes, 1 byte, 1 MiB, 1 MiB and 1 byte, and 100 MiB with the peak memory of each side measured.

Left: the connection of the service `recipes` to the outbound links of `remote`, which the root service gives, so that `recipes.build` runs a distributed build on a machine; the grant Store of the service `recipes` at its start ([declarations.md](declarations.md), "State": until then a realisation is refused with `Store_Failed`), the fetcher, the import of a tree from outside (a source of a project) into the place `objects`, the C builder, a builder that is a module file of a disk, the bound of blocks of the store "out" (the share has the limit of the store of `recipes`), builds of other callers while one build runs (the service serves one call at a time), the signature of a local realisation with the key of the principal (the key is in the service `principals`, to which `recipes` has no connection), the QUIC cache client inside modus, console wiring for `recipes.build`/`recipes.provenance`, and the `--authorized-key` of the cache signing key of the publisher at `cache.modus.systems` ([../infrastructure/cache_publication.md](../infrastructure/cache_publication.md), "State").
