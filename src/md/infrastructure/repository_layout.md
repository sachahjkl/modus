# The layout of the repository

Everything that becomes the system is in one folder, `src`. A module of a third party imports the packages of the system through one source library, `modus`. This file is the design of that layout: the folders, the parts of the library, the rules of the imports that the tool holds, the split of the tool, and the steps that reach the target layout from the layout of today.

What changed: the private half of a single module and the kernel logic leave the shared library, the modules with an entry and the other modules become one folder of modules by group, and the tool becomes packages behind one command. The source library `modus` and its one flag stay as they are.

The terms are in [`docs/glossary/communication.md`](../../../docs/glossary/communication.md): "Source library", "Private part", "Kernel part", "Module group", "Test module". The flag of the compiler for a source library is `-collection`.

## Purpose

- A reader tells what becomes the system from what builds it, tells it and checks it: the system is `src`, the rest is at the root.
- A reader tells from a folder what its code serves: two parties, several modules, one module, or the kernel alone.
- Each part of the system that holds logic has host tests. Before this design a test existed only in a package of the library, so the logic of a module moved into the shared library to get its tests, and the library held the private half of single modules.

## The constraints

- A module of a third party writes no relative import, and names the library of the system by one name.
- A module inside the repository imports with the same lines as a module outside it. An example module that is copied out still builds.
- One spelling for one package: an import line of a package is the same in each file that imports it, the tool too.
- No relative import in `src`.
- The kernel imports the contract packages and its own parts only. A contract package imports no support package. This rule is held by a check that stops a build, not by a convention.
- Each step to the target layout is one commit that builds and passes the checks. A move is made by a command: `git mv`, then one precise rewrite of the import lines and of the paths.

## The target tree

```
src/
  md/                          the intent of each part (this folder)
  kernel/                      the kernel: the package that is the kernel module
    <part>/                    a kernel part: a pure package with host tests
  boot/                        the boot program
  runtime/                     the memory procedures in assembly
  library/                     the source library `modus`
    contract/                  what two bodies of code agree on, and nothing else
    support/                   what two modules or more compile in
    private/<module>/<part>/   a private part: what one module alone compiles in
  modules/                     each module of the system, by its module group
    system/                    the root service, the services, the desktop, the tools of a principal
    libraries/                 the modules that export functions and have no entry
    demonstrations/            the modules that show a property to a principal
    tests/                     the test modules
tools/modustool/               the tool: one command, in packages
  foundation/ resources/ build/ checks/ fuzz/ similarity/ machine/ site/
docs/                          the guides, the glossary, the research, the pictures, the films, the measures
news/  changelog.d/  CHANGELOG.md  ROADMAP.md
resources/                     the sources of the resources of the boot image, with their licenses
secrets/                       the keys of the publisher, encrypted with sops
.github/                       the workflows of the releases and of the site
.project/                      the card of the project
flake.nix  flake.lock  .sops.yaml  AGENTS.md  README.md  LICENSE
build/                         the output, which git ignores
```

### What stays at the root, and why

- **`tools/`.** The tool is not a part of the system: it is a program of the host that builds the system. It must build before anything of `src` does. The command of each project is the program of `tools/<tool>`; here `nix develop -c modustool <command>` runs it.
- **`docs/`.** The guides are the documentation, and the site publishes them at addresses made from their names.
- **`news/`, `changelog.d/`, `CHANGELOG.md`, `ROADMAP.md`.** They report the project to a reader.
- **`resources/`.** A resource is not written here: the tool converts it from a source of another party (a font, a pointer theme) or from the mark, and each has its license.
- **`secrets/`, `.sops.yaml`, `.github/`, `.project/`.** The keys of a release, the workflows that the host of the repository runs, and the card that the host shows. A tool of the host reads each at its fixed place.
- **`flake.nix`, `AGENTS.md`, `README.md`, `LICENSE`.** The entry points of a repository are at its root.

`src/md` is under `src` because the intent is kept near the code that it explains.

## The source library `modus`

The library is one source library, `modus`, in the folder `src/library`, with the one flag `-collection:modus=src/library`. An import line says the part of the library: `modus:contract/ring`, `modus:support/system`, `modus:private/console/line_editor`.

| Form | Import lines | Flags | The rule of the kernel |
|---|---|---|---|
| A. One source library whose folder is `src` | `"modus:contract/ring"`, `"modus:support/system"` | One: `-collection:modus=src` | Held by the tool. `"modus:kernel"` and `"modus:modules/clock"` are imports too |
| **B. One source library `modus`, in `src/library`** | `"modus:contract/ring"`, `"modus:support/system"` | One: `-collection:modus=src/library` | Held by the tool |
| C. Two source libraries, `contract` and `support` | `"contract:ring"`, `"support:system"` | Two | Held by the compiler |
| D. `modus` for modules, and `contract` kept for the kernel and for the contract packages | `"contract:ring"` in the kernel and inside `contract`; `"modus:contract/ring"` in each other file | Two for a module | Held by the compiler |

Form B is built:

- One name, `modus`, and one folder that holds the library and nothing else. A source library is a named folder of source packages; `src/library` is exactly that.
- The name of the library and the name of its folder are two things. The name is `modus`: it is what a source writes before the `:` of an import. The folder is `library`: it says what the folder is among the parts of `src`.
- One flag, and one entry in the settings of a language server.
- One spelling for one package, in the kernel, in a module of the system and in a module of a third party.

Why not the others:

- **A** makes the kernel, the boot program and each module importable packages of the library. A third party points at a folder that holds the whole system.
- **C** keeps two common words as the names, and gives a third party nothing that says `modus`.
- **D** gives one package two import lines, and a writer must know which one a file takes. A contract package that is copied into a module, or a module file that moves into the kernel, changes its imports.
- **The folder named `modus`** (a folder `modus` in `src`). The system modus is the whole of `src`: a folder of that name beside `src/kernel` reads as if the kernel were not a part of modus.

### The three parts of the library

- **`contract`**: the records, the constants and the pure procedures that two bodies of code compile in so that they agree: the kernel and a module, two modules, a module and the tool, the boot program and the kernel. A contract package holds no kernel operation call, and imports no support package.
- **`support`**: the code that two modules or more compile in to use the contracts: `system` (the kernel entry, the rings, the loader), `interface`, `graphics`, `display`, `tcp`, `quic`, `storage`, `sentence`.
- **`private`**: the private parts. `src/library/private/<module>/<part>` is a package that the module `<module>` alone compiles in, with its host tests. The folder of a module is named by the name of the module, not by its path, so the move of a module to another module group changes no import line of a private part.

