# The root ring and the context of a program that the root service starts

The root ring is the border between the root service and each program that asks it for a start, a connection, a revocation or a command of the principals. The context is the border between the root service and each program that it starts. Both carry authority, so a word of either must never become a right that its writer was not given.

## Purpose

- A program sends a command on its root ring only when its role gives it that command. The role is the set of start grants and the terms that the root service gave the program at its start.
- A word of a record becomes a command or a member of an enumeration at one place, which refuses a word that names no member.
- Each refused command gets one error record, written by one known party.
- Each handle that a start gives takes its own context slot: no role loses a handle in silence because two of its grants have one number.

## Constraints

- The kind of a record and each word in it come from another program, which can be hostile ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "No ambient access: the other holes to close").
- A disk program has a nickname that its principal chose. A name gives no authority ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "A program from a disk").
- A program is not built for a host test: each decision that a test must break lives in a package.
- A contract package imports no support package. The site reads the table of the context slots and the recorded grants from `src/library/support/system/grants.odin`, and the grants of each program from the switch `grants_of` of `src/programs/root/main.odin`.

## The chosen form

**The contract** is the package `modus:contract/root_ring`: `Root_Command`, the enumerations of its words, the border procedures, the table of the senders and the name tables. The root service, the console and the programs that send a command agree on it. It holds no kernel operation, so it is a contract and not a part of `system`.

**Three steps for each record**, in this order (`src/programs/root/root_ring.odin`):

1. **The border.** `command_of_word` reads the kind. A word that names no command, and `None`, get `Unsupported` with the word, and nothing runs.
2. **The sender.** `sender_allowed` reads the table `ROOT_COMMAND_SENDERS` with the start grants of the sender, never its name. A program receives a root ring only with a start grant of `ROOT_RING_GRANTS` (Root_Ring, Connect, Principals, Debugger). A refusal gets `No_Grant` before any other check, so a program learns nothing of a command that it cannot send. For `Connect` with the grant Connect and not Root_Ring, the root service then checks the list of the services of the role.
3. **The command.** One case of a whole switch runs it. The table `ROOT_COMMAND_REFUSAL_WRITERS` says who writes the error record of a refusal: the dispatch, from the name of `values[0..4]` and the word of `values[4]`, or the procedure of the command, whose values hold a hash, a nickname or a key, or whose cause only it knows.

**The role of a program** is read one time, at its start (`role_of` in `src/programs/root/roles.odin`), and kept in `Started.role`. It holds the start grants of `grants_of` and the terms of the rows of `program_role_rows`: the services that it can connect to, the blocks of its private store, the log with Give, the size of its terminal, a start on demand. Each rule after the start reads `Started.role`: the sender of a command, the grant of a connection, the debug access, a replacement. A disk program has the role of the row of its nickname in the disk grant table: the grant Store at most, so no root ring.

**The context slots** are one table: the `GRANT_` constants of `src/library/support/system/grants.odin`, for the handles 0 to 13 and the values that the root service and its program agree on. Two roles share a context slot only when no program holds both. The root service writes each handle with `system.grant_put`, which refuses a slot that is taken already; a start that a taken slot stops writes one line and does not start the program. A support package that reads a slot names the constant of the table (`terminal.GRANT_RING :: system.GRANT_TERMINAL_RING`). A contract package keeps its number, and the root service checks it against the table with `#assert`, so the build stops when the two differ.

**The `unlock` of the root service** is one record, `Unlock_Run`, with one stage: Stopped, Starting, Running, Stop_Asked. The stage says when `start` takes the name `unlock`, whether a stop counts toward the bound of its restarts, and whether a reader of the records sees a principal that is created.

## The refused forms

- **A cast of the kind, then a `#partial switch`.** A word past the last member became a member that does not exist, and a new command with no case compiled and answered `Bad_Operation`.
- **The role read again from the name at each command.** The nickname of a disk program is a name that the principal chose: a rule by name is a rule that a name can meet. The rule had to rely on a refusal of the nickname at its start.
- **One boolean expression for the sender.** It named each exception in one line, and the reader could not see which grant sends which command.
- **A chain of `command != ...` for the record that the command wrote itself.** A new command that writes its record and is missing from the chain had its record written over.
- **The table of the context slots in `src/library/contract/root_ring`.** The contract packages of the readers would import it, but the site reads the table of `system`, and `system` already names the slots for the support packages.
- **The terms of a role and its grants in one table.** The site reads the grants from the switch `grants_of`; the terms are the rows beside it until the reader of the site reads a table.
- **A check of a taken value.** The values of the context are written by the procedures of each page, which take an array; the table names the values, and the check covers the handles, where a lost handle is a lost authority.

## Subtle points

- **The order of the steps is a rule.** The border comes first, then the sender, then the command. A refusal of the sender never says whether the name exists.
- **A disk program has no root ring.** The test that breaks the design first is a disk program whose nickname is the name of a privileged program (`console`, `unlock`, `remote`), which sends each command: `root_ring_test.odin` tries each start grant outside `ROOT_RING_GRANTS`, alone and together, and each command is refused.
- **The terminal text is the handle 4.** It was the handle 7, which is the call ring of the private store: a role with the grants Terminal and Store would have lost its store. The log service, the one holder of Log_Records, has a window.
- **The error record of `Machine_Seal` with Secure Boot off** is `Refused` with the unit Principals: the general rule of `No_Right` no longer comes before it. `Machine_Passphrase` never reads Secure Boot, and its records did not change.
- **The records of a refused `Replace`** that the state explains (`by` past the entries, a name of no module, a module that replaces itself, a full table, no grant Replace) are the pure procedure `root_ring.replace_refusal`, which a host test calls; a refusal of a signed row is written by `replace` itself.
- **One mapping from a role to its handles.** `root_ring.role_handles` gives the handles of a role, and `system.ROLE_HANDLE_SLOTS` the context slot of each. The start writes a handle by that mapping only, and refuses a handle that the mapping does not give, so the test of the tool that reads each case of `grants_of` checks what the start does.
- **A nested start never takes the place of a start that runs.** `start_place_take` marks the place that it takes (`Started.reserved`) before any step that can start another program, such as a service that starts on demand at the connection to the private store; each search of a free place skips a marked place, and `release` clears it.

## State

Built: the package `root_ring` with its host tests, the dispatch in three steps, the role in `Started.role`, the table of the context slots with `grant_put` and its host test, the stage of `unlock`.

Left:

- The fixed starters (the input service, the compositor, the device services, the TPM service, the font service) still write their own context layouts by index; each has one role, so no two grants meet.
- A check of the values of the context.
- The terms of a role and its grants in one table, with the reader of the site.
- A fuzz target of the dispatch of the root ring.
