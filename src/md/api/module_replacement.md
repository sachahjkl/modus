# Who may replace a module

A replacement of an import puts the code of another module into each process that imports the first one, with all the memory and all the handles of each. The drawing module is imported by the compositor, which holds every surface and every key, by the terminal, and by almost every process with a window. So the question "who may replace a module" is the question "who may run code in all of those processes". This file records the answer.

The mechanism of a replacement (the table of the machine, the check of the loader, the module record) is in [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Replacement of an import". The rule of this file is in the same guide, "Who may replace a module".

## The constraints

- **The check of the loader proves the types, not the behaviour.** It compares the description of each export that an import slot uses. A module with the same descriptions and hostile code passes it.
- **The role Replace is held by the console.** Whoever controls the console, or a fault of the console, chooses the code of every importer. Before this design, the root service accepted any pair of modules of the boot image that the console named.
- **The root service imports nothing and starts with no loader for imports.** The check must be code that it compiles in, and must not need a service that it starts later.
- **No new kernel operation, no new grant.** The decision is a policy of the root service, which already holds the table.

## The chosen form: a signed row

A replacement row (`docs/glossary/code.md`, "Replacement row") is a record of the replacement list, a resource of the boot image. It holds the hash of the module that an import names, the hash of the module that the loader gives in its place, the importer scope, and an Ed25519 signature over those three, by the key of a principal.

- **The signed message** is a label (`module replacement signature 1`, on 32 bytes), the old hash, the new hash, and the scope with its principal: 104 bytes. A signature of one row never verifies for another pair, another direction or another scope.
- **The root service accepts a replacement only for a row whose signature verifies under a key that it trusts for the scope of the row.** The console still names the two modules (`replace("calendar", "calendar_fixed")`); the root service then looks for the row of that pair in the replacement list and verifies its signature, before it writes the table of the machine. The console gives no row and no signature: it chooses among the rows that a principal signed.
- **The scope System** is each importer of the machine. Its key is the signing key of the system (`docs/glossary/trusted_boot.md`, "Signing key"): the public key that verified the system description, from the trust record that the boot program wrote.
- **The scope Principal** is the processes of the session of one principal, for a module that only those processes import. Its key is the public signing key of that principal, from the record that the root service holds.
- **A replacement of a module that a service of the system imports needs the signing key of the system**, whatever the scope of its row: the compositor, the terminal (the terminal of a process runs in the session of that process), and every process of principal 0. A key of a principal reaches the code of that principal; it must never reach the code that holds the screen and the keys of every principal.
- **A refusal is one line of the log**, which names the two modules and the reason, and an error record for the asker. The table does not change, so each importer loads the module that its import names.
- **The removal of a replacement needs no row.** It gives back the module that the importer names, which the system description lists.
- **The tool signs the rows when it writes the boot image of a volume**, with the key that signs its system description: the key of `SYSTEM_SIGNING_KEY`, else the test signing key. The test machine signs with the test key, as its boot image is signed. The rows of the build are a table of the tool, by the names of the modules.
- **The format** is the contract package `src/library/contract/replacement_list` (its reader copies nothing: the list is in the pages of the boot image, which no process writes, and the root service checked its hash against the system description). The signature and its check are the private part `src/library/private/root/replacement_signature` of the root service, which the tool and the root service compile in.

## The refused forms

- **A flag "for tests" in the table or in the role.** A flag that a test sets is a flag that a hostile console sets: it proves nothing, and a test of the flag tests a path that a real machine does not take. The test machine takes the real path with the test key, as its boot takes the real check of the description with the test key.
- **A signature over the new hash only** ("the principal vouches for this module"). It lets the console put that module in the place of any module with the same descriptions of the exports that an import slot uses: a signed correction of `calendar` becomes a replacement of each other module whose exports match. The consent is for one pair and one scope, so the signature covers the pair and the scope.
- **The description check as the whole answer.** It proves that a call has the right types, and nothing of what the code does with the memory and the handles of the importer. It stays, as a second check that a signature cannot replace: a row that a principal signed by mistake for a module with another description still fails the load.
- **Trust in the list because the boot image is signed.** It holds today, because the list is a resource of the boot image. It ties each row to a new system description, so a correction of one module needs a new system, and a row of the scope of a principal could never exist: a principal does not sign the system. The signature of a row is the same proof wherever the row comes from.
- **The machine key of the machine passphrase as the key of principal 0.** It is a symmetric key, and the root service holds the key of the tag that it derives: a tag would prove nothing that the root service could not write itself. Principal 0 runs the services of the system, so a replacement for it needs the signing key of the system.
- **A signed row in the ring record.** A row is 136 bytes; a record of the root ring has 56 bytes of values. A memory object for each `replace` adds a path for a form that the console cannot fill: the console holds no private key.

## The subtle points

- **The signature is consent, the load check is compatibility.** The test system signs rows that the loader then refuses: `calendar` by `calendar_changed` (another description) and `calendar` by `agenda` (an import cycle). These rows test the loader. The signing key of a real system signs neither.
- **The check runs at each `replace`, not at the start.** A row that does not verify costs nothing until a principal asks for it, and the refusal then names it. The start of the machine verifies no row.
- **The order of the checks**: the names, a module that replaces itself, a chain of replacements, then the row and its signature. A chain is refused for each pair, so its sentence comes first.
- **One row for one pair and one scope.** The reader refuses a list with two rows of the same pair and scope, so the row that the root service verifies is the only candidate.
- **A process that loads modules with its own loader** (the process `imports`, the process `errors`) chooses its own replacements for its own address space. It reaches only its own memory and handles, so it needs no row. The rule is for the table of the machine, which reaches other processes.
- **The private key of the test system is published.** A test machine says so at its start; a row that the test key signed proves nothing on such a machine, as its system description proves nothing.

## What is built and what is left

- Built: the format of the list and its reader, the signed message, the signature by the tool for the scope System with the key of the volume, the check of the root service at each `replace` under the signing key of the system, the two refusals with their lines, the host tests of the reader and of the check, and the machine test of both refusals.
- Left: **the scope Principal.** A named principal has a signing key, but `unlock` erases the secret key after the unlock, and no tool holds it, so no row of this scope can be signed yet. The reader accepts such a row; the root service never looks for one, so a `replace` finds no row for it. With it comes the check that no service of the system imports the module, which needs the import graph of the boot image in the root service.
- Left: **a list from outside the boot image** (the store `module_files`, the network). The signature of a row already makes it the same proof there; the list then needs the same copy-then-check rule as each file from the disk.
- Left: **a revocation of a row.** An older list signed by the same key still holds its rows; no counter refuses it, as for an older system description.
