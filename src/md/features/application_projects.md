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

### The catalog of the system

The catalog is the declaration that a project reads under the name `catalog`: a record of the modules and the recipes of the system on which a project is built. Its hashes are the hashes of the built modules, so the catalog is an output of the build of the system, never a file of the repository written by hand. Until the build writes it, the tests give the evaluator a catalog of the same form.

### The layers

1. **The project.** The evaluator reads `project.lex` with the tree hash of the folder as `here()`; the service `projects` loads the evaluation and `pins.lex`; the output is a recipe whose hash follows the source. Each part runs today, on the real files of the project, in a host test. A project with no pin has no recipe of its inputs: `projects.build_recipe` gives one input for each pin, and refuses with `Pin_Not_Found`.
2. **The build.** `recipes.build` of the output realises the module: the root service starts the C builder in a sandbox, the builder compiles and assembles, and the realisation is signed and stored. Then the module starts from the store.
3. **The cache.** The realisation goes to an object cache; a second machine takes it by its recipe hash with `Cache_Only`, and starts the module with no build.

### Where the path stops today

Layer 1 holds, with one gap at its end, and layer 2 stops at three more places. Each is an entry of `ROADMAP.md`:

- **Two identities of one recipe.** The evaluator hashes `recipe(builder, arguments)` under its own domain, over the builder and the serialized arguments; the service `recipes` hashes a recipe record over the builder, the input table and the argument bytes (`plans_recipes.recipe_hash`). Nothing turns the recipe that a project names into the record that `recipes.register` takes, so the host test writes that record itself to reach the service.

- **No C builder.** No module exports the `build` of the builder contract ([recipes.md](recipes.md), "The builder"): `c_compiler` and `assemble` export their own calls, which the console chains by hand.
- **No sandboxed builder start.** `recipes.build` refuses each builder but the inputs tree builder with `Builder_Needs_Sandbox`: the root service does not start a builder in its sandbox yet.
- **No signature of a local realisation.** A realisation of the machine is kept, but not signed with the key of the principal.

Layer 3 needs layer 2, and the QUIC client of the object cache inside the system, which is also left ([recipes.md](recipes.md), "State").

### The checks

A host test takes the real files of the project and passes layer 1:

- the tree hash of the folder, from the bytes of its files;
- the evaluation of `project.lex` with that `here()` and the catalog, whole and at `outputs.default`, which is a recipe;
- the load of the evaluation and of `pins.lex` by `projects_core`;
- the recipe of the output, as a record that the test writes, refused by `recipes_core` with `Builder_Needs_Sandbox`: the stop of layer 2, read as a refusal of the service, not as a fault;
- a realisation of that recipe from a cache, trusted only when the key of the policy signed it intact.

The refusals come first: a `pins.lex` with a damaged hash, a project whose `source` is not a hash, a recipe whose builder needs a sandbox, a realisation of the project signed by a key that the policy does not trust and one whose signature is wrong.

## Refused forms

- **The build of the module by the tool, then a realisation written by hand.** It proves the tool, not the system: the realisation must come from a build on the machine.
- **A first project in Odin.** The system has no Odin compiler of its own; a build would run on the host or in the guest builder, which needs layer 2 as well.

## State

Built: the project `src/outside/projects/collatz` (`project.lex`, `pins.lex`, `collatz.c`) and the host test of layer 1 with its refusals.

Left: one identity for the recipe of a project and the recipe of the service, a C builder, a builder started in its sandbox with a signed realisation, the catalog of the system as an output of its build, and layer 3: each an entry of `ROADMAP.md`.
