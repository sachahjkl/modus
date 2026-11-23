# Applications as projects

A program of the system is described as a Lex project: its source by hash, how it is built, and the module that it gives. The project travels as a tree, a machine builds it or takes its realisation from a cache, and it runs from the store. This file records the path from one project to a running module, layer by layer, what each layer can do today, and where it stops.

The terms Project, Recipe, Realisation, Builder and Object cache are in [`docs/glossary/code.md`](../../../docs/glossary/code.md). The mechanisms are [declarations.md](declarations.md) ("Projects", "Declaration inputs, pins and release pointers"), [recipes.md](recipes.md) and [c_compiler.md](c_compiler.md).

## Purpose

The system describes how a program is made, and a machine checks it, but no program of the repository is described that way yet: the declarations, the recipes and the cache are built and tested on records made by hand. A first real project, run through each layer, shows which layer holds and which does not, and gives the form that more programs then copy: a real program of others (Lua, SQLite, zstd, whose sources are pinned already) is the next project of the same form.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": the identity of the project is its tree hash, and the identity of the module is its hash.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": a build holds only its inputs.
- One form for every program: the project of a small program and of a large one are the same files, read by the same evaluator, loaded by the same service.
- A pin moves only by an update. A pin that the build of the repository rewrites at each commit is no pin.

## The chosen form

### Where a project lives

A project is a folder of its own, outside the sources of the system: `src/outside/projects/<name>`, as the outside modules are ([../infrastructure/third_party_module.md](../infrastructure/third_party_module.md)). It holds `project.lex`, `pins.lex` and its sources, and nothing of the system.

- **Why outside.** A program of the system imports the source library of the system, which changes at most commits. A project whose pins named that library would move at each commit, so its pins would be written by the build, not by an update. A project outside the sources names what it takes from the system through `catalog`, the catalog declaration of the system it is built on, and pins only its own declaration inputs.
- **Refused: `project.lex` beside a module of the system** (`src/modules/...`). Its pins would name the library tree, which moves at each commit.
- **Refused: a project with no `pins.lex`.** The design puts `pins.lex` beside each `project.lex`; a project with no declaration input has an empty record, `{}`, so a reader sees that it pins nothing, not that the file was forgotten.

### The first project: collatz

`src/outside/projects/collatz` is a C program of one function, `steps(n)`, the count of steps of the Collatz sequence from `n` to 1. C is the one language that the system compiles itself today: `c_compiler` writes the assembly and `assemble` writes the module file, in the system, with no host ([c_compiler.md](c_compiler.md)). Its project:

```
project {
  source = here(),
  outputs = {
    default = catalog.c.module("collatz.c"),
  },
}
```

- `source = here()` is the tree hash of the folder of the project.
- `catalog.c.module(path)` is the recipe of the C module of a file of the source: its builder is the C builder of the catalog, its argument record names the file. The project names no hash of the system: the catalog gives them.
- `pins.lex` is `{}`: the program has no declaration input.

### One identity for a recipe

The recipe that a project names and the recipe that the service `recipes` builds are one record with one hash: `plans_recipes.recipe_hash`, over the builder, the output kind, the source date, the input table and the argument bytes. The evaluator computes no hash of its own.

**An input carries its kind.** `here()` gives a tree, and `module(hash)` gives a module file, an object: each is a typed value, written in the output with its own tag (`Tree_Ref`, `Module_Ref`). A bare hash literal names no kind, so it names no input: a recipe whose arguments hold one is refused, and so is a builder given by a bare hash, the field `source` of a project, which is a tree, and a module of the field `console` of a project, which is a module file.

**`declaration` takes a tree.** A declaration is a tree, so `declaration(here())` reads the declaration of the source tree. `declaration(blake3:…)` stays: the function itself names the kind of its hash, the tree of one exact declaration ([declarations.md](declarations.md), "Declaration inputs, pins and release pointers"), and no other form names a declaration by its hash. A module file or a text is refused.

**The conversion has one place.** `plans_recipes.recipe_spec_of_arguments` reads a recipe as the evaluator writes it (its builder, then its argument record) and gives the record of the service; `recipe_spec_of_output` does it for the whole output of an evaluation whose value is a recipe, and checks that the hash that the evaluator wrote is the hash of the record:

- each field of the argument record whose value is a tree or a module file is an input, under the name of the field, with its kind;
- the other fields are the argument bytes: the record of those fields, in the canonical form of the output;
- a field `source_date` is also the source date of the recipe: an integer of 0 or more, and any other value is refused;
- the output kind is a tree, as each output of a recipe is ([recipes.md](recipes.md), "Trees").