A format that only the kernel reads is not a contract, even when the hardware or the firmware writes it: a contract exists so that two bodies of code compile the same definition, and the hardware compiles nothing. Such a package is a kernel part.

### Where the private part of a module lives: the chosen form

**The chosen form: a third part of the library, `src/library/private/<module>/<part>`, imported as `modus:private/<module>/<part>`.** The tool holds the border.

- It needs nothing from the compiler: no new flag, no new setting of a language server. The compiler accepts the import in each file; the check of the imports refuses it outside its module.
- The tool imports a private part with the same line as its module. The tool is a second reader of six of the seventeen private parts: it writes the disk images of the storage service (`storage_mount`, `storage_object`, `storage_tree`), places a click on the bar of the compositor (`bar`), signs the rows of a replacement (`replacement_signature`), and runs the cryptography of its QUIC peers (`cryptography_primitives`). The fuzzer names a package by the same path.

### The code of a library module that a host program calls

A host program cannot load a module, so the code of an export that a host program calls is a private part of its module: `cryptography_primitives` holds the code of the exports of the module `cryptography`, each under the same name and with the same signature, and the module exports each one with a call. The peers of the tool and the host tests of `quic`, which fill `quic.Cryptography` with these procedures, import the part. The module keeps its names, its signatures and its error records, so its description and the hash of its exports stay. `argon2id` stays in the module, because no host program calls it and its cost record is a record of the description.

- **A host test may import a private part of a module of the group `libraries`.** A host test is no owner, and such a test stands in for the module whose exports its package calls through its import slots. A private part of a module of another group stays refused in a host test of another module or package.
- **A relative import never lands in a module folder** from a file outside that folder, in `src` or in `tools`. The compiler accepts it in a host test and in the tool, and it makes the code of one module a library of another reader, beside its import slots.

Refused forms:

- **The code in a support package of its own.** One module alone compiles it in; the tool and the host tests are no owners, so the package has one owner, and the owner rule refuses it.
- **The relative import of the module folder, as before.** It names a module by its path, which a move of the module group changes, and it hides from the check of the imports a reader of the module.
- The word `private` tells a third party that the package is not for it, in the import line itself.

Refused forms:

- **A part under the folder of its module, through a second source library for all the modules** (`-collection:modules=src/modules/...`, `modules:console/line_editor`). The compiler then accepts `modules:console` too, the main package of another module, so the check must refuse more, not less. Each module build, each host test and the tool need the second flag. A module folder then holds packages in its subfolders, and each reader of the tool that takes the files of a module folder whole (the build key, the size counts, the choice check, the export check) must learn to skip them. Its one gain is that the part sits beside its module; the folder `src/library/private/<module>` gives the same pairing.
- **A part under the folder of its module, through a source library that each module build sets to its own folder** (`-collection:part=<the folder of the module>`, `part:line_editor`). The compiler then refuses a part of another module, because no line names it. But the same line names another package in each module, a language server takes one folder for one name, and the tool, which reads five private parts, can name none of them with the line of its module. It breaks "one spelling for one package".
- **The private parts kept in `support`, with a list of the support packages that one module imports.** A reader of `support` then cannot tell shared code from private code without the list, and the list grows in silence.
- **The private part inside the package of the module.** A module package has no host test: a test of it builds the whole module for the host.

### The kernel parts and the second source library

**The chosen form: a second source library, `kernel`, in the folder `src/kernel`, with the flag `-collection:kernel=src/kernel`.** A kernel part is `src/kernel/<part>`, imported as `kernel:<part>`.

The tool gives the flag to exactly these compiles:

- the compile of the kernel module, in each row of the table of the modules that is a kernel;
- the host test of each folder under `src/kernel`;
- the compile of the tool, which imports two kernel parts: the fuzz targets of the firmware tables read `acpi_processors` and `iommu`, and the depth of the kernel stack reads `iommu`.

No module of `src/modules`, no host test of the library and no boot program gets it. So the compiler refuses `kernel:iommu` in each of them, with an unknown source library. The check of the imports refuses it too, in each source and test of `src` outside `src/kernel`, because a language server has one set of source libraries for all the folders, and it then compiles the import. It also refuses a relative path of a file outside `src/kernel` that lands in `src/kernel` or under it: the compiler accepts a relative import in a host test, which reaches a kernel part with no flag. The check resolves the path from the folder of the file, as the compiler does.

The rules of a kernel part:

- It imports `base:`, a contract package, and another kernel part. It never imports `kernel:` with no package, or `kernel:.`: each names the package of the kernel itself, which imports the part.
- It is pure: its procedures read values and give values, and it keeps no state and reaches no machine. The state of the kernel stays in the package of the kernel, so that a host test runs each procedure with no machine. The check of the imports reads each source of a kernel part that is not a test and refuses:
  - a package variable with no `@(rodata)`. The compiler refuses a write to a variable that is `@(rodata)`, and the memory of the machine refuses a write through a pointer to it, so the attribute is the whole check. The tables of a kernel part are such variables: the texts of the problems of a table of the firmware (`DMAR_PROBLEM_TEXTS`) and the encodings of the events of each vendor (`INTEL_EVENTS`);
  - a variable marked `@(static)` or `@(thread_local)`, which keeps state from one call to the next with no package variable;
  - a foreign import and a foreign block, which link to a symbol of the kernel or of assembly, and an asm template: on the host, each fails to link or runs on the processor of the host;
  - an intrinsic that reads or changes the machine (`read_cycle_counter`, `x86_cpuid`, `volatile_load` and the others that the guide lists), under any local name of `base:intrinsics`. An intrinsic that computes a value from its arguments stays open.
- It is freestanding as the kernel is: `"contextless"`, no allocator, no `fmt`. Its host tests start with the build line of the host.

Why a second source library for the kernel and not a part `modus:kernel/<part>` of the library: the kernel is one body of code with its own compile, its own target and its own flags, so one more flag costs one line; and the refusal by the compiler comes back for each module build, where it was lost when the two libraries became one. For the modules this costs one flag in each build and gives no refusal (the refused forms above), so the tool holds that border.

Refused forms for the kernel:

- **`src/library/kernel/<part>`, as `modus:kernel/<part>`.** It keeps one flag, but puts code that only the kernel compiles in the library that a third party reads, and the border is held by the tool alone.
- **The kernel logic kept in `contract`.** A contract package that the kernel alone imports says that two parties agree where only one reads it.
- **Each part as a file of the package of the kernel.** The package of the kernel has no host test: a test of it builds the kernel for the host.

The packages that become kernel parts are those that the kernel alone reaches: `acpi_processors`, `debug_exception`, `processor_counters`, and `iommu`. Two contract packages that the analysis named stay contracts:

- **`cut_mark`** is reached by the kernel and by three support packages (`information`, `sentence`, `terminal`): it is the one form of the mark of a cut text, which the log lines of the kernel and the records of the processes share.
- **The rule of a bridge in `iommu`.** The root service reads `bridge_passes_requesters` and `CONFIGURATION_WORDS` to give the devices behind a conventional bridge to one service, as the kernel gives them one domain. That rule leaves `iommu` for a contract package of its own, `bridge_requester`, before `iommu` moves. The formats of Intel VT-d and of AMD-Vi stay with the kernel.

## The module groups

Property 10 says that a library and the module of a process are one thing: a module ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module"). The old folders src/programs and src/modules ("the modules that are not programs") said the opposite. They become one folder, `src/modules`, grouped by what each module is for:

- **`system`**: the root service, the device services, the shared services, the desktop, and the tools that a principal uses (`manual`, `monitor`, `log`, `inspect`, `debugger_window`, `pages`, `boot`).
- **`libraries`**: the modules that export functions and have no entry function, which other modules import (`drawing`, `cryptography`, `math`, `calendar`, `text_shaping`, `interface_module`).
- **`demonstrations`**: the modules that each show a property to a principal, and the children that a demonstration starts (`node`, `twin`, `locker`).
- **`tests`**: the test modules. A test module is started or imported by a machine test only, and is wrong on purpose or shows nothing of its own: `test_callee`, `hostile_exports`, `lonely`, `calendar_fixed`, `debug_target`, `iommu_device`, `store_library`.

The group of each module is decided; step 4 builds it:

| Group | Count | Modules |
|---|---|---|
| `system` | 26 | `block`, `boot`, `compositor`, `console`, `date`, `debugger`, `debugger_window`, `entropy`, `frame`, `glyphs`, `host`, `input`, `inspect`, `log`, `manual`, `module_files`, `monitor`, `network`, `pages`, `remote`, `root`, `settings`, `storage`, `terminal`, `tpm`, `unlock` |
| `libraries` | 6 | `calendar`, `cryptography`, `drawing`, `interface_module`, `math`, `text_shaping` |
| `demonstrations` | 50 | `address_space`, `agenda`, `budget`, `clock`, `counters`, `crowd`, `cryptography_vectors`, `debugged`, `disk`, `errors`, `extended_state`, `fault`, `fault_ring`, `fetch`, `flow`, `frames`, `guest_demo`, `hall_of_fame`, `heron`, `imports`, `interface_elements`, `interface_font`, `interface_through_module`, `kernel_events`, `life`, `limits`, `locker`, `locks`, `net`, `node`, `notes`, `origin`, `paint`, `plasma`, `pointers`, `processors`, `quic_echo`, `randomness`, `return_fault`, `rights`, `rings`, `sample`, `scheduler`, `server`, `tables`, `tally`, `threads`, `twin`, `vector_glyphs`, `workers` |
| `tests` | 20 | `arena`, `calendar_changed`, `calendar_fixed`, `debug_target`, `flood`, `hierarchy`, `hostile_exports`, `hostile_terminal`, `iommu`, `iommu_device`, `lonely`, `log_reader`, `probe`, `ranges`, `shortage`, `store_importer`, `store_library`, `test_callee`, `test_caller`, `visitor` |

The cases that the rule left open: `inspect` and `host` are in `system`, a tool of a principal and the call host that the console starts; `probe` and `flood` are in `tests`, because a machine test alone starts them and a principal has no use of a module that only refuses or floods; `notes` and `heron` are in `demonstrations`, each a module that a principal starts to see a property.

A module group is not a second format. The module file holds no group; the loader and the root service never read it. A module of `libraries` and a module with an entry are the same format, and one module can run as a process, serve as a service and be imported as a library (`tally`). The group says where a source lives, and whether a release ships it.

### How the table of the modules reads the group

The folder is the one fact. Each row of the table of the modules names its source folder from the constant of its group: `SYSTEM_MODULE_SOURCES + "root"`. The tool reads the group of a row from the start of its folder, through one procedure that gives the enum `Module_Group`. A host test of the tool refuses a row whose folder starts with no group, a folder of `src/modules/<group>` that no row names, and two rows with the same name. The two rows of the kernel are outside `src/modules`: the procedure gives them no group, and each reader of the group skips a kernel by its flag `kernel`.

**The entry is a field of the row.** The old folder src/programs also said which module starts as a process: the roles of the root service name each such module of the boot image, the site shows it as a module with an entry, and its search gives it the kind entry module. After the merge, no folder says it, so a row has the field `entry`: a module with an entry function that the root service starts. A host test of the tool checks that the source of each such module declares `entry`. The field keeps the set of the modules of before: 85 modules, the subfolders of the old folder src/programs. The entry alone was refused as the rule: `agenda` has an entry, and the process `imports` loads it as a module, so the check of the roles then asks a row for a module that the root service never starts. The field is not the group: a module with an entry is in `system`, `demonstrations` or `tests`, and a group holds modules with an entry and modules with no entry.

Refused forms:

- **A field `group` beside the folder in each row.** Two facts that say one thing, which can disagree.
- **The group from the name of the module** (a prefix `test_`). A name is the identity that a principal types; it must not carry a rule of the build.
- **A list of the test modules in the code of the release.** A new test module that is not in the list ships.
- **The flag `library` of a row as the group.** The flag is a property of the file: the conversion refuses a segment that is read-only after the load. `cryptography` is in `libraries` and has no flag; the group is a property of the place.

### What a release ships

Today the release volume holds the main boot image of the tests, so a release ships each row with `image = true`, the test modules too: `hostile_exports`, `lonely`, `debug_target`, `iommu_device`, `hostile_terminal`, `calendar_fixed`, `calendar_changed`. Only `test_callee` and `test_caller`, whose rows have `image = false`, and the modules that start from a disk are left out.

