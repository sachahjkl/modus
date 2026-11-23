# The loop of a program written in the system

A principal writes a C program, builds it and runs it, with no host and no step outside modus. Then the principal changes the source, builds again and sees the new result. The loop joins parts that exist apart: the editor ([editor.md](editor.md)), the C compiler and the assembler ([c_compiler.md](c_compiler.md), [assembler.md](assembler.md)), the recipes and their realisations ([recipes.md](recipes.md)), the projects ([declarations.md](declarations.md)) and the store `module_files` ([processes_from_a_disk.md](processes_from_a_disk.md)).

## Purpose

The owner wants a programmable environment that holds its own tools: a program of the system is written, built and run in the system. The first loop is the smallest one that works end to end. Each later step adds to it: a program of several sources, a program with an `entry`, grants for a program.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": the compiler, the assembler and the program each run with only what the step gives them.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": the source has no save action, and each change of it is a version.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": a build is a recipe, whose hash names its inputs, and its output has one hash.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": the source and the module are bytes, the recipe and the result are records.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": the built program reaches only what its project declares.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": each step of the loop is one line of the console.

## The chosen form

### The loop, line by line

```
> projects.new("hello")
> edit("hello", "hello.c")                 // the window of edit: type the source
> build("hello", "hello.c")
hello: built, module 3f1c…, recipe 9a07…
> run("hello")
42
> edit("hello", "hello.c")                 // change the source
> build("hello", "hello.c")
hello: built, module 81d2…, recipe 5e30…
> run("hello")
43
> build("hello", "hello.c")                // the same source
hello: substituted, module 81d2…, recipe 5e30…
```

1. **The project.** `projects.new(name)` records a project of the principal of the caller in the private store of `projects`: its name, the store of its source, which has the name of the project, and its grants, none at its creation. The name follows the rules of a nickname of a disk process (`disk_process.name_problem`), so the module of the project can have the name of the project in the store `module_files`.
2. **The source.** `edit(name, file)` edits the object `file` of the store `name` ([editor.md](editor.md), "Subtle points and hazards"). The editor has no save action: each group of changes is a version of the object.
3. **The build.** `build(project, file)` is a command of the console. The console acts for its principal, so it reads the object `file` of the store of the project. It gives the bytes to `recipes.build_c`, which builds or substitutes. The console then gives the module to `module_files.put`, which writes it as the object named by the project in the store `module_files`, and gives the hash of its bytes.
4. **The run.** `run(project)` reads the module of the project from the store `module_files` (`module_files.read`), checks its hash, isolates it in a call host as `isolate_memory` does, and calls its export `main`. The console shows the result, and writes one line of the log with the name of the project and the hash of the module.

### The native C builder

The recipe of a build:

- **The builder** is the BLAKE3 hash of the context `"modus builder c v1"`, then the hash of the module `c_compiler` and the hash of the module `assemble` of the boot image. A new compiler or a new assembler is a new builder, so a new recipe.
- **The inputs** are one row: the name of the source and the BLAKE3 hash of its bytes.
- **The arguments** are none.

`recipes.build_c` computes the recipe hash. In the local store of the realisations, a realisation of that recipe gives the module with no compile: the build is substituted. Else the service builds:

1. It starts the module `c_compiler` of the boot image in a call host, and calls `compile` with the source and a memory object for the text of the assembly.
2. It starts the module `assemble` in a call host, and calls `assemble` with that text and a memory object for the module.
3. It checks the module file (`module.validate`), computes its hash, writes the realisation and the module in its private store ([recipes.md](recipes.md), "The local store of the realisations"), then gives the module to its caller.

Each call host holds the module and the memory that the service lends for the call, and nothing else: no store, no network, no root ring. The seed of each is the recipe hash. A call host ends after its one call: `chibicc` keeps its state in static variables, and takes one source for each call host ([c_compiler.md](c_compiler.md), "One source for each call host").