It refuses a bare hash, a tree or a module file below the first level of the record (its input would have no name), a tag that names no kind, a value that does not decode, and an input table past `MAX_RECIPE_INPUTS`. The evaluator calls the same procedure at each `recipe(...)` to compute the hash that it writes, and the service calls it on the output of an evaluation, so the two cannot differ.

- **The canonical form first.** One value must give one argument form, so the conversion first checks the whole value with the reader of the output (`output_skip_value`): each record has its names in the order of their bytes with no name twice, at every level, each list and record holds at most `OUTPUT_COLLECTION_LIMIT` items, the nesting stops at `OUTPUT_DEPTH_LIMIT`, and the value ends at the last byte. `{a = 1, b = 2}` has one form only; the evaluator writes it sorted, and a written form with `b` first is refused. Then it walks the value, which can no longer fail to decode; each read still checks its refusal.
- **A private copy.** The walk reads the bytes several times, so they must not change under it: the evaluator gives its own buffer, and the service copies the bytes of its caller into its own memory before the conversion.
- **A refusal leaves nothing.** On each refusal the record is zero, so no caller reads a record half written.
- **The words of a refusal.** The evaluator gives each refusal of the conversion as the failure `Recipe_Refused`, with the words of that refusal (`plans_recipes.recipe_refusal_words`): "a bare hash names no input: use here() or module(...)", not a type error.
- **The bound of the written arguments.** The evaluator writes the arguments before it converts them, so its buffer holds the largest value that converts: `MAX_RECIPE_INPUTS` inputs with names of the largest length, and argument bytes of `MAX_RECIPE_ARG_BYTES` (`plans_recipes.MAX_RECIPE_ARGUMENT_VALUE_BYTES`, with an `#assert` of its sum).

### The export of the service

The service `recipes` takes a recipe in two forms. `register` takes the record in its parts (a head, the input rows, the argument bytes), as `projects.build_recipe` gives the recipe of the inputs of a project. `register_evaluation` takes the output of an evaluation whose value is a recipe, as `outputs.default` of a project: it copies the bytes into its memory, converts them with `recipe_spec_of_output`, and registers the record, under the hash that the evaluator wrote. Each refusal of the conversion is an error record of the service with the refusal as its value (`recipes_core.recipe_refusal_record`, one place for both exports).

Refused: **`register` taking the output too, by a flag.** One export with two forms of arguments has parameters that one form leaves empty, and a border that checks which. Two exports each take one form whole.

Refused: **the argument record of the builder declaring the kind of each input.** Each builder would repeat the kind of each of its inputs, and two builders could give one value two kinds; the value itself knows what it names.

Refused: **a kind guessed from the hash** (a lookup in the store). The evaluation reads no store, and the identity of a recipe would depend on what one machine holds.

### The catalog of the system

The catalog declaration of the system is the declaration that a project reads under the name `catalog`: a record of the release number, the modules and the builders of the system on which a project is built. Its hashes come from the built boot image, so the build writes it deterministically after the boot image exists, never by hand in the repository.

The build writes two files:

- `build/catalog.lex`, from `build/boot.image`: holds every module of the boot image.
- `build/catalog_release.lex`, for the release boot image (`build/boot_release.image`): holds only the shipped modules of a release, with no test module.

Each file has one canonical Lex record shape:

```
// Catalog declaration of modus <release>.
{
  release = "<release>",
  modules = {
    <name> = module(blake3:<64 lowercase hexadecimal digits>),
  },
  c = {
    compiler = module(blake3:<c_compiler hash>),
    assembler = module(blake3:<assemble hash>),
    module = (path) => recipe(module(blake3:<c_compiler hash>), {
      assembler = module(blake3:<assemble hash>),
      path = path,
      source = here(),
    }),
  },
}
```

- **`catalog.release`** is the release number string of the build (`release.RELEASE_NUMBER`).
- **`catalog.modules.<name>`** gives each module of the boot image as a typed module file, `module(blake3:<hash>)`, in ascending byte order of module name. The generator checks every module entry's bytes against its stated BLAKE3 hash and checks that each name is a valid Lex field name with no duplicates.
- **`catalog.c.module(path)`** gives the recipe that compiles `path` in `here()` with the `c_compiler` and `assemble` hashes of that build: `c_compiler` is the builder module, `assembler` is a typed `Blob` input, `source` is `here()` (a typed `Tree` input), and `path` stays in the recipe arguments. `catalog.c.compiler` and `catalog.c.assembler` expose the same two module files directly. Because both `c_compiler` and `assemble` ship with identical bytes in the development boot image and in the release boot image, a C project evaluates to one recipe hash against either catalog declaration.
- **Determinism.** The generator reads only the boot image and the release number, sorts the module entries by name, and writes no host path or timestamp. Two builds of the same boot image write identical bytes.
- **Border refusals.** The generator refuses a damaged boot image, an entry outside the image, an entry whose bytes do not hash to its stated BLAKE3 hash, an empty or malformed release number, a module name that is not a Lex field name or appears twice, a boot image without `c_compiler` or `assemble`, and, in release scope, any test module or module absent from the module table.

