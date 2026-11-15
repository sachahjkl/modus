# A module from a source outside the repository

A developer writes a module for the system in a folder of another project. The tool of the system builds the module file and the debug object from that folder. The developer keeps no copy of the sources of the system and changes no line of them. This file is the design of that build.

The terms outside module and module build file are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Outside module". The layout that this design builds on is [repository_layout.md](repository_layout.md).

## The constraints

- **One build path.** An outside module passes the two steps of a module of the system, in the same procedures, with the same commands. A second path would give a module that the checks of the system never proved.
- **No change of the system.** The module table of the tool gets no row for an outside module. A folder of the system gets no file.
- **No fact of the host in an output.** The module file and the debug object hold no path of the computer of the developer, as for a module of the system.
- **The tool reads the file of the developer exactly.** A line that the tool does not know stops the build. The tool guesses no field.
- **An import names a hash.** The import table of a module holds the hash of the file of each import. So the build needs the built file of each import, not only the sources of the system.

## What the developer has

1. A folder with one Odin package: the sources of the module, and its assembly files if it has some. The sources import the packages of the system from the source library `modus`, with the lines of a program of the system.
2. In that folder, the module build file `module.txt`.
3. A checkout of the system. For a module with an import, the checkout is built: the build of the system wrote the file of each module.

### The module build file

The file has the fields of a row of the module table that a developer chooses, one on each line, as `key: value`:

```
name: my_program
imports: drawing
defines: DRAWING_THROUGH_MODULE=true
library: no
```

| Key | Value | Absent |
|---|---|---|
| `name` | The name of the module: lower case letters, digits and `_`, at most 31 bytes | Refused |
| `imports` | The names of modules of the system, in the order of the import table, with a space between two | No import |
| `defines` | Settings of the compiler for this module, `NAME=value`, with a space between two | None |
| `library` | `yes`: the module is a library module. `no`: it is not | `no` |

The rules of the reader: each line that is not empty is `key: value`; a key is written at most one time; a key that is not in the table is refused; a value of `library` that is not `yes` or `no` is refused. The file has no comment and no other syntax.

Two fields of a row are not in the file:

- **`kernel`.** An outside module never runs in kernel mode.
- **`image`.** In the table this field says two things: the module is in the boot image, and its link gets the assembly files of the system library. The tool sets it for each outside module. The link drops the procedures that the module does not call, so a module that does not use the system library pays nothing.

Why this form:

- The project already writes the head of a changelog fragment and of a news entry as `key: value` lines. A developer reads and writes this form with no tool.
- The reader is about forty lines, and each fault has one sentence.

The forms that were refused:

- **Arguments of the command** (`--name`, `--import`). The fields belong to the module, not to one run. A build that a developer types two times must give the same file.
- **A file in the syntax of Odin**, read with the parser of the compiler. The file would sit in the folder of the package. With the suffix of a source, the compiler compiles it. With another suffix, it is still a second language for four fields.
- **A table in Markdown, JSON or TOML.** Each needs a reader that accepts more than the four fields, and the project has none for a build input.
- **A row in the module table of the system.** It is a change of the system for each module of each developer.

## Where the tool finds the system

The tool runs in the folder of the system. Each path of a source of the system in the tool is a path from that folder, and the build keys, the debug objects and the messages depend on it. So the build of an outside module keeps that rule and moves the process:

1. The command reads the folder of the module and the output folder as the developer typed them, and makes each an absolute path with its links resolved.
2. It changes its working folder to the folder of the system.
3. It builds, with the folder of the module as the source of the row.

The folder of the system is, in this order: the argument `--system`, the environment variable `MODUS_SYSTEM`, the folder where the command runs.

The command `modustool` of the flake compiles the tool from its sources before it runs it. It reads `MODUS_SYSTEM` to find those sources, because it runs before the tool reads an argument. A developer who uses the command of the flake sets the variable. A caller that runs the file of the tool itself can give `--system`.

The forms that were refused:

- **A path of the system in each constant of the tool.** Each of about a hundred paths would take a prefix at run time. A path that is missed reads a folder of the developer with no error.
- **The system from the store of Nix** (a run of the flake with no checkout). The store is read-only: the tool cannot compile itself there. A module with an import needs the built modules of the system, which the store does not hold. The machine that runs the module needs the same built system. So a checkout is not a cost that this form removes.
- **A copy of `src/library` and `src/runtime` in the project of the developer.** The copy is the thing that the source library was made to end.

## Where the outputs go

The output folder is the argument `--out`, or the folder `build` in the folder of the module. The build writes there, and nowhere in the system. The command of the flake writes the compiled tool in the folder `build` of the system, as for each command. The outputs:

- `<name>.module` and `<name>.debug`;
- the folder `<name>`, with the files between the steps (the LLVM IR, the objects, the linked file).

The folder `build` is inside the folder of the package. The compiler reads the sources of one folder and not of the folders under it, so the outputs are no sources.

**The file of an import** is read in the folder of the modules of the build of the system. The tool has one more setting for it, beside the folder of the outputs: for a module of the system the two are the same folder.