A release must leave out the group `tests`: a principal has no use for a module that is wrong on purpose. The release image ([release_image.md](release_image.md)) also states that a release ships the bytes that the tests ran. So the boot image of a release is a boot image with no test module, and a machine test boots that exact image: the machine of Secure Boot, which boots the release volume with the test keys. That machine then must need no test module. This is a change of the design of the release image, and comes after the move.

## The tool in packages

The tool is 124 714 lines in one package of 301 files: 201 sources and 100 host tests with 672 test procedures. Each command compiles the whole package first, and each host test of the tool runs with all the others.

What changed: the order of the packages, and the place of the concerns that the first form put in the wrong package. A read of the declarations of the tool, of what each body reads, found four cycles in the first order. The form below has none.

**The chosen form: one command, `modustool`, whose package holds the table of the commands, and one package for each concern under `tools/modustool`.** The packages import each other through a source library of the tool, `-collection:modustool=tools/modustool`, so that a package has one import line in each package that imports it: `import "modustool:foundation"`. The command package stays at `tools/modustool`. It holds `main.odin` and the host test of the path constants, which reads a constant of each package, and it is the only package that imports all the others.

The packages, in the order of their imports: a package imports only packages above it in this list, because the compiler refuses a cycle.

1. **`foundation`**: what each other package uses. The folders of the sources and of the build, the source libraries and their flags, the table of the modules with its groups, the run of a process and the pool of host processes, the read and the write of a file, the lines of a text, the print of a passed test, the hang bound, the reader of the Odin sources of a folder, the lines of a manifest.
2. **`resources`**: the commands that make a resource of the boot image: the mark and its pictures, the fonts, the pointer themes, the portraits of the hall of fame, and the PNG files.
3. **`build`**: the compile, the description of the exports, the conversion to a module file, the incremental build, the boot images, the boot volumes and the table of the self tests that each of them holds, the signatures, the system description, the release image, the module of a source outside the repository, the writer of the disk of `module-disk`, and the checks and the pages that each build runs: the check of the imports and of the roles, the vector instructions and the deepest stack of the kernel, the manual pages with the declaration index and the reader of the glossary.
4. **`checks`**: the checks of the sources and of the documents, the readers of the formats of the changelog, the roadmap and the news, the reader of the pointers of a document, and the measures: the table of the measures, the measure record, the measure history and the lines of each measure process.
5. **`fuzz`**: the engine, the targets, the corpus, and the host half of the fuzzing of the kernel operations: the model of the operation sequences, the writers of the records, and the format and the reader of the corpus of the operations.
6. **`similarity`**: the similarity finder. It reads `foundation` only.
7. **`machine`**: QEMU, the scenarios with their `Step` types and the runner of a machine test, the peer of the network, the screenshots, the films, the measure runs, the power loss, the network block device, and the fuzzing of the kernel operations on machines.
8. **`site`**: the pages of the site, with the renderer of the Markdown, the byte layouts and the check of the pointers of an intent file, which read the model of the site.

A declaration that a lower package needs from a higher one moves down to the lowest package that each reader can import. The state that a command sets for its process (the folder of the modules of a build, the debug information, the folder of the imports of an outside module) moves to `foundation` with the procedures that read it. A host test moves the other way: a test that reads a higher package goes to the test files of that package. No test reads a test file of another package.

Why each concern is where it is:

- **`resources` before `build`.** Each build converts the pointer themes and the glyph caches, and the release image converts the pointer theme of the owner. `resources` reads no declaration of `build`.
- **The fuzzing of the kernel operations on machines in `machine`.** It starts machines, reads the peer and the runs of the parts, and the table of the parts of the machine test runs the operation sequences. In `fuzz` it would make `fuzz` and `machine` import each other. The command `fuzz` reaches both halves, so its procedure is in the command package.
- **`Step` and the runner in `machine`.** Once the fuzzing on machines is there, no other package reads them. Only the hang bound goes to `foundation`, because the host fuzzing reads it.
- **The checks that each build runs in `build`.** The build calls them before or during its compile; in `checks` they would make `build` import `checks`, which reads `build`.
- **The measures in `checks`.** The release of the changelog copies the measure record to the history, and the record reads the changelog for its release number. `checks` is the lowest package that `checks`, `machine` and `site` can each import.
- **The byte layouts and the pointers of an intent file in `site`.** They take the model of the site, and the renderer of the site calls the writer of a byte layout fence.
- **The table of the commands.** The site shows each command, and cannot import the command package. The type `Command` is in `foundation`, and the command package gives its table to the site as an argument.

What the split gives: a border between the concerns that the compiler holds, the host tests of one package at a time, and a reader who finds a concern in one folder. What it does not give: a fault of the site still stops the compile of the command, because the one command compiles in each package.

Refused forms:

- **One binary for each concern, which the command starts.** A fault of one package then stops only its own command, but the tool has several outputs that each command must find and build, and a fault of a package is found by `-vet` of the check in any case.
- **Relative imports between the packages of the tool.** One package then has two import lines: `"foundation"` from the command and `"../foundation"` from a package.
- **The site in a tool of its own.** The site reads the table of the modules, the declarations and the measures that the other packages hold: it imports them in each form.
- **A ninth package for the readers of the documents, below `build`.** The renderer of the Markdown reads the model of the site (its links, the colors of the code, the diagrams): such a package would hold most of the site. The reader of the pointers goes to `checks`, the declaration index and the lines of the Markdown to `build`, and the renderer stays in `site`.
- **The `Step` types and the runner in a base package.** One package reads them: a base package would hold 5 000 lines for one reader.
- **The site reads the table of the commands from the source of `main.odin`.** The help line of a command is a concatenation of constants, which only the compiler evaluates.
- **The path constants of every package in `foundation`, for the one host test that reads them.** Each concern would lose its own paths. The test stays in the command package, which imports each package.

Decided points of the move:

- **The file names stay.** A file keeps its name in its package (`site/site_render.odin`), so Git finds each rename, the rewrite of a document path only inserts the folder of the package, and a bare file name in a comment stays unique in the tool.
- **The data of a package moves with it.** The corpus of the fuzzing goes under `fuzz`, and the kept list of the similarity finder under `similarity`; each path changes in one constant.
- **The prefix `site_` of a name that leaves the site** (a line reader in `foundation`, the declaration index in `build`, the pointer reader in `checks`) says something false. These names got their new names in their own commit after the last move, so that each move commit only moves: `lines_of_text` in `foundation`, `declaration_index_make` in `build`, `document_pointers` in `checks`. A new name is a word that no file of the tool or of the documents used before, so that it hides no local, no field and no member. A name that leaves the site and names a thing of the site keeps its prefix: the files of the mark and the icons that the site serves (`SITE_FAVICON` in `resources`), the folder of the pictures of the site, the style rules of the charts of the home, the guides that the site leaves out, and the place of a number on its page.
- **The names inside the package `site` keep the prefix `site_`.** It is redundant after `site.`, but the names are read inside the package without the qualifier, where the prefix separates a name of the site from a local of the same word (`Site_Page`, `page`). A rename of the names of the site is a separate change, and no decision asks for it. The file names keep the prefix too, for the reason of the file names above.
- **No `@(private)` for the names inside a package.** The tool has no package-private declaration today, and a review of each declaration is a separate change.

