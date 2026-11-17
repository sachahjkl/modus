# The root ring and the context of a program that the root service starts

The root ring is the border between the root service and each program that asks it for a start, a connection, a revocation or a command of the principals. The context is the border between the root service and each program that it starts. Both carry authority, so a word of either must never become a right that its writer was not given.

## Purpose

- A program sends a command on its root ring only when its role gives it that command. The role is the set of start grants and the terms that the root service gave the program at its start.
- A word of a record becomes a command or a member of an enumeration at one place, which refuses a word that names no member.
- Each refused command gets one error record, written by one known party.
- Each handle that a start gives takes its own context slot, and each value its own index: no role loses a handle or a value in silence because two of its parts have one number. This holds for each starter of the root service, the fixed starters too.
- The whole role of a program is in one place, and a new program of the boot image cannot start with a role that nobody wrote.

## Constraints

- The kind of a record and each word in it come from another program, which can be hostile ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "No ambient access: the other holes to close").
- A disk program has a nickname that its principal chose. A name gives no authority ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "A program from a disk").
- A program is not built for a host test: each decision that a test must break lives in a package.
- A contract package imports no support package. The site reads the table of the context slots and the recorded grants from `src/library/support/system/grants.odin`, and the role of each program from the table `program_roles` of `src/programs/root/roles.odin`.
- A program is no package: the tool, the site and a host test read the source of the table, not the compiled table.

## The chosen form

**The contract** is the package `modus:contract/root_ring`: `Root_Command`, the enumerations of its words, the border procedures, the table of the senders, the table of the writers of the error records, the decision of the dispatch and the name tables. The root service, the console and the programs that send a command agree on it. It holds no kernel operation, so it is a contract and not a part of `system`.

**Three steps for each record**, in this order. The first two are one pure procedure of the contract, `dispatch_decide`, which a host test and the fuzz target `root_ring` call with any word and any role; the root service (`src/programs/root/root_ring.odin`) runs the third only when the decision says `Command`:

1. **The border.** `command_of_word` reads the kind. A word that names no command, and `None`, get `Unsupported` with the word, and nothing runs.
2. **The sender.** `sender_allowed` reads the table `ROOT_COMMAND_SENDERS` with the start grants of the sender, never its name. A program receives a root ring only with a start grant of `ROOT_RING_GRANTS` (Root_Ring, Connect, Principals, Debugger). A refusal gets `No_Grant` before any other check, so a program learns nothing of a command that it cannot send. For `Connect` with the grant Connect and not Root_Ring, the decision also needs the fact that the list of the services of the role names the service; the root service computes it from the role (`role_may_connect`) and passes it.
3. **The command.** One case of a whole switch runs it. The table `ROOT_COMMAND_REFUSAL_WRITERS` of the contract says who writes the error record of a refusal: the dispatch, from the name of `values[0..4]` and the word of `values[4]`, or the procedure of the command, whose values hold a hash, a nickname or a key, or whose cause only it knows.

**The role of a program** is one row of the table `program_roles` (`src/programs/root/roles.odin`): the name of the program, its start grants, and the other terms of its role (the services that it can connect to, the blocks of its private store, the log with Give, the size of its terminal, a start on demand), with the reason of each in the comment above the row. Each program of the boot image has one row, the parts of the system that the root service starts itself too (the grant System_Part), and a program with no grant has a row with no grant. The tool keeps the table whole: before each build, and before the site, it reads the rows with the parser of Odin and refuses a program of the boot image with no row, a row that names no program of the boot image (a disk program, the root service, a name of no module), a program with two rows and a grant that is no start grant (`tools/modustool/program_roles_check.odin`). The role is read one time, at the start (`role_of`), and kept in `Started.role`. Each rule after the start reads `Started.role`: the sender of a command, the grant of a connection, the debug access, a replacement. A disk program has the role of the row of its nickname in the disk grant table: the grant Store at most, so no root ring. What changed: the grants were a switch `grants_of` and the terms a second table beside it, so a reader of a role read two places, and a program that no case named had the zero role in silence.

**The context slots** are one table: the `GRANT_` constants of `src/library/support/system/grants.odin`, for the handles 0 to 13 and the values that the root service and its program agree on. Two roles share a context slot only when no program holds both. Each starter of the root service writes each handle with `system.grant_put`, and each value with `system.value_put`, `system.values_put` (a value of several words, written whole or not at all) or `system.range_mapped_put` (the bit of a fixed range). Each one refuses a place that is taken already and writes nothing there; `grant_put` also refuses the slot of the budget, which the loader writes, and `value_put` the indexes of the seed, of its strength and of the fixed ranges, which `random.values_with_seed` and `range_mapped_put` write. The first refusal is kept in the record that the starter builds (`Context_Refusal`), and the starter reads it once, before the start (`context_refused`): a refused write stops the start with one line that names the slot or the index. This holds for the start of a program by its name, a disk program, a terminal, and the fixed starters: the input service, the compositor, the device services, the TPM service, the font service and `shortage`, each with its own layout (`pci.GRANT_`, `tpm_service.SERVICE_`, `INPUT_GRANT_`, `COMPOSITOR_GRANT_`). A support package that reads a slot names the constant of the table (`terminal.GRANT_RING :: system.GRANT_TERMINAL_RING`). A contract package keeps its number, and the root service checks it against the table with `#assert`, so the build stops when the two differ.