**A C error builds nothing.** `compile` fails with its error record, whose value is the byte of the source that the diagnostic names. The service gives that record to its caller, writes no realisation, and the console shows the place: `build: hello.c, byte 31`, with the first line of the diagnostic in the log.

### The grants of a program

A program runs in a call host with no grant. Its project declares the grants that a run may give, and none at its creation. `run(project, grant)` asks for a grant: when the project does not declare it, the run is refused before the call host starts, with the error record of the missing grant. A project that declares a grant is planned work: the call host then takes the store of the project, which needs a store for a call host.

### Why each part is where it is

- **The console reads the source.** It acts for the principal, who owns the store of the project. `recipes` and `projects` then hold no right over a store of a principal.
- **`recipes` builds, not the console.** The realisation and its output are kept by the one service that keeps realisations, so a build of the same recipe from another console is a hit too.
- **`module_files` writes the module.** It is the one writer of module files in the store `module_files` ([processes_from_a_disk.md](processes_from_a_disk.md), "Subtle points"). `module_files.put` takes the bytes from its caller, with no network: the left work "A file from another store" of that intent, with the console as the reader of the other store.
- **The run reads the module by its nickname and checks its hash.** The object of a nickname changes at each build, and the older versions stay in the store as versions, so each module that was built is kept by its hash.

### The check against the properties

- **Property 2.** The compiler and the assembler hold only the memory of their call; the program holds only the memory of its call. None reaches a store, the network or the root ring.
- **Property 11.** The recipe hash names the compiler, the assembler and the source. The compiler reads no clock (its dates are the start of the epoch) and no file outside its table, so one recipe gives one module: the output hash. A second build of one recipe is a hit with no compile.
- **Property 19.** The source, the text of the assembly and the module are bytes in memory; the recipe and the result of a build are records.
- **Property 20.** A run gives no grant that the project does not declare, and the project declares none yet.

## Refused forms

- **The root service starts the native builder as a process** ([recipes.md](recipes.md), "The builder"). A call host of `recipes` with no grant is the same sandbox: it holds only the memory that its caller lends, and it needs no new command of the root ring, no input store and no store "out" for one source and one module. A builder of foreign code, whose inputs are trees, still needs the start of the root service with an input store and a store "out".
- **A builder module `c_builder` that imports `c_compiler` and `assemble`.** `chibicc` takes one source for each process, and the two steps are two modules of the boot image already; a module that only calls the two adds a third hash to the builder and no check.
- **The console builds.** The console holds the grants of its principal: a compiler that runs there runs with all of them.
- **`start_from_disk` for the program.** A module that `chibicc` writes has exports and no `entry`, and calls nothing of the system: it cannot run as a process. A call of its export `main` is what the program can do now.
- **The module in the store of the project.** The store `module_files` is the store of the modules of a principal, which the disk processes and the import scan read already.
- **A build at each change of the source.** A build is a command of the principal: a source with an error in the middle of a change would build at each word.

## Subtle points

- **The source is read whole, at most 64 KiB**: the bound of an object of the local store of `recipes`, under the 256 KiB of `compile`. The text of the assembly and the module have the same bound.
- **The text of the assembly and the module have the bounds of their memory objects.** A larger output fails the build with `Full`.
- **The run unloads the module of the run before**, so a run after a build calls the new module.
- **A substituted build reads the module from the store of `recipes`**, and checks its hash against the output hash of the realisation: a realisation that the service reads back from its private store keeps its object under the hash of its record, with no new hash of the bytes. A difference refuses the build with `Damaged`, and no module goes out.

## State

Built: `projects.new`, `recipes.build_c` with the native C builder, `module_files.put` and `module_files.read`, the commands `build` and `run` of the console, and the machine of the loop in `modustool test disk_processes`. The first call of `build` to `recipes` and to `module_files`, two services that start on demand, lends a handle: it needs the ready completion of the call ring ([../api/call_ring_ready.md](../api/call_ring_ready.md)). Left: a program of several sources, a program with an `entry` as a disk process, the grants that a project declares and a call host that takes them, and a build of the recipe by another machine.
