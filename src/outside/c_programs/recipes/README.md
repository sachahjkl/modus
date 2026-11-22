# The recipes of the C programs

Each file of this folder declares how one C program of others becomes a
module of modus with the thin libc and the adapters of this folder: the
source at its pinned hash, the files of the system that it links, the
patches, the definitions and the flags. The design is in
[`src/md/features/c_compiler.md`](../../../md/features/c_compiler.md),
"The C programs".

A line is `<key>: <value>`. A key that can hold many values is written once
for each value, in order. A line that starts with `#` is a comment.

| Key | Count | Value |
|---|---|---|
| `recipe` | one | The name of the program, as the module names it |
| `version` | one | The version of the source |
| `source` | one | The URL of the archive that the hash names |
| `source_hash` | one | The SHA-256 of the archive, in the SRI form of Nix (`sha256-` and 44 characters of base64) |
| `unpack` | one | `tar.gz` or `zip` |
| `root` | one | The folder of the archive that the paths of `compile` start from |
| `compile` | many | A C file of the source |
| `adapter` | many | A C file of this folder, from `src/outside/c_programs` |
| `manifest` | one | The manifest of the module of the program, from `src/outside/c_programs`: the exports of its entry file |
| `include` | many | A folder of headers of this folder, before each folder of the source |
| `patch` | many | A patch of this folder, applied to the root in the order of the lines |
| `force_include` | many | A header that each C file of the source reads first (`-include`) |
| `define` | many | A definition of the preprocessor, `NAME=VALUE` |
| `flag` | many | A flag of the compiler |
| `test` | many | A check that the module of the program passes on modus |

The flake reads `source`, `source_hash`, `unpack`, `root` and `patch` of
each recipe: it fetches the archive, applies the patches to the root, and
names the folder of the store with the variable `SQLITE_SOURCE`,
`LUA_SOURCE` or `ZSTD_SOURCE`. The hash is written in the recipe only.

The test `recipes_name_pinned_sources_and_files_that_exist` of
`recipes_test.odin` reads each file: it refuses an unknown key, a missing
key, a hash that is not 32 bytes, and a file of this folder that does not
exist. When the variable of a program is set, `real_programs_test.odin`
builds the module of its recipe and runs its tests.