Subtle points:

- **The identity of the tool follows its own source library.** Each build key holds one hash over the sources of the tool and of the packages that it imports. The reader of the imports follows `modustool:`, so a change of a file of a package of the tool builds each module again. Without it the hash would cover the folder of the command alone, and a changed package would keep old modules with no error.
- **The output folder of the build is ignored at the root only.** `.gitignore` names `/build/`. A pattern `build/` with no `/` before it also ignores the folder of the package `build` of the tool, and a new file of that package would then miss the flake with no error.
- **The seed of the fuzzing of the check reads the tool to any depth**, so a change of a package of the tool explores other inputs.
- **The check of the source paths reads the spans under `tools/`**, so a move of a file of the tool cannot leave a dead pointer in a guide in silence.
- **A local named as a package hides the package.** `build: Module_Build`, `machine: ^Machine` and `site: ^Site` are common locals. A body that also reads the package of that name renames its local.
- **The instrumented child of the fuzzing chooses its files of LLVM IR by the name of a package.** No package of the tool has the name of a package of the system, so no code of the tool gets counters.
- **A comment of a module that names a file of the tool is a part of the module.** The comment before `package` is the documentation that a module file carries, so its rewrite changes the module. Five modules hold such a path in that comment: `math` (`describe.odin`), `test_callee` and `test_caller` (`modules.odin`), `net` (`peer.odin`) and `debug_target` (`debugger_scenario.odin`). Their hashes change, and each other module keeps its hash. The rewrite of `debug_target` stays on its line, because its tests name lines of its source.

### The tool built once

What changed: the command of the flake compiled the whole tool at each call (`odin run`). It now runs a binary that is compiled once for each change of its sources.

**In the check of the flake.** The tool is a derivation of its own, `modustoolBinary`. Its source is the set of files that its compile reads: the `.odin` files that are not tests of `tools/modustool`, of `src/library`, of each folder under `src/kernel` (the kernel parts, not the kernel), and the font that a fuzz target loads (`resources/fonts/commit_mono.ttf`). The check `boot-test` and the release shell run its binary. Nix builds it again only when one of those files changes: a change of a guide, a test or a module does not compile the tool. The binary is compiled with `-define:TOOL_BUILDS_ITSELF=false`, and never compiles itself: its sources are the inputs of its derivation.

**In the development shell.** The command `modustool` runs `build/tool/modustool`. When the file is absent, the command compiles it first. Before each command, the binary compares the build key of its sources with the key of its build record, `build/tool/modustool.build_record`, as the incremental build does for a module ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The incremental build"). When the two keys differ, it compiles the tool again, then runs the new binary with the same arguments and ends with its status. The key covers:

- the list of the files that the compiler read (`-export-dependencies`): the sources of the tool, of the two source libraries, of the libraries of the compiler, and the files of `#load`;
- every other file of the folder of each of those sources, so a new file in a package is a change;
- the command of the compiler with each flag, and the program `odin` (its path in the store, its size and its time).

So the sources of the tool are what its compiler read, not a list that the tool writes: an import of a new package is in the next list with no change of the tool.

**The one way to call it** stays `nix develop -c modustool <command>`.

**The measure.** Each compile of the binary of the shell prints `modustool: measure: the compile of the tool: <seconds> s`. The derivation compiles with `-show-timings`, so its build log gives the time of each phase of the compiler. Each is a measure: nothing reads it. No claim of speed is made without such a number.

Refused forms:

- **The binary compares the time of each source with the time of the binary.** A time of a file is not the identity of a source: a checkout, a copy or a branch switch sets times that say nothing of the bytes. The key, and not a time, decides. A time is read only to refuse a record when a source changed during the compile, as for a module.
- **The command of the flake hashes the sources.** The hash would then be a second implementation of the build key, in a script of the shell, and the two must agree. The tool has the build key; the command only makes the first binary.
- **One hash over the folders of the tool and of its imports** (the identity of the tool that the build keys of the modules hold). It holds the host tests, so each change of a test compiles the tool, and it does not hold a file of `#load` outside those folders.
- **The binary of the store in the development shell.** Each change of a source then builds a new derivation, which copies the sources to the store first, and a binary in the store cannot be a build of a work tree that has changes.
- **The check that runs the command of the shell.** The check then compiles the tool in its sandbox at each run, also when no source of the tool changed.

Subtle points:

- **A process that a command starts does not check again.** The first process of a command sets `MODUSTOOL_SOURCES_CHECKED` after its check, and each process that it starts inherits it: a step of a module, a boot volume, a fuzz child, the binary that it compiled. Each would otherwise hash the sources again.
- **The binary of the store and the instrumented child of the fuzzing never compile themselves.** Each is a build at another place than `build/tool/modustool`, and has no folder of sources of its own; the child is compiled with the same flag as the store binary.
- **A compile writes files of its host process.** The new binary and the list of the compiler go to files whose names hold the number of the host process, then the binary moves to its place. Two commands that start at once after a change then never write one file; the one that moves last leaves its binary.
- **The first command of a new work tree compiles the tool two times.** The command of the flake makes the first binary with no record, because only the tool computes a key, and it must compute the key before the compile starts. That binary finds no record and compiles again, with its record.
- **A failed compile runs nothing.** The record of the binary before is removed before the compile, so the next command tries again; the old binary does not run code of older sources in silence.

## The rules of the imports

The tool holds each rule at the start of each build, and in `modustool check` ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The imports of the sources of the system"). The reader is the parser of the library of the compiler. It reads each file of `src/`, also a file that a build tag leaves out: the check is stricter than the compiler, never looser.