**The `unlock` of the root service** is one record, `Unlock_Run`, with one stage: Stopped, Starting, Running, Stop_Asked. The stage says when `start` takes the name `unlock`, whether a stop counts toward the bound of its restarts, and whether a reader of the records sees a principal that is created.

## The refused forms

- **A cast of the kind, then a `#partial switch`.** A word past the last member became a member that does not exist, and a new command with no case compiled and answered `Bad_Operation`.
- **The role read again from the name at each command.** The nickname of a disk program is a name that the principal chose: a rule by name is a rule that a name can meet. The rule had to rely on a refusal of the nickname at its start.
- **One boolean expression for the sender.** It named each exception in one line, and the reader could not see which grant sends which command.
- **A chain of `command != ...` for the record that the command wrote itself.** A new command that writes its record and is missing from the chain had its record written over.
- **The table of the context slots in `src/library/contract/root_ring`.** The contract packages of the readers would import it, but the site reads the table of `system`, and `system` already names the slots for the support packages.
- **A table of the roles indexed by an enumeration of the programs.** The compiler would then refuse a missing row, but the enumeration would be a second list of the programs beside `module_builds`, which the tool would have to generate or check; the check of the tool against `module_builds` is the one list.
- **A default row for each other program.** It is the form that the table replaced: a new program got the zero role with no line that said so.
- **The grants in the source of each program.** A program would state its own authority; the root service is the one that decides it, and a reader finds every role in one file.
- **A return value of each giver of a page in place of the refusal record.** Each giver (the date page, the glyph caches, the debug image) would need a result, and each caller a check; one record that the starter reads once covers them all, and no write can be forgotten.
- **The dispatch tested only in a machine.** The decision of the border and the sender reads no state; in the program, a host test and a fuzz target cannot call it.

## Subtle points

- **The order of the steps is a rule.** The border comes first, then the sender, then the command. A refusal of the sender never says whether the name exists.
- **A disk program has no root ring.** The test that breaks the design first is a disk program whose nickname is the name of a privileged program (`console`, `unlock`, `remote`), which sends each command: `root_ring_test.odin` tries each start grant outside `ROOT_RING_GRANTS`, alone and together, and each command is refused.
- **The terminal text is the handle 4.** It was the handle 7, which is the call ring of the private store: a role with the grants Terminal and Store would have lost its store. The log service, the one holder of Log_Records, has a window.
- **The error record of `Machine_Seal` with Secure Boot off** is `Refused` with the unit Principals: the general rule of `No_Right` no longer comes before it. `Machine_Passphrase` never reads Secure Boot, and its records did not change.
- **The records of a refused `Replace`** that the state explains (`by` past the entries, a name of no module, a module that replaces itself, a full table, no grant Replace) are the pure procedure `root_ring.replace_refusal`, which a host test calls; a refusal of a signed row is written by `replace` itself.
- **One mapping from a role to its handles.** `root_ring.role_handles` gives the handles of a role, and `system.ROLE_HANDLE_SLOTS` the context slot of each. The start writes a handle by that mapping only, and refuses a handle that the mapping does not give, so the test of the tool that reads each row of `program_roles` checks what the start does.
- **The compositor writes its framebuffer slot once.** It held the framebuffer of the firmware, then the screen pages over it; a checked write takes one handle, so the start chooses first and writes once.
- **The terms of a row hold no comment.** The site shows the terms as the source writes them, on one line; a comment inside them would show as code, so the reader refuses it, and the reason goes above the row.
- **The name before the border.** The dispatch unpacks the name of `values[0..4]` before the decision, as `Connect` needs it for the list of the role. The unpack reads no state and the decision reads only whether the list names it, so a refused record still learns nothing.
- **A nested start never takes the place of a start that runs.** `start_place_take` marks the place that it takes (`Started.reserved`) before any step that can start another program, such as a service that starts on demand at the connection to the private store; each search of a free place skips a marked place, and `release` clears it.

## State

Built: the package `root_ring` with its host tests, the dispatch in three steps with the pure decision `dispatch_decide` and the fuzz target `root_ring` ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)), the role in `Started.role`, the one table `program_roles` with its check before each build and its reader of the site, the table of the context slots with the checked writes of the handles and the values for each starter and their host tests, the stage of `unlock`.

Left: nothing of this design.