Refused forms:

- **Hand-written hashes in project files.** A project file names `catalog.c.module(...)` or `catalog.modules.<name>`, never raw module hashes of the system. Hand-written hashes go stale on every build and hide which system built the project.
- **A catalog declaration that names test modules in a release build.** A release image ships no test module ([../infrastructure/release_image.md](../infrastructure/release_image.md), "The release boot image holds no test module"), so a release catalog declaration refuses every test module and every single-image test module.

### The layers

1. **The project.** The evaluator reads `project.lex` with the tree hash of the folder as `here()`; the service `projects` loads the evaluation and `pins.lex`; the output is a recipe whose hash follows the source. Each part runs today, on the real files of the project, in a host test. A project with no pin has no recipe of its inputs: `projects.build_recipe` gives one input for each pin, and refuses with `Pin_Not_Found`.
2. **The build.** `recipes.build` of the output realises the module: the root service starts the C builder in a sandbox, the builder compiles and assembles, and the realisation is signed and stored. Then the module starts from the store.
3. **The cache.** The realisation goes to an object cache; a second machine takes it by its recipe hash with `Cache_Only`, and starts the module with no build.

### Where the path stops today

Layer 1 holds: the recipe that the project names reaches the service under one identity ("One identity for a recipe"). Layer 2 stops at three places, each an entry of `ROADMAP.md`:

- **No C builder.** No module exports the `build` of the builder contract ([recipes.md](recipes.md), "The builder"): `c_compiler` and `assemble` export their own calls, which the console chains by hand.
- **No source of a project in the place `objects`.** `recipes` starts a builder in its sandbox ([recipes.md](recipes.md), "The builder"), but an input must be an output of an earlier build: nothing imports the tree of a source from outside. The recipe of `collatz` is refused first with `Builder_Absent`, as no C builder is a module yet, and its source would be refused with `Input_Absent`.
- **No signature of a local realisation.** A realisation of the machine is kept, but not signed with the key of the principal.

Layer 3 needs layer 2, and the QUIC client of the object cache inside the system, which is also left ([recipes.md](recipes.md), "State").

### The checks

Host tests take the real files of `src/outside/projects/collatz` and pass layer 1 against a catalog declaration generated from a boot image by the real generator:

- the tree hash of the folder, from the bytes of its files;
- the generated `catalog.lex` and `catalog_release.lex` from a boot image with every boot module: deterministic bytes, every boot module present with its exact BLAKE3 hash, no test module in the release catalog declaration, and direct parsing and evaluation by `lex_evaluator`;
- the evaluation of `project.lex` with that `here()` and the generated `catalog.lex`, whole and at `outputs.default`, which is a recipe whose builder is `c_compiler` and whose inputs are `assembler` and `source`;
- the load of the evaluation and of `pins.lex` by `projects_core`;
- the recipe of the output, read back by `recipe_spec_of_output` from what the evaluator wrote, registered by `recipes_core` under the hash that the evaluator gave, and refused at its build with `Builder_Needs_Sandbox`: the stop of layer 2, read as a refusal of the service, not as a fault;
- a realisation of that recipe from a cache, trusted only when the key of the policy signed it intact.

The refusals come first: a `pins.lex` with a damaged hash, a project whose `source` is not a tree, a recipe whose builder needs a sandbox, a realisation of the project signed by a key that the policy does not trust and one whose signature is wrong.

## Refused forms

- **The build of the module by the tool, then a realisation written by hand.** It proves the tool, not the system: the realisation must come from a build on the machine.
- **A first project in Odin.** The system has no Odin compiler of its own; a build would run on the host or in the guest builder, which needs layer 2 as well.

## State

Built: the project `src/outside/projects/collatz` (`project.lex`, `pins.lex`, `collatz.c`) and the host test of layer 1 with its refusals; one identity for a recipe: `here()` a tree and `module(...)` a module file as typed values (`Tree_Ref`, `Module_Ref`), the conversion `plans_recipes.recipe_spec_of_arguments` and `recipe_spec_of_output` with host tests of each refusal, and the evaluator that hashes each recipe through it; the catalog declaration of the system written by the build (`build/catalog.lex` and `build/catalog_release.lex`) with its pure generator and host tests.

Left: a C builder, a builder started in its sandbox with a signed realisation, and layer 3: each an entry of `ROADMAP.md`.