- A source of `src/` that is not a test imports a package of `base:` or of `modus:` only, and a kernel source also `kernel:`. A package of the core library is refused: it reaches the host. `gt:` is refused too: the toolkit of rich modules serves outside modules only, which import `gt:` and the core library on the target modus ([third_party_module.md](third_party_module.md); [../features/desktop_to_browser.md](../features/desktop_to_browser.md), "The toolkit of rich modules"). This rule binds the code of the system, and no outside module.
- A test imports a package of the core library only with `#+build !freestanding` as its first build line.
- The kernel and a kernel part import a contract package or a kernel part only. A contract package imports no support package and no private part.
- `kernel:` is refused in each file of `src/` outside `src/kernel`, and so is a relative path that lands in `src/kernel`.
- A source of a kernel part is pure: each package variable is `@(rodata)`, no variable is `@(static)` or `@(thread_local)`, and it holds no foreign import or block, no asm template and no intrinsic that reads the machine.
- A private part `modus:private/<module>/...` is imported only by a file of the folder of the module `<module>` or of another private part of the same module, and by a host test when `<module>` is in the module group `libraries`. A name of `<module>` that names no row of the table of the modules is refused.
- The owners of a package of the library are the bodies of code (the kernel, the boot program, each module) whose chain of imports reaches it. A support package has two owners or more. A private part has its module as its one owner. A contract package that the kernel alone owns is refused: it is a kernel part. The tool is not an owner: it builds the system and is not a part of it. A refusal names the one owner, so the message says where the package goes.
- A path with `..` or with a part `.` after the name of a library is refused. A relative import is refused in a source; a host test and a file of the copy of the cryptography of Odin reach a folder of the repository by one.
- A relative import that lands in the folder of a module, `src/modules/<group>/<module>` or under it, is refused in each file of `src` outside that folder and in each file of `tools`. The check resolves the path from the folder of the file. A foreign import, such as the assembly of `src/runtime` that a host test links, is not this rule.
- A file that the parser cannot read whole is refused as a file.

**Why this is complete**: if no file of `src/` imports outside its list, no chain of imports from the kernel reaches a support package, and no source that a build of the system reads reaches the host.

**The test that breaks this design on its first day**: a support package that only one module imports, a private part of `console` that `compositor` imports, a kernel part that a module imports or that a host test of the library reaches by a relative path, a module that a host test or the tool reaches by a relative path, and a kernel part with a package variable that is not `@(rodata)` or a variable marked `@(static)`. The build must stop and name each file. A host test of the tool holds each case on a small tree.

**What the contract-only compile gave up.** A contract package that no module and no host test imports is compiled by no command. Today two contract packages have no importer in `src`: the tool reads `operation_sequence`, the format of a sequence of the fuzzing of the kernel operations, and `release`, the version numbers. The owner rule does not refuse them, because the kernel does not own them; the compile of the tool compiles each.

## What a third party types

- In a source: `import "modus:support/system"` and `import operation "modus:contract/operation"`. A private part and a kernel part are not for it: the first says so in its line, and the second is in no source library that it gets.
- For a language server and for `odin check`: one source library, `modus`, at `<the repository of modus>/src/library`.
- To build a module: the tool ([third_party_module.md](third_party_module.md)).

**The proof of the second constraint.** `modustool check` copies the sources of two modules of the system to a folder outside `src`, with no change, and builds a module from each copy with the command of a developer of another project ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "A module from a source outside the repository").

The words "SDK" and "collection" are not terms of the system: the term is source library, and `-collection` is only the name of the flag.

## The hazards of a move

These held for the move of the seven folders under `src` and the one library, and hold for each step below.

1. **The paths of the tool.** Each folder of the sources has one named constant in one file of the tool, and each path of the tool is made from them. A path that is missed is a folder that a check no longer reads, with no error. The new folders get their constants: the private parts, the source library `kernel` and its flag, the four module groups. Some lists name a package by a constant and its name (the folders of the host tests, the exceptions of the choice check, the packages of the fuzz targets): each such line changes with its package.
2. **The hashes of the modules.** A module is compiled with the file names of the sources and not their paths, and an import line is not in the output. But the compiler orders the packages by their path, so a move that changes the order of the packages of a module changes its hash, with the same size and the same procedures in another order. After the first move, 64 of 89 modules had another hash; after the one library, 66. So the hashes are a proof of a move only for the modules whose order did not change. Each step below says which modules are expected to keep their hash; `modustool module-hashes` compares a build with a record ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The hashes of the modules of two builds"). A hash that changes and is not expected is read to its cause. The full check is the proof.
3. **A text in a source is not a comment.** A source that holds a path in a text that its process draws or prints changes its module and the width of a text in a window. A step that rewrites a path in a text says so, and the pictures of its windows are viewed.
4. **The debug objects and the paths in the windows.** A debug object holds the path of each source from the root. A stop report, a stack trace and the debugger show it. The module groups make the path of a module longer: the path of a demonstration under the new folder of its group is 14 bytes longer than under the old folder src/programs. View each picture that shows a path (`errors`, `inspect`, the debugger) against the rule of the text box ([`../features/text_box.md`](../features/text_box.md)). The first move made a stack trace four bytes longer, and the windows of `errors` and `inspect` cut it; that fault is fixed, and each frame now shows whole.
5. **The pointers of the documents.** A code span of a guide that names a file of the repository is a link on the site; a path that no longer exists stays as plain code, and the link is lost in silence. So each path in the guides, the glossary, the README, `AGENTS.md`, this folder and the comments of the sources is rewritten in the commit of the move. The news entries and the released sections of the changelog are records of their time and stay. The check ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The source paths in the documents") refuses a span that starts with a folder that no longer exists: each step adds its old folders to that list.
6. **A rewrite by prefix is not safe at any place.** A name of a folder is also a part of a longer path, and after a move the old start is the start of the new path: the path of a module under `src/modules` with no group is the start of nothing after the move, but a rewrite that runs twice repeats the name of the group. Rewrite a path only where it starts (after a code mark, a quote, a parenthesis or a space, never after a `/`), with the name followed by `/`, a quote or a code mark, and run each rewrite one time from one list of the names and their new folders. A name of a module is also a name of a package or a word: `storage`, `network`, `log`, `boot`, `programs`.
7. **The relative paths.** The compiler reads the path of a `#load`, of a relative import and of a foreign import from the folder of the file that holds it, and the assembler reads an include from the root, where it runs. Each one changes when its folder gets deeper. Each step below counts them.
8. **The files of another origin.** A taken file of the cryptography of Odin names its manifest by its path, and the list of the system files holds the hash of each file that the project wrote. No step below moves the cryptography or names it in a manifest, so no line of a manifest changes.
9. **The branches of other agents.** A branch that was made before a move adds its files at the old paths. A move runs when no other branch is in flight, and each worktree is made again after it. The steps of the private parts and of the kernel parts touch few files and run between two batches; the module groups and the split of the tool touch most files of the repository and run alone.
10. **The history.** Move with `git mv`. Git finds a rename when a file keeps most of its lines, so a step is one commit: the move, and the few lines that the move breaks. A commit that only moves does not build.
11. **The fixtures of the host tests.** The tests of the tool that build a small tree place its parts at the folders of the constants. A test that only holds a path as a text of its small tree stays.
12. **A folder named with no `/` is not a path for the check.** A sentence that lists the folders of a check by their names alone is found by a search for each name as a whole span.