**No build record.** The build of an outside module always runs its two steps. The incremental build compares the inputs of 90 modules; for one module the compare saves little, and a record in the folder of a developer is one more form to keep.

## The path of a source in the debug object

A debug object names each source file by a path that is not a path of the host: from the root of the repository for a source of the system, with the name of its library for a source of the compiler. A source of an outside module is in neither.

The chosen form: the path from the folder that holds the folder of the module. The file `main.odin` of the folder `/home/someone/projects/my_program` is `my_program/main.odin`. A stop report and the debugger then show the name that the developer gave the folder, and no folder above it.

- The rule for the folder of the module is read before the rule for the root of the repository. In the check of the project, the folder of the example is inside the repository.
- The writer of the debug object refuses an object whose bytes hold the folder above the folder of the module, as it refuses the folder of the build.
- Refused: the name of the module in place of the name of the folder. Two files of two folders would get one path only when the developer chose so, and the name of the folder is what an editor shows.

## What is checked

The rules that hold for each module, of the system or not. Each is a part of the one build path:

| Rule | Where it is held |
|---|---|
| Each function keeps its frame pointer | The command that makes the object |
| No thread-local data | The conversion |
| Each declaration of an import agrees with the description of its export, and each called import has a compared declaration | The conversion |
| A library module has no segment that the loader writes and that is read-only after the load | The conversion |
| No path of the host in the debug object | The writer of the debug object |
| The vet of the compiler (no shadowed local, no unused import) | The compile command |

The vet is a choice of the project more than a rule of the module contract. It applies because the build path is one, and a second compile command for an outside module was refused with the second path.

One rule is new, and is for an outside module only:

- **Each source that the compiler read is in one of three places**: the folder of the module or a folder under it, the source library `modus`, the libraries of the compiler. The tool reads the list that the compiler writes, after the compile step and before the conversion. A source in another place stops the build with its path.
- **Why this is complete.** A relative import that leaves the folder of the module (`"../shared"`), an import of the kernel through a path with `..` after the name of the library, and a source library of another name each put a file outside the three places in the list.
- **What it allows.** A package of the developer in a folder under the folder of the module, with a relative import. The rule of the sources of the system (no relative import at all) is a rule of that repository.
- Refused: a read of the import lines with the parser before the compile, as for the kernel. It reads files that the compiler does not compile (a host tool of the developer in a folder below), and the list of the compiler is exact.

The rules of the repository of the system that the tool does not apply to an outside module: the rule of the comments, the rule of the names, the rule of the imports of the kernel and of the contract packages, the check of the fixed addresses, the checks of the documents. They are rules for who writes the system.

## The proof in the check, and its limit

`modustool check` builds two outside modules, each from a copy of a module of the system:

- `tally`, a program with no import;
- `agenda`, a module that imports `calendar`.

For each, the check copies the sources with no change to a folder outside `src`, writes the module build file, and starts the tool as a second process in the folder of the copy, with the argument `--system`. So the check passes the path that a developer types: the read of the file, the change of the working folder, the two steps. Then it reads the module file and proves:

1. the loader of the system accepts the file (`module.validate`);
2. the file has the name, the parameters and the result of each export of the module of the system, and the same line of documentation;
3. the import table names the hash of each import of the build of the system;
4. the debug object is there, no path of it starts with `/`, and it names a source of the copy by the name of the folder of the copy.

**Why the bytes are not compared.** The compiler orders the procedures of a module by the path of its packages ([repository_layout.md](repository_layout.md), "What the move of the folders showed"). The package of the copy has another path than the package of the system, so the order can differ with the same procedures. The check prints the two hashes and says whether they are equal. It is a line of fact, not a condition.

**The test that breaks this design on its first day** is the second example. A module with an import needs the file of the import from the folder of the system while its own file goes to the folder of the developer, and the check of the declarations must find a source that is in no folder of the system. A design with one folder for both fails on it.

The limit: the examples are copies inside the folder of the build. A folder on another disk, or a path with a link, passes the same code after the path is resolved, but the check does not run it.

## Built and left

Built: a machine that runs the module (the command `program-disk` writes a data disk whose store of the programs holds module files, and the root service starts a disk program by its hash, with no grant: the boot image, its system description and its build record do not change); the debug object of the module in that machine (`program-disk` writes it beside the module file, and the debugger reads it at an attach: [`../features/debug_object_of_a_disk_program.md`](../features/debug_object_of_a_disk_program.md)); the command `module-build`, the module build file, the three settings of the process (the folder of the outputs, the folder of the imports, the folder of the outside source), the rule of the three places, the path of an outside source in a debug object, the variable `MODUS_SYSTEM` in the command of the flake and a development shell with the build tools and no hook of the repository, the proof with two examples.

Left:

- **The stop report of the module in the console, `inspect` and `errors`.** They read the debug image only, which has no debug object for a disk program: their stop report of the module shows addresses. The debugger names its frames. The roadmap holds this work.
- **An import of another outside module.** An import names a module of the system. A developer with a library module and a program of their own needs a second place for the file of an import. The roadmap holds this work.
- **A module in another language.** The description of the exports comes from the Odin source.
