# The package names of the copy of the cryptography of Odin

The repository holds a copy of the cryptography of `core:crypto` in `src/library/modus/cryptography` ([`docs/CRYPTOGRAPHY.md`](../../../docs/CRYPTOGRAPHY.md), "3. The layout"). Each package of the copy has the name of its package in the origin after the prefix `modus_`: `modus_sha2`, `modus__subtle`, `modus_aes_ct64`. The folders keep the names of the origin.

## Purpose

Odin refuses one program that imports two packages of one name ("Duplicate declaration of 'package _subtle'"). With the names of the origin, a host program could not import both the copy and `core:crypto`:

- The tool `tools/modustool` imports the copy through the system description, the replacement rows and QUIC. Before the rename, it could not import `core:crypto` and carried its own SipHash in `tools/modustool/build/fact_key.odin`.
- A host program that uses `gui_toolkit` imports `core:crypto/hash` and MD5. It could not also import the QUIC packages of the system. The native viewer of the remote display is such a program.

A name that `core:crypto` does not use removes the clash for each host program at once.

## Constraints

- The copy stays provable: `modustool cryptography-origin` proves that each taken file is its origin with listed changes only ([reuse_list.md](reuse_list.md)). The new name is one more listed change. It is not a change that the check accepts in silence.
- The code of the origin stays unchanged past its package line and its import paths. It names the packages that it imports as the origin does (`_aes.`, `ct64.`, `subtle.`).

## The rule: two names of a package

A package has two names in Odin, and they come from two places:

- **The import name** is the name by which the importing code calls the package. It is the alias of the import, or, with no alias, the last element of the import path: `import "core:crypto/_aes/ct64"` gives `ct64.`, though the files of that folder say `package aes_ct64`.
- **The declared name** is the word of the `package` line. It appears only in the link names of the symbols and in the canonical names of the types. No code writes it.

Only the declared name collides: two packages of one declared name in one program are refused, whatever their import names. So only the declared name changes. The import paths, the aliases and each call site stay as the origin has them.

## The chosen form

- **One prefix, then the name of the origin whole.** The check derives the name of the copy from the name of the origin with one concatenation. A reader sees the origin name in each name. `_chacha20` and `chacha20` stay two names: `modus__chacha20` and `modus_chacha20`. The double `_` is the leading `_` of an internal package of the origin.
- **The folders keep the names of the origin.** The path of a taken file is the path of its origin under another start. The rule `"core:crypto/` to `"modus:cryptography/` stays one rule, and the manifest and the reuse list keep their paths.
- **No import changes for the name.** The check never adds an alias. Each importer in `src/` and `tools/` keeps its import as it was, and its code keeps `sha2.` and `ed25519.`.
- **One table in the check.** `cryptography_packages` in `tools/modustool/checks/cryptography_origin.odin` names each folder of the copy with the package name of its origin. For a taken file, the check finds the row of its folder. It then needs the line `package <name of the origin>` exactly one time, as a whole line, and puts the line of the copy in its place. A comment line that starts with the same words is another line (`argon2id` has one). The check refuses a folder with no row, and a package line that is missing or doubled.
- **A file of the system in a folder of the copy declares the package of the copy.** Each file of one folder must declare one name, and a file in the place of a hardware dispatch, or a test, could keep the name of the origin and bring the clash back. The check reads its package line beside its hash.
- The compatibility layer (`compatibility_crypto`, ...) and the vectors had their own names already. They keep them.

## Refused forms

- **Names of complete words** (`secure_hash_2`). Each name would need its own row of a translation, and the reader of a taken file could not see the origin name.
- **New folder names** (`modus_sha2/`). The last element of a path is the import name, so each import with no alias would need an alias, and each taken file one more change. The paths of the manifest and the reuse list would change too, with no gain: the clash is in the declared name only.
- **An alias with the declared name** (`import aes_ct64 "…/_aes/ct64"`). The code calls the import name, which comes from the path (`ct64.`): such an alias breaks each call where the two names differ.
- **A prefix that drops the leading `_`.** `_chacha20` and `chacha20`, and `_aes` and `aes`, would get one name.
- **Leave the names, and write again in each host program what it needs from `core:crypto`.** That is the SipHash of the tool. Each new host program would pay that cost again, and its code would have no proof of origin.

## Subtle points

- **A package name enters the symbols of Odin.** Odin forms the link name of a procedure of the package scope from the package name, and the canonical name of a type is `<package name>::<type name>`. The symbols and the typeids of the copy change. So the bytes of each module that compiles the copy can change, and with them its hash. No fact type is in the copy, so no fact key changes.
- **The marking of a taken file says it.** The first line says "its package name and its imports changed" (the import paths, as before): the zlib license of Odin asks that an altered source says so.
- **A reader of package lines must skip prose.** `argon2id/argon2id.odin` has the comment line `package argon2id implements ...` before its package line. The check needs the whole line, and the fuzz build reads a package line as an identifier with only blanks or a comment after it.
- **A new package of the copy needs its row first.** `modustool cryptography-take` refuses a file in a folder that `cryptography_packages` does not name.

## State

The packages are renamed, and the check and its host tests accept the new names and refuse each other difference. A host test of the tool imports `core:crypto/sha2` and the copy of `sha2` in one package, and both give the SHA-256 of FIPS 180-2. `tools/modustool/build/fact_key.odin` now calls `core:crypto/siphash` directly.