## The steps

Each step is one commit that builds and passes its checks. Steps 1 and 2 went in together, in one commit: their expected hashes were not checked apart (step 1 alone changes `root`, step 2 alone the two kernels). A rule of the imports enters as a refusal in the commit where the tree first holds it: no rule runs first as a report that does not fail, because such a mode is a path that the next commit removes. The counts are from the tree before the first step.

1. **The rule of a bridge as a contract.** Built. By hand, not by a command: `CONFIGURATION_WORDS`, `STATUS_CAPABILITIES`, `CAPABILITY_PCI_EXPRESS`, the port types, `express_port_type` and `bridge_passes_requesters` leave `iommu` for the new contract package `bridge_requester`, with their host tests. `bridge_shared_requester` stays in `iommu`: it gives a requester identifier, a format of the IOMMU, and only the kernel reads it. The kernel (two files), the root service (one file) and `iommu` import the new package. Expected: the two kernels and `root` change their hash; each other module keeps it.
2. **The kernel parts.** Built. `git mv` of four folders, 10 files, from `src/library/contract/` to `src/kernel/`: `acpi_processors`, `debug_exception`, `iommu`, `processor_counters`. One rewrite of 9 import lines (6 in 6 files of the kernel, 3 in 2 files of the tool) from `"modus:contract/<part>"` to `"kernel:<part>"`. By hand in the tool: the source library `kernel` and its flag on the three compiles, the 4 folders of the host tests, the 4 exceptions of the choice check, the packages of the fuzz targets (each now a folder from the root, made from its constant, by one rewrite of the 38 lines of the list), the rules of a kernel part in the check of the imports, the flag of the tool in the flake. Paths of the documents: 6 spans in 4 files with the folder, and 4 spans of the old folder of `iommu` in 3 intent files. No relative path. Expected: the two kernels change their hash (their package order changes); each other module keeps it.
3. **The private parts.** Built. `git mv` of 16 folders, 49 files and 19 343 lines, from `src/library/support/` to `src/library/private/<module>/`: `addresses` (`inspect`); `bar`, `palette` (`compositor`); `console_language`, `console_results` (`console`); `debugging` (`debugger`); `information`, `manual_navigation`, `source_comment_markdown` (`manual`); `kernel_events_rounds` (`kernel_events`); `keyboard_layout` (`input`); `replacement_signature` (`root`); `storage_mount`, `storage_object`, `storage_retention`, `storage_tree` (`storage`). One rewrite of 52 import lines in 37 files (38 lines in 27 files of `src`, 14 lines in 10 files of the tool) from `"modus:support/<part>"` to `"modus:private/<module>/<part>"`, from one list of the 16 pairs. By hand in the tool: 18 lines that name a part by its constant (the folders of the host tests, the choice check, the fuzz targets), and the owner rules of the check. One relative `#load` of a font, in the test of `bar`, gets one `../` more. Paths of the documents: 73 spans in 40 files (the glossary is now one file for each group). Found at the move, beyond the count: the six lists of the tool that name the support packages as a folder to read (the comment rule, the fixed addresses, the inputs of a build key, the declarations and the pointers of the site, the cut texts) name the private parts too; the similarity finder counts a private part as code compiled in; and one text that the process `manual` draws named `modus:support/information`, so it no longer names a package (hazard 3). Expected: the 9 modules that import a part change their hash (`compositor`, `console`, `debugger`, `input`, `inspect`, `kernel_events`, `manual`, `root`, `storage`); each other module keeps it.
4. **The module groups.** Built. `git mv` of 101 folders, 176 files: the 85 of the old folder src/programs and the 16 of `src/modules`, to `src/modules/<group>/`. The group of each module is written once, in the rows of the table of the modules; the moves and the rewrites are made from that table. One rewrite of the 101 sources of the table, and of the paths: 234 spans in 80 files (17 guides, 8 intent files, the README, 32 sources of `src`, 22 files of the tool). Relative paths: 10 `#load` of a font one level deeper (7 in `vector_glyphs`, 3 in the tests of `drawing` and `text_shaping`), and the 2 relative imports of the module `cryptography` in the peer of the tool. The 5 `#load` of the portraits of `hall_of_fame` are inside its folder and stay. Found at the move: the rows of the table had no other fact that said which module is a process, so they got the field `entry` (above); the check of the source paths no longer read a span that starts with the old folder src/programs, because no folder of the sources has that name, so a list of the folders that a move removed keeps such a span refused; a host test of `interface` holds a stack trace as data, with a break at a fixed width, and keeps its text (hazard 11); the fileset of the tool in the flake names the module `cryptography` by its folder. The rewrite of the paths read only the lines that are whole comments in the tests of the tool, and ran twice, as it is idempotent, for two paths that share one separator. Expected: each module keeps its hash, because a module folder stays after `src/library` in the order of the paths; the debug objects change; view the windows that show a path (hazard 4).
5. **The tool built once.** Built. The flake builds the tool as a derivation and the check runs the binary; in the development shell the binary compiles itself again when the build key of its sources changes ("The tool built once"). Each compile prints its time as a measure. No file of `src` changes, so each module keeps its hash.
6. **The tool in packages.** First, with no move, the four faults that a move would make silent: the identity of the tool follows `modustool:` imports, `.gitignore` ignores `/build/` only, the seed of the fuzzing reads the tool to any depth, and the check of the source paths reads the spans under `tools/`. That check found no stale span in the documents that it reads. Then one commit for each package, from the bottom of the list: `foundation` first, then the smallest package that imports only the packages that exist: `similarity`, `resources`, `build`, `checks`, `fuzz`, `machine`, `site`. A package cannot import the command package, and each concern reads `foundation`, so no other package can move first. In each commit: `git mv` of the files of the package, a rewrite of their package clause, the declarations that move down into the files of the package, the tests that move up, and the prefix of the package on each name that another package reads. The compiler names each use that needs the prefix: an undeclared name at its line and column. A rewrite by word is refused, because a name of a procedure is also a field (`run`) or a word of a text. A read of the declarations of the tool counts about 695 names that cross a border and about 4 600 uses that get a prefix; the compiler gives the exact count at each commit. The paths of the documents: 187 spans of a file of the tool in 67 files, the news and the changelog left out. Expected: `math`, `test_callee` and `test_caller` change their hash in the commit of `build`, and `net` and `debug_target` in the commit of `machine` (the subtle points of "The tool in packages"); each other module keeps it. Measure the compile time of the tool again.

The full check runs after the last step. A step whose expected hashes do not hold is read to its cause before the next step.

## The subtle points

- **The owners, not the import lines.** `line_editor` has one importer with an entry, `console`, and one library importer, `palette`, which is a private part of `compositor`: it has two owners, and stays in `support`. `storage_object` has two importers, `storage` and `storage_mount`, and one owner, `storage`. Count the bodies of code whose chain of imports reaches a package, never the files that import it.
- **The tool is not an owner.** Five private parts are read by the tool too. A package that one module and the tool read is private to that module: the tool builds and tests the system, and a third reader does not make a package shared between modules of the system.
- **A kernel part is pure.** A rule on writes ("no procedure writes a package variable") was refused: it needs an analysis of each write, and it does not see a `@(static)` local, a `foreign` block, `asm` or an intrinsic that reads the processor. The syntactic rule needs only the attributes and the names, and the compiler and the memory of the machine complete it. A rule that refuses each package variable was refused too: it refuses the read-only tables of the parts.
- **The kernel has no suffix of its processor in its file names.** Each kernel file is for x86-64. The rule of the suffixes of a platform (`_amd64`, `_arm64`) applies to the kernel and its parts before a second target is built, and not before.

## The state

Built: the folders under `src`, the one source library `modus`, the check of the imports with the rules of the kernel and of the contract packages, the constants of the paths of the tool, the check of the source paths in the documents, and the command `module-hashes`. The rule of a bridge as the contract package `bridge_requester`. The kernel parts `iommu`, `acpi_processors`, `debug_exception` and `processor_counters` under `src/kernel`, the source library `kernel` with its flag on the compile of the kernel, the host tests of its folders and the compile of the tool, the refusal of `kernel:` and of a relative path into `src/kernel` in each file of `src/` outside `src/kernel`, and the check that a kernel part is pure. The fuzz targets name each package by its folder from the root, so a kernel part is a target as a contract package is. The check of the fixed addresses reads the kernel and its parts. The tool built once: the derivation of the check, and the binary of the development shell that compiles itself again when the build key of its sources changes. The private parts of 9 modules in `src/library/private/<module>/`, the refusal of a private part imported from another module, and the count of the owners that refuses a support package with fewer than two owners and a private part that its module does not reach. One folder of modules, `src/modules`, in the four module groups, with the group of each row read from its folder (`module_group_of_source`) and the field `entry`. For the tool in packages, before any move: the identity of the tool follows the source library `modustool`, `.gitignore` ignores the output folder at the root only, the seed of the fuzzing of the check reads the tool to any depth, and the check of the source paths reads the spans under `tools/`. The first package of the tool, `foundation`: the folders and the source libraries with their flags, the table of the modules, the run of a process and the pool of host processes, the reading and the writing of a file and of a text, the hang bound and the reader of the Odin sources, with their host tests. The command package imports it as `modustool:foundation`, each compile of the tool and each host test of a folder of the tool get the flag of the source library of the tool, and the check runs the host tests of `foundation` as a folder of its own. The package `resources`, which imports `foundation` only: the mark and its pictures, the fonts and the glyph caches, the pointer themes, the portraits of the hall of fame and the PNG files, with their host tests in a folder of the check; the build reads the pointer themes and the glyph caches from it. The package `build`, which imports `foundation` and `resources`: the compile, the description, the conversion, the incremental build, the boot images and volumes with the table of the self tests, the signatures, the system description, the release image, the outside module, the writer of the disk of `module-disk`, the build of the tool itself, and the checks and pages that each build runs (the imports, the roles, the vector instructions, the deepest stack of the kernel, the manual pages with the declaration index and the reader of the glossary). The check of the choice constants reads a use through the source library of the tool, so a constant that another package uses with its package still counts in its family. The package `checks`, which imports `foundation`, `resources` and `build`: the checks of the sources and of the documents, the readers of the changelog, the roadmap and the news, the reader of the pointers of a document, the check of the film of a document, the host tests of the check with the list of their folders, the release command, and the measures (their table, the measure record, the measure history and the lines of each measure process). An example of each format that the tests of `checks` and of the site both read (a news entry, a measure record, a release of the history) is a declaration of `checks`, because a test file is not compiled with another package. The package `fuzz`, which imports `foundation` and `build`: the engine, the child, the instrumented build, the targets with their corpus in its folder, the reader of a disk of the storage service, and the host half of the fuzzing of the kernel operations (the model of the sequences, the generation of a sequence and of its records, the format and the reader of the corpus of the operations). The command `fuzz` is a procedure of the command package, because it also starts the fuzzing on machines. The package `similarity`, which imports `foundation` only, with its kept list in its folder. Neither of the two imports the other. The package `machine`, which imports `foundation`, `resources`, `build`, `checks` and `fuzz`: the command line of QEMU for a test machine, the runner of a machine test with the `Step` types, the scenarios and the table of the parts, the peer of the network and the calls from the host, the films, the measure runs, the power loss, the network block device, and the fuzzing of the kernel operations on machines with the writer of their corpus. The build of the system that a command or a film asks for (`build_system`) is in `build`, the lowest package that each caller imports. The package comments of the modules `net` and `debug_target` name a file of `machine`, so their hashes changed with the move. The package `site`, which imports `foundation`, `resources`, `build` and `checks`: the pages, the renderer of the Markdown, the byte layouts and the pointers of an intent file. It takes the table of the commands as an argument of its command. The tool is now in packages: the command package holds `main.odin`, with the table of the commands, its dispatch and the commands that reach several packages, and the host test of the path constants.

Left: the boot image of a release with no test module. It is an entry of [`ROADMAP.md`](../../../ROADMAP.md).
