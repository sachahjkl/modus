# Declarations

A principal describes a system, a session or a project, with the console of that project, as one lazy value of Lex, the language of the console, in the manner of Nix. The evaluation of that value has no effect: it gives a typed record, the plan. An explicit command applies the plan, and the root service writes it as one applied plan, which a rollback can select again. The root service and the services never read the text of a declaration.

The terms Plan, Applied plan, Declaration, Catalog declaration, Declaration input, Pin, Source module, Release pointer, Project, Plans service, Projects service, Recipes service and Declaration reference are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); Lex, Console of a project, Evaluation budget, Evaluation stack bound, List, Comment of Lex, Evaluation mode, Thunk, Record literal, Named argument and Anonymous function are in [`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md). The recipes that a plan names, the cache and the substitution policy are in [recipes.md](recipes.md).

## Purpose

A principal does each day the same few tasks: start the system that it chose, go back to the system before, work in a project with the commands of its modules, build an output of a project. Today each one is a sequence of console commands that the principal keeps in memory. A declaration states the result once, with the hashes that it resolves to, and one command applies it. A second machine with the same declaration and the same pins gets the same hashes.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system": no `PATH`, no shared configuration folder, no installer.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": a module is the BLAKE3 hash of its bytes, a system is a list of hashes, an upgrade writes a new list and a rollback selects an old one, both atomic.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM": the image that the publisher of the system signed stays the base, and each choice of principal 0 that changes the start is measured.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": no process parses the text of another. [start_policy.md](start_policy.md) refuses "a text configuration file with a parser in the root service" and scripts for the same reason.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": a new grant comes from a principal, as a record that it sees and can revoke.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": one language, and a plain expression for each frequent task.

## What the properties already give

The design adds little mechanism, because most of it exists:

- The identity of a module is the hash of its bytes, and an import names a hash.
- A system is a list of hashes: the system description, with an upgrade and a rollback.
- The disk grant table binds a nickname to a hash, as a profile of Nix binds a name to a store path ([processes_from_a_disk.md](processes_from_a_disk.md)).
- The start policy reads a start list of typed rows ([start_policy.md](start_policy.md)), and the wiring list of a start wires the record outputs ([module_outputs.md](module_outputs.md)).
- Each change of an object of a store is a version ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes").
- The roadmap entry of a cache of modules on the network is the substitution of Nix ([recipes.md](recipes.md)).

What is missing is one value that names all of these at once, a way to compute it, and one atomic step that applies it.

## The chosen form

### Text stops at the evaluation

Text exists only between the principal and Lex. Lex has two readers, with one parser and one evaluator from one library package (property 10):

- **The console** reads the line that the principal types, as today, and evaluates it in mode `console`.
- **The evaluation process** evaluates in mode `declaration`. It reads the text of a declaration object. The service of the declarations that needs a value starts it as a sandboxed child for each evaluation ("The services of the declarations"): it holds a connection that reads only the trees of the declarations that the evaluation names, and nothing else. No network, no store that it can write, no root ring.

The service sends the evaluation process typed values only: a declaration reference, which is the hash of a declaration, the list of the field names to force, and the typed records that a `with` composed with it. The evaluation process sends back typed values only: a plan, a table of recipes, the console of a project, or an error record with its place. No line of the principal crosses to it, and no text comes back. The text of a declaration is a document that a principal wrote, as the source of a module is: a reader of its language reads it, as a compiler reads a source. No process sends text to another process for it to parse.

The root service and every service read the plan, a typed record, through one border of a contract package. None of them reads the text of a declaration.

### A declaration is an object

A declaration is a tree in a store, with its hash, as a module is. Its root holds one text object in Lex, whose name has the extension `.lex`, and whose value is one record: `project.lex` for a project. `pins.lex`, the pins of a project beside it, is no declaration ("Where the pins live"). A tree whose root holds no other entry `.lex`, or two, is no declaration: `declaration(hash)` refuses it with an error record that names the tree. A project keeps its declaration in its source tree; a principal keeps the declaration of its session in a store of its own.

The value of a declaration is lazy: the evaluator reads it in mode `declaration` ("One parser, one lazy evaluator, two modes").

### The plan

The plan is the typed record that an evaluation gives and the root service applies. It holds hashes and typed rows, never a name to resolve:

- the hashes of the modules of the plan, each with the recipe that made it when one did;
- the rows of a start list, in the format of `start_list` ([start_policy.md](start_policy.md)), and the hash of a start policy;
- the wirings of the record outputs, in the format of the wiring list of `Start` ([module_outputs.md](module_outputs.md));
- the rows of the disk grant table: a nickname, a hash and its grants;
- the holder of each role, by its hash, or a chain of an interposed holder and the holder below it ([roles_and_contracts.md](roles_and_contracts.md), "The plan says who holds each role");
- the settings, each a member of `Setting` with its value;
- the substitution policy, `Substitution` ([recipes.md](recipes.md), "The substitution policy");
- the pins of each declaration input, with its publisher;
- the provenance of each realisation that it uses: the source and the signer ([recipes.md](recipes.md)).

A plan names each object by its hash, so it is complete in itself: the root service never asks what a name means.

### Apply, the difference and the rollback

`plan { … }` is the only form of Lex that describes an effect, and it has no effect by itself: it is a value. An explicit command of the service `plans` applies it ("The services of the declarations"):

1. `plans.apply(p)` forces the plan in an evaluation process, and the service `plans` asks the root service for the difference between the plan and the current applied plan of the principal: the grants that it adds and removes, the wirings, the rows of the start list, the start policy. The root service computes it from its own copy of the current applied plan, not from the evaluation, so neither the evaluation nor `plans` can hide a grant. `plans.difference(p)` gives that difference and applies nothing.
2. The root service gives the difference to the trusted display, which shows it on the trusted path as one screen, grouped by kind, and the principal accepts it whole with the act of a grant dialog ([powerbox.md](powerbox.md), "The relation to the other paths"). While a wide grant holds in the session, a difference that adds a grant needs the proof of the principal ([wide_grants.md](wide_grants.md), "Acts that still ask"). A difference with no new grant is still shown. What changed: the console drew the difference and took the key, and a console that the principal does not watch, or that an agent drives, could then accept it.
3. The service `plans` sends the root ring command `Apply` with the hash of the plan and the hash of the current applied plan that the difference read. The root service refuses the command when the current applied plan changed since: the principal accepted another difference.
4. The root service checks the plan at its border, checks that the store `module_files` holds each hash that the plan names and each import of each module, writes the plan as applied plan N + 1 in the store `applied_plans` of the principal, then writes the hash of applied plan N + 1 in the row "current plan" of the disk grant table of the principal. That last write is the commit: before it, applied plan N is current; after it, N + 1 is.

`plans.rollback()` shows the difference back to the applied plan before the current one on the trusted display, as an apply does, and the principal accepts it whole. Only then does it send `Rollback`, which writes the hash of that applied plan into the row "current plan". It writes no new plan. `plans.rollback(n)` selects the applied plan n. A later `plans.apply` writes the number after the highest one, so a rollback never loses a plan.

Why a rollback asks too. A rollback restores the grants of an older plan and, for principal 0, its role holders: it can widen a grant or swap the holder of a role as much as an apply can (property 23). A rollback that a console accepts alone would let an agent take back a grant that the principal removed. Each rollback shows its difference, even one that only narrows: one path, and one meaning of the result of `rollback`. Refused: a rollback with no dialog when it narrows only; it gives two paths and a result that is a ticket in one case and a generation in the other. A rollback to a plan equal to the current one is refused with `No_Change`: the dialog would have nothing to show.

What changes when:

- The plan changes no process that runs. A grant of a disk process takes effect at its next start, as `allow` does today.
- The start list and the start policy of the plan of principal 0 take effect at the next start of the machine, as the choice of a start policy does today.
- The console of a project of the plan takes effect at the next `projects.enter`.

So the authority is in `plans.apply`, not in the evaluation. A foreign plan cannot take a grant in silence: its grants are in the difference that the principal accepts.

### The apply as built

Until the root service holds the applied plans, the service `plans` keeps them, and the four steps above run in it, in two calls:

1. `plans.apply(name, plan, expected)` computes the difference against its own copy of the current plan of the principal, refuses an `expected` hash that is not the hash of that plan, and shows the difference with `plan_diff_ask` of the trusted display. It keeps the plan as the pending apply of the principal ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Pending apply"), and gives the serial of the dialog as a ticket. It commits nothing.
2. `plans.apply_poll(ticket)` reads the decision with `plan_diff_poll`. While the dialog shows, it gives 0. An accepted difference commits; a refused one, a dialog that the display no longer knows, and a display that does not answer drop the pending apply and change nothing else.

The rollback takes the same two calls. `plans.rollback()` computes the difference from the current plan to the generation that it selects, shows it with `plan_diff_ask` under the name "rollback of the plan", keeps it as the pending rollback of the principal ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Pending rollback"), and gives a ticket. `plans.rollback_poll(ticket)` commits it only when the principal accepted, and only if the current plan is still the one that the dialog read (`Stale_Current_Plan`). The roles of principal 0 go to the root service at that commit, never before. A principal has one dialog at a time: an apply and a rollback refuse each other with `Apply_Pending` while one shows.

`plans` reaches the trusted display by the role name `display`, never by the name of a module: the root service connects it to the holder of Display in force, and `plans` takes the description of its exports from the entry of the boot image with the hash that the connection gives, checked against the bytes. A holder with no `plan_diff_ask` and `plan_diff_poll` shows no difference, and each apply and rollback is refused. The exports that read a generation (`current_generation`, `apply_generation`, `rollback_generation`) take no principal: they read the principal of the caller, as each other export does.

The commit writes two objects of the private store of `plans`, each in one write: the object of the applied plan `plan_<principal>_<n>` (its record and its rows), then the current object `plan_<principal>_current` (the current and the highest number, and the hash of the current plan). The write of the current object is the commit, as the write of the row "current plan" is in the chosen form. A rollback writes the current object only. The service reads the objects of a principal back at its first use after a start, and checks each one whole: its head, each row at the border of a plan, the hash of the plan against its record, and the hash of the current plan. One damaged object refuses the whole history with `Store_Damaged`, so no step acts on a part of a history.

The roles of the plan of principal 0 go to the root service before the commit, with the root ring command `Plan_Roles` (`modus:contract/root_ring`; `modus:contract/root_delegation`, `plan_roles.odin`). The root service lends `plans` one roles page; `plans` writes there the whole set of the role overrides of the generation (`Plan_Roles_Set`: for each role, the hash of the module that callers reach, the outermost of its chain of interposition), with the serial of the set in force that it read. The root service copies the set once, checks it whole at its border (`plan_roles_set_check`: principal 0 only, the serial in force, no role twice, no role that the root service starts in its own way, no hash of zero bytes), resolves each hash to a module of the boot image and checks the exports and the record streams of its contract, then replaces its overrides in one step (`role_policy.holder_overrides_replace`). A set that one override refuses changes nothing, and `plans` then commits nothing: the apply is refused with `Roles_Refused`. A rollback sends the set of the generation that it goes back to, with the step `Rollback`, before it writes the current object. When the store refuses the current object after the root service took a set, `plans` sends the set of the generation in force again, so the root service and the store name one generation. A process that holds a role keeps running when its role changes: the next start and the next connection reach the new holder.

Why the two stay in step. A set whose answer did not come, or that names a serial that is no longer in force (`Stale_Serial`), leaves `plans` unsure of what the root service holds. `plans` then reads the serial and the generation in force with the step `Page`, gives the root service the generation that its store holds as current with the step `Rollback` when the two differ, and sends the set once more. A compensation that the root service refuses leaves the port unsynchronized, with one line (`Plan_Roles_Unreconciled`): the next set reconciles first. At its start, `plans` reads the generation of the root service and reconciles at once, so a `plans` that stopped after the root service took a set and before the store committed it leaves no second generation.

Why the set and not the difference. The root service holds the overrides of the roles, not the history of the plans: a whole set replaces a whole set, and a set that comes late names a serial that is no longer in force, so it is refused with `Stale_Serial` and never undoes a later set. The plan of a named principal names no role of the machine: `plans` sends no set for it.

Why two calls, and not one that waits. An export of a service runs in the loop of the service: an export that waited for the principal would hold every other caller of `plans` for the time of a decision. The ticket also lets a caller that stopped leave no trace: the next `plans.apply` polls the old dialog and drops its pending apply when the dialog closed.

Why every difference, and not only one that adds a grant. A difference with no new grant is still shown (step 2 above). `plans.apply` refuses a plan with no change with `No_Change`: the dialog has nothing to show, and the principal has nothing to accept.

Why the whole difference or nothing. The dialog shows each change that a difference holds, each item of at most 48 bytes ([powerbox.md](powerbox.md), "The relation to the other paths"). Past the lines of its view, the body scrolls, and its accept counts only once the view showed the last line: a principal never accepts a line that it did not see. An item past 48 bytes is refused with `Display_Refused` before any dialog. An item is the kind and the name of its entry: `role`, `start`, `disk` or `store`, the name, and for a store its rights; a changed entry that adds or widens a grant, or changes a module, is on the side of the additions with `changed`, and one that only narrows is on the side of the removals.

Why a plan and its difference have no count. A plan of a principal grows with what the principal installs: a fixed count of entries refuses a real plan, and a fixed count of items refuses its first apply. So a plan (`Plan_Spec`) holds its entries and their order in memory of its owner, and only `PLAN_ENTRY_COUNT_LIMIT` (2^31 minus 1, the bound of an index) bounds it. The core of `plans` takes a block of its memory port for each plan that it keeps, for the pending plan, for the items of a difference and for its two lists, each of the size of its plan. The service gives blocks of the powers of two from one page, out of an arena of its budget (`plan_memory.odin`); a budget that pays no more is `No_Memory`, with nothing changed.

`plan_validate` checks a plan of n entries in n log n: it sorts the order by identity and by module, finds the repeats as neighbours, and walks each chain of interposition once, with a mark on each holder whose chain ends. `plan_hash` is a chain over the entries in their canonical order, each link the hash of the link before and of one entry, so it hashes a plan of any count in the memory of one entry. A generation object has the size of its plan: the private store reads its size first, and the storage port moves an object past 16 KiB (`storage_port.PIECE_BYTES`) in ranges and one commit. `plans` lends each side of a difference to the trusted display in a memory object (`plan_diff_ask(name, added, removed)`, two `Bytes`); the display copies it once into an arena of its own and gives the dialog its items there.

Refused forms:

- **The decision in an answer record that the caller gives.** The caller is the process that wants the plan applied. `plans` reads the decision from the trusted display itself.
- **A second pending apply that replaces the first.** The dialog would show one plan while another commits. A second `plans.apply` while the dialog shows is refused with `Apply_Pending`.
- **A commit of the dropped pending apply when its dialog closed with Accept and no poll.** The caller that asked is gone, and a later caller did not see that difference. It is dropped, uncommitted.

What is left of the chosen form: the root service does not hold the applied plans or compute the difference yet, and no row of a disk grant table names the current plan. The applied plans change the role holders of the machine (`Plan_Roles`), and no start list yet.

### The plan of principal 0 at the start

The role holders that principal 0 applied hold from the first start of the machine, not only after the next `plans.apply`. The root service never reads a store: `plans` reads its own private store, and the root service waits for it.

The order of one start (`src/modules/system/root/plan_at_start.odin`, `role_policy/plan_at_start.odin`):

1. The root service reads the choice of principal 0 (`start_policy_choice.odin`). The storage service runs from that read on a machine with a data disk.
2. It starts the holder of Plans, which connects to its private store, as at a first connection.
3. `plans` asks for the roles page (`Page`), and reconciles at once: when the current generation of principal 0 in its store is not the generation in force (0, the roles of the image, at each start), it sends the set of that generation with `Rollback`. The root service checks the set as for any rollback, and takes it whole or refuses it whole.
4. `plans` sends `Plan_Roles` with the step `Loaded` and its outcome (`Plan_Roles_Load_Outcome`): `No_Plan`, `Applied`, `Plan_Refused`, `Store_Unread` or `Core_Unread`. The root service writes one line for it.
5. The root service starts the start policy with the roles in force. Each start that the start policy asks for reaches the holder of the plan, the rows that the root service starts by a procedure of its own too: the boot pass of the row `settings` starts the holder of Settings in force, through the decision of one process `settings` at a time ([settings_window.md](settings_window.md), "Subtle points"), and that holder alone gets the context value `VALUE_PASS` of the pass.

The limit of a holder that a plan gives. The root service gives the grants of a start by the row of the module name in its start grant sets, not by the role. So a holder of Settings that a plan names gets the value of the pass and none of the grants of the row `settings`: no settings page with Write, no Serve, no Store. Such a holder runs, and cannot do the work of the role until the grants of a role follow its holder (`ROADMAP.md`).

The wait ends at `Loaded`, at the stop of the holder of Plans, or at the hang bound, whichever comes first; each end has its line, and the start policy starts. With no wait at all, the roles of the image hold:

- **A rescue.** The rescue start policy runs with the roles of the image: a plan can be what broke the start, as a chosen start policy can.
- **No data disk.** No store holds a plan, so a machine with no disk starts with no delay.
- **No holder of Plans or of Storage in the boot image.**
- **A holder of Plans that does not start.**

Why a stored plan that the image refuses never stops the start. A newer boot image can lack a module that the plan names (`Not_In_Image`), or hold one that no longer fills the contract of its role (`Contract_Not_Filled`). The root service refuses the set whole, so it keeps the roles of the image, and the start goes on. `plans` keeps that refusal as a known difference (`roles_stored_refusal`), with one line (`Plan_Roles_Image_Defaults`), and marks the port synchronized. A refusal of the content comes again on each send of the same set, so a retry would refuse each later `plans.apply` for ever: the next apply or rollback is sent as usual, and a success ends the difference. When the root service holds the roles of another generation at that moment, `plans` gives it the set of the image (generation 0, no override), never a part of either plan. Only `Stale_Serial` is a refusal of the order of the sets, and it is tried again (`plan_roles_refusal_of_content`).

Why a damaged store keeps the image. A current object or a generation object that does not pass its border refuses the whole history with `Store_Damaged` (see "The apply as built"). `plans` sends no set, says `Store_Unread`, and the root service starts with the roles of the image.

Why the holder of Plans says Loaded at each start. It does not know whether the root service waits. Out of the wait at the start, the root service answers `Loaded` and changes nothing.

Why a late answer of `Page` is closed. Each answer of `Page` gives a new handle of the roles page through the root ring. A `Page` whose answer came after its bound keeps its tag (`Late_Page_Tags`); a later wait that receives that answer closes its handle, so no handle stays for each bound that passed.

Refused forms:

- **The root service reads `plan_<0>_current` itself.** The root service never calls the storage service for a delegated service (`src/md/api/root_service_split.md`); the parsing of a plan in the root would be one more border in the most trusted process.
- **A start policy that waits for the plan.** The root service starts the start policy; a start policy from the disk is foreign code, and the roles of the start must hold before its first `Start`.
- **A wait with no bound.** A holder of Plans that hangs would hold the start of the machine.

The subtle point of the measure. The role holders are modules of the signed boot image, so the image stays the base (property 17). The choice of the holders by principal 0 changes the start, and no extend of PCR 12 records it yet: a plan with no start policy of its own changes no measure, as the list of the measures says below. The measure of the set of roles at the start is planned work (`ROADMAP.md`).

### The trusted display of a plan

`plans` shows each difference on the trusted display and reads the decision there (`compositor.plan_diff_ask`, `compositor.plan_diff_poll`). `plans` acts for nobody: its start grant set has no `Acts_For_Principal`, so it never sees what a service keeps for all the callers of a principal. The display serves those two exports to the holder of the role Plans, and to a caller that acts for its principal; each other caller gets `No_Grant` with its error record.

The identity is the one that the root service writes, with no new source of trust. The amount of a grant (`isolated.CALLER_AMOUNT_MASK`) has the meaning that its service gives it, as the log service packs its scope there. On a connection to the holder of Display, the amount `plans_recipes.DISPLAY_AMOUNT_PLANS_HOLDER` says that the caller holds the role Plans now (`role_policy.display_caller_amount`). The display reads it with `plans_recipes.plan_display_caller_allowed`.

A holder of Display serves its exports with `system.service_run`, which applies each `Grant` of its service ring before the next call, so a grant that the root service wrote again holds from the next call on. When the grant of the asker of an open dialog no longer names the holder of Plans, or its connection ends, the compositor refuses the dialog and closes it (`Plan_Difference_Asker_Lost`): the principal never answers for a module that lost the role.

The trust follows the role, not the module name. After each change of the roles (`Plan_Roles`), the root service writes again the grant of each connection whose amount changed: a module that lost the role Plans loses the amount at once, and the connections of a holder of Display that moved lose it too. The root service compares the whole grant of each connection before and after the change: the amount of a connection to the holder of Storage changes too when that role moves. Each service ring must have room for the grants that change on it (`role_policy.grants_room_short`); else the change is undone whole (`role_policy.holder_overrides_restore`), the set is refused with `Grants_Busy`, and nothing changes. `plans` sends the same set again after a pause of 10 ms, at most `plans_core.ROLES_BUSY_RESEND_BOUND` (8) times. Past the bound, the apply or the rollback is refused with `Roles_Refused`, nothing commits, and `plans` writes the line `Plan_Roles_Busy`; the principal applies again.

Refused forms:

- **The grant `Acts_For_Principal` for `plans`.** One line, and `plans` would read what every service keeps for the principal, a grant much wider than the dialog.
- **The display compares the caller name with `plans`.** The holder of a role can move; a name test would trust a module that lost the role, and refuse the one that took it.
- **A new bit of the grant.** The 64 bits of the grant are all in use; the amount is the field that each service gives its own meaning.

### The plan of principal 0

The plan of principal 0 is the system plan. It adds to the signed image and never replaces it (property 17): its modules are disk processes and a start policy from the disk, its start list is the list of that start policy, and the boot image stays the one that the publisher of the system signed.

- The row "current plan" of principal 0 is in its disk grant table, under the tag of the machine key, as the choice of a start policy is ([start_policy.md](start_policy.md), "A start policy from the disk").
- The root service reads it at step 4 of each start, before the start policy.
- The measure into PCR 12 stays one extend for each start policy. For a start policy of a system plan, its second hash is the hash of the plan, in place of the 32 zero bytes of a start policy from the disk with no list. So an attestation sees which plan ran, with no third extend.
- `plans.apply` of principal 0 is refused where the machine key does not open with no passphrase, for the reason of the choice of a start policy: the table cannot be read before the start policy.

### Lex: the console with eight forms of grammar and the names of the evaluation

The language of a declaration is Lex, the language of the console ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "Lex"), with no second language. The declarations add eight forms to its grammar:

1. **`let`.** `let a = 1, b = a + 1 in { x = a, y = b }`.
2. **The record literal.** `{ field = value, … }`. It takes the type of the parameter or the field that receives it ("A record literal is typed by its use").
3. **The named argument.** `recipes.build(kernel, substitution = { mode = .Verify })`. A named argument follows the rule of the record literal: the parameters of the call are the fields of a record.
4. **The literals that a use types.** A list `[a, b]`, a member of an enum `.Verify`, and a hash `blake3:…`. A list and a member take their type from their receiver, as a record literal does.
5. **The anonymous function.** `(name) => odin.module(name)`. A function is a value: it can be a field, an argument and a result.
6. **`with`.** `a with b` composes two records: the result is `a`, with each field of `b` in place of the field of the same name ("Composition").
7. **The call on a record literal.** `plan { … }` is `plan({ … })`. `plan` and `project` are functions of the catalog declaration that take one record literal.
8. **The placeholder `_` of `|>`.** `compile(src, t) |> bytes(t, 0, _) |> assemble(f)`: the value on the left takes the place of `_`, one whole argument of the call on the right ([pipe_operator.md](pipe_operator.md), "The placeholder `_`").

The other forms of the declarations are names of functions and values, with no form of grammar of their own. Both modes know them; in mode `console`, a name that gives a value of a declaration gives a declaration reference:

- **A reference by hash.** `module(blake3:…)` is one exact module. `declaration(blake3:…)` is one exact declaration. A name of a catalog declaration, `catalog.odin`, is a field of its record; the plan records the hash that it gave.
- **`recipe(builder, arguments)`.** A lazy value whose identity is its recipe hash. Forcing it does not build it: a build is a command ([recipes.md](recipes.md)).
- **`plan { … }`, `project { … }`.** The record of a plan, which `plans.apply` takes; of a project, with its console ("The console of a project").
- **The values of the declaration inputs.** `catalog`, `inputs`, `keys` (the table of the publisher keys that the principal trusts), `follow(publisher, name)` and `here()` ("Declaration inputs, pins and release pointers", "Sources and the identity of a source").
- **`map(list, function)`.** It gives a list with the function applied to each item.

### One parser, one lazy evaluator, two modes

One grammar and one parser library read the line of the console and the text of a declaration. One lazy evaluator takes the tree that the parser gives. Each field of a record and each binding of a `let` is a thunk, which the evaluator forces when a value needs it, and at most once.

The evaluator runs in one of two evaluation modes, a closed set:

- **Mode `declaration`** runs in the evaluation process, in its sandbox. An export with an effect is refused at its border: the evaluator does not call it, and gives an error record that names the export, the declaration, its line and column, and the chain of fields that it forced. The evaluator forces nothing beyond the fields that the console asked for, so `kernel.tools` forces the recipe of the tools and nothing of the image.
- **Mode `console`** runs in the console. Exports with an effect are allowed. Each line is forced whole, each binding of its `let` too, so no effect is skipped because its value went unused.

The exports with an effect are each command of the services `plans`, `projects` and `recipes`, the command `exit` of the console, and each export of a module or of another service: the evaluator cannot know that an export of a module has no effect. The names of the evaluation (`module`, `declaration`, `recipe`, `catalog`, `inputs`, `keys`, `follow`, `here`, `map`, `plan`, `project`) have none. A Stream is a wiring, an effect: mode `declaration` refuses it, and mode `console` holds it while its line runs, as today.

**Why one meaning everywhere.** An export forces its arguments from the left to the right before it is called. So the effects run in the order of the data: `assemble(bytes(t, 0, compile(src, t)), f)` compiles, then reads, then assembles, as the eager console of today does. The one difference that laziness can make is a value that nothing uses, whose effect then never runs. That cannot happen in mode `console`, because the line is forced whole. So a line means the same thing in both modes; mode `declaration` only refuses the effects.

**What is shared.** The parser, the type rules, the literals, `with`, the functions, `where` and the evaluation budget are one code for both modes. A field that names another field of its record, and a `let` that names itself or a later binding, are accepted in both. A thunk that its own computation forces again is a cycle: the evaluation stops at once with the record `Cycle` at the name that closes it. A work that has no cycle and no end, which functions can make, stops at the budget.

**The tests.** One evaluator has no second semantics to compare with. The tests check two claims:

- Mode `declaration` refuses each effect: each command with an effect, an export of a module, an export of a service, a Stream. Each case checks the error record, and that nothing changed: no call reached the export, no store was written.
- Mode `console` runs each effect of a line once, in the order of its data: an export whose result no other part uses, an export in a `let` binding that the result does not name, and an export whose result two parts use, which runs once.

**The cost.** The eager evaluator of the console was replaced by the shared evaluator in mode `console`, layer 2 of the build order ("The evaluator package"). Each line runs its effects in the same order as before.

**A value of a declaration at the console.** The console evaluates no text of a declaration ("An evaluation in the console process" in the refused forms). `declaration(here())`, `catalog` and `kernel.tools` give a declaration reference at the console: the hash of the declaration, the chain of the field names, and the records that a `with` composed with it. Each part is a typed value. Forcing the reference in mode `console` gives the reference itself. A command that needs the value, such as `recipes.build` or `plans.apply`, gives the reference to its service, which sends it to an evaluation process that forces the fields in mode `declaration` and gives back typed values.

**The limits of the console on lazy values.** Mode `console` forces each line whole, so a variable keeps a value, never a thunk. The thunks of a declaration live in the evaluation process, which ends after its evaluation. So:

- A declaration reference takes one of the 16 variables, whatever the size of its declaration.
- A text field of a forced value keeps the bound of a text of a variable (96 bytes), and a table the bound of a table (`TABLE_KEPT`).
- No Stream reaches a variable through a declaration: mode `declaration` refuses a Stream.

The cost is a second evaluation of the same reference on a later line. The evaluation is pure, so it gives the same value ("Open questions").

### The parser package

The parser of Lex is `src/library/modus/lex_parser`. It reads a text and gives a syntax tree ([`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md), "Syntax tree"); it evaluates nothing.

**What it took from the console.** The console read and ran a line in one pass. `expression`, `term`, `factor` and `call` of `language.odin` read a token and computed its value at once, `condition_read` of `tables.odin` read the field and the operator of a condition, and `fact_name_read` of `facts.odin` the name of a fact type. A call ran when the parser reached its `)`, so the calls before a fault of the text ran before the parser found the fault. The parser package now holds that grammar, the arguments by their form, the head of a condition and the fact name. The console keeps:

- the evaluation of each node, which the evaluator package now holds ("The evaluator package"), and what the evaluator asks of the console: the variables and the commands, the checks of a call, the checks of a condition against the record of its table, the fact names of the image;
- the sentence of each refusal;
- `pipe_nested_form` and the checks of `|>` before the run, which read the line before its nested form ([pipe_operator.md](pipe_operator.md));
- the scanner of `console_language`, which the colors share, and `console_condition`, which the tool shares.

**The tree.** Each node has a kind, its place (line, column from 1, and offset), its own bytes, and its children: the arguments of a call, the two operands of an operator, the value of a condition. The caller gives the memory; the package keeps no state and calls no allocator.

**A refusal is a node in its place.** The parse stops at the first fault of the text, and the fault is a node where the one pass met it: an argument, an operand, or the root with the part before it as its child. The tree also holds it as a record: the member, the place and a value. The console evaluates the tree from the left, so the calls before the fault run, then the line fails with the sentence of the one pass ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "Errors": "A call that runs before the error keeps its effect"). The parse writes no text.

**The form of an argument comes from the caller.** The parser asks a lookup of the caller for the form of each argument of a call: an expression, a condition, a fact name, or the names of fields of `columns(t, a, b)`, which take the commas that would end the argument, as the one pass read it from the command. So inside `where`, `=` is the operator of a condition. The package keeps no table of the commands, because the console changes its table with each module that it loads.

**A condition keeps both readings.** The kind of its field is known only when the evaluation has the table. The node keeps the head (the field, the operator, the place of the value) or its refusal, the value as an expression, and whether the first token of the value ends the argument. A status field reads that first token as the name of a member; another field evaluates the expression.

**The bounds.** A text has at most the bytes of the longest line that the console runs, 200. Each level of a nesting takes one byte at least, so this bound is also the bound of the depth of the parser, and of its nodes: one for each byte, and the refusal. A text of a declaration is longer: its bounds come with mode `declaration`.

**Why in `src/library/modus`.** A support package has two owners or more ([../infrastructure/repository_layout.md](../infrastructure/repository_layout.md), "The rules of the imports"). The parser moved from `src/library/internal/console` to `src/library/modus` with the sandboxed evaluation module `src/modules/system/declaration_eval`, together with `console_language`, `console_condition` and `lex_evaluator`.

Refused forms:

- **A parse of the whole line before the first call.** A fault of the text then fails a line before any call runs, and this changes what a line does today. If a later layer makes this change, it is a change that a reader sees, with its own changelog fragment.
- **The parser in a support package now.** It has one owner, and the tool refuses it.
- **Sentences made by the parser.** The sentence of a condition names the fields of the record of the table, which only the evaluation knows.
- **Each argument read as an expression, with `=` as an operator.** `=` then has two meanings in one grammar, and the evaluator must tell a field from a variable. The form of the parameter says it with no rule.

Subtle points:

- **A load and a call in one line.** The parser reads the forms before any call, so a command that a call of the same line loads is read with the forms of before. Only built-in commands have a form other than an expression, so the forms are the same.
- **A name that no command has.** The parser reads its arguments as expressions; the evaluation refuses the name before it reaches them, as the one pass did.
- **A status reads one token.** When the value is a longer expression, the parser read more than the one pass. The node says that the first token does not end the argument, and the evaluation fails with `"," or ")" is missing`, the sentence of the one pass.
- **A zero byte** ends the text for the parser, as it did for the one pass. The line editor types no such byte.

### The evaluator package

The evaluator of Lex is `src/library/modus/lex_evaluator`, shared by the console and the sandboxed evaluation module `src/modules/system/declaration_eval`. It evaluates a syntax tree in an evaluation mode. It holds the values of Lex (`Value` and its `Kind`), the thunks, the order of the forcing, the operators with their refusals, the evaluation budget and the mode. An evaluation host ([`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md), "Evaluation host") gives it what only the host knows: the value of a name, the command of a call and its effect, the run of a call, a condition, a fact name, and the memory of a joined text. The console is the host in mode `console`; the evaluation process is the host in mode `declaration`.

**A thunk for each node.** The thunks are an array indexed by the nodes of the tree, so an evaluation needs no allocator. A thunk is unforced, then forced with its value. A second force of a forced thunk gives the kept value: it costs no step and runs no effect again. Today no node has two readers, so a second force comes only from the host; `let` and `with` of layer 3 give a node two readers.

**The order of the forcing.** A call asks the host for its command first, so a name that no command has fails before its arguments, as before. Then it forces its arguments from the left, then the host runs it. An operator forces its left operand, then its right one. A refusal of the text forces the part before it, then stops. So the effects run in the order of the data, which is the order of the line with calls in calls.

**Mode `console` forces the whole line.** The evaluator forces the root of the tree, and each node of a line is reached from the root through the force of its parent. The value of a status condition is one name, which has no effect, and the console reads it as a member without a force. A variable takes the value of the root.

**Mode `declaration` refuses an effect at its border.** When a call reaches a command that has an effect, the evaluator stops with the record `Effect_Refused`, which names the command and its place, before it forces the arguments and before any run. Today every command of the console has an effect: the names of the evaluation, which have none, come with layer 6.

**The budget.** A step is one thunk computed; a force of a forced thunk and the work of the host are no steps. Past the budget the evaluation stops with the record `Budget_Exceeded` at the place of the node that needed the step. The constant `EVALUATION_BUDGET_STEPS` is 2^20 until the measure of layer 6 sets it ("The evaluation budget"): the longest line of the console has 201 nodes, so the bound is more than 5000 times the largest count of steps that a line reaches today. A host test gives a smaller budget to the evaluation, so that a tree of the parser reaches it; each host gives the constant.

**The refusals are records.** The first refusal ends the evaluation, and each later force gives nothing. A record holds its member, the place and node, and the values that its sentence needs: the operator, the kinds, the operands, the refusal of the parser, the command. The host writes the sentence; the evaluator writes no text. When the host refuses (an unknown name, a call that fails), it has written its own failure, and the record is `Host_Refused`.

**What a reader sees change.** `%` of the least Integer by `-1` gives 0, its true remainder; before, the console refused it as a division that does not fit. A line past the budget fails with a new sentence, which no line of the console reaches today. Every other sentence is the one of before.

Refused forms:

- **The evaluator generic over a value of each host.** The two hosts evaluate one language with one set of values; a type parameter on each procedure buys nothing.
- **The values kept in the console, with the evaluator asking the host for each operator.** The operators and their refusals are then two codes, one in each host.
- **The check of an effect after the arguments.** In mode `declaration` the arguments of a refused call are then forced for nothing.
- **A step as a time.** A budget of time gives another error on another machine.
- **A step for each force, also of a forced thunk.** A value that many readers share then costs at each read, and the count says more about the readers than about the work.

Subtle points:

- **A kept value points into the memory of the line.** A Text of a thunk is a part of the nested form or of the line memory of the console, so the thunks live for one line, as the values did.
- **The budget is not reached by the console today.** The lines are shorter than the budget by far; the test of its bound uses a smaller budget, and a test checks that the densest line stays below the constant.

### A record literal is typed by its use

A record literal has no type of its own. It takes the type of the parameter or the field that receives it:

- A field of the literal that the type does not have is refused: `error: Substitution has no field mdoe; its fields are sources, signers, mode`.
- A field that the type has, with no default, and that the literal does not give, is refused: `error: Substitution needs the field mode, which has no default`.
- A value of a field is checked against the type of that field, with the same rule, so a literal inside a literal is typed by its field.
- A field whose type is a table of names, such as `inputs` and `outputs`, takes any name. The type of the table checks each value.

A named argument is the same rule on the parameters of a call. An unknown name, a parameter given twice, and a parameter with no default that the call does not give are refused, with the name of the command.

In mode `console`, the console knows the receiver from its command table before the run, so it refuses the literal before any call, as it refuses an argument of another kind. A literal with no receiver, such as `r = { a = 1 }`, is refused there: it has no type. In mode `declaration`, a literal is typed when a force passes it to its receiver. A `let` binding that two receivers take is checked against each one. The error record names the declaration, its line and column, and the chain of fields that the evaluation forced.

**Why typed by its use.** A literal with a type name, `Substitution { mode = .Verify }`, repeats a type that the parameter already states. A literal of no type, checked by the receiver only when it reads a field, accepts a field with a wrong name in silence.

### The forms of layer 3 as built

Layer 3 adds the record literal, the named argument, `let`, `with` and the placeholder `_`. The parser reads them ("The parser package"), the evaluator types and forces them ("The evaluator package"), and the console draws, completes and colors them. The grammar ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "The form of a line"):

```
line       = name "=" expression | expression
expression = sum { "with" sum }
sum        = term { ("+" | "-") term }
factor     = ... | "{" [ name "=" expression { "," name "=" expression } ] "}"
           | "let" name "=" expression { "," name "=" expression } "in" expression
argument   = [ name "=" ] expression | condition | fact name | field names
```

**The words of Lex.** `let`, `in`, `with` and `_` are no names: a variable, a field, a binding or a named argument with one of these names is refused with `Word_As_Name` at its place. `_` stays a name in each longer name, as `sum_values`.

**The record literal.** The parser gives a node `Record_Literal` whose children are its fields, each a node `Literal_Field` with its value. A field given twice is refused by the parser. The evaluator forces the values from the left and gives an untyped value, of the kind `Record_Literal`, which points to its node. The receiver types it:

- The parameter of a call of the kind Record, whose description the host gives from the module file. The names of the fields are checked when the call starts, before any of its arguments runs: an unknown field (`Literal_Field_Unknown`) and a missing field (`Literal_Field_Missing`). The kind and the range of each value are checked when the values are known, before the call runs (`Literal_Field_Kind`, `Literal_Field_Range`). The record is written in the memory of the host.
- The right side of `with`, typed by the record on its left.
- A value that nothing types is refused with `Literal_No_Type`: the value of a line, a variable, and a parameter that is no Record. A field of a record holds no record, so a literal inside a literal is refused as a value of the wrong kind.

**No default: each field is given.** A field of a contract record has no mark of a default, and the forms of this layer need none: a literal gives each field, and `with` changes some fields of a whole record. The question of where a default is written stays open ("Open questions"); a missing field is refused.

**Named arguments.** An argument `name = value`, of a parameter whose form is an expression, is a node `Named_Argument`. Its name is a parameter of the description of the command: an export and a command that makes a record have names, a command of the console has none. The checks when the call starts: an unknown name (`Argument_Unknown`), a parameter given twice by place and by name (`Argument_Twice`), and a parameter that the call does not give (`Argument_Missing`, but the last parameter that a call may leave out). The parser refuses a name given twice and an argument with no name after a named one. Inside `where`, `=` stays the operator of a condition.

**`let`.** A node `Let` holds its bindings, each a node `Let_Binding` with its value, then its body. The parser binds each name of a binding to the names that its values and its body read, after it read the whole `let`, so a binding can name a later one and an inner `let` hides an outer one. In mode `console` the evaluator forces each binding from the left, then the body: the line is forced whole. In mode `declaration` it forces the body only. A thunk that its own computation forces again stops the evaluation with `Cycle` at the name that closes the cycle. `a.field` reads a field of a binding: of a record, or of a literal.

**`with`.** The lowest priority but `|>`. The left value is a record; the right one is a literal of fields of that record, typed with the left record as its base, or a record of an equal description, which replaces each field. Another kind is refused with `With_Kinds`, two records of two descriptions with `With_Records_Differ`.

**The placeholder `_`.** The nested form of `|>` puts the text of the value on the left in the place of `_` ([pipe_operator.md](pipe_operator.md), "The placeholder `_`"). A pass over the tokens of the line, before the nested form, finds each `_` and the group that holds it, and refuses before any call: a `_` that is not a whole argument, two `_` in one call, a `_` in a call nested in the call on the right, a `_` with no `|>` before its call. So the parser and the evaluator never see a `_` that the nested form keeps; the parser refuses one as a word of Lex used as a name.

**The nested form reads the new forms.** The pieces of a call and of a literal are split at the commas outside parentheses and braces; a piece `name = value` keeps its name and nests its value only; a segment that starts with `let` nests each value and the body. So `f(n = x |> g)` is `f(n = g(x))`, and `let a = x |> g in a` is `let a = g(x) in a`.

**What the console shows.** A typed literal is a Record, drawn as any record. The completion offers the fields of the record of the parameter inside `{ }`, and the names of the parameters at the start of an argument of a call whose parameters have names. The words `let`, `in`, `with` and `_` have the color of an operator, the names of the bindings of a `let` the color of a variable, and a field or a parameter before its `=` the color of a parameter.

Refused forms:

- **A check of the whole line before its first call.** It would refuse an unknown field of a literal deep in the line before any call; the check when the call of the literal starts gives the same refusal before the arguments of that call run, with no second walk of the tree. The text of a fault still ends the line where it is.
- **A default of a field from its zero value.** A literal that forgets a field then writes 0 in silence.
- **Named arguments of the commands of the console.** Their parameters have no names in a description; a name that the console gives in its code alone is a second table of names.
- **A cycle stopped by the budget only.** A cycle in a `let` of the console recurses on the stack of the evaluator: a thunk in its computation refuses a second force at once, with the place of the cycle.
- **`with` on any two values.** `with` composes two records only; a second meaning is refused ("The refused forms").

Subtle points:

- **The names are checked before the arguments run, the kinds after.** In `area(g(), {widht = 3})`, `g()` does not run: the name `widht` is refused when the call of `area` starts. In `area({width = g()})`, `g()` runs, then its kind is checked.
- **A literal bound by a `let` is typed at each receiver.** `let s = {…} in area(s) + area(s)` forces the values of `s` once and types them twice, each in the memory of the line.
- **The words of Lex change the meaning of three names.** A command, a variable or a field named `let`, `in` or `with` can no longer be written. No command and no field of the system has such a name.

### The functions of layer 4 as built

Layer 4 adds the anonymous function, its call, the list literal and `map`. The grammar:

```
factor     = ... | "(" [ name { "," name } ] ")" "=>" expression
           | "[" [ expression { "," expression } ] "]"
```

**A function or an expression in parentheses.** A `(` starts a function when its group closes and `=>` follows the `)`. One scanner says it, `function_head` of `console_language`, for the parser, the nested form of `|>` and the colors. The body is an expression: `(x) => x + 1 with r` holds all of it, and a `,` or the `)` around the function ends it. The parser refuses, each at its place: a parameter that is no name (`Parameter_Name_Missing`), a word of Lex as a parameter (`Word_As_Name`), a parameter twice (`Parameter_Twice`), more than 12 parameters (`Too_Many_Parameters`), and a list with no `]` (`List_Close_Missing`). A `->` where the parser expects another token is refused with `Thin_Arrow` at the `->`. No part of such a line runs, because the names before the `->` are the parameters of the function that the line meant, not values, and the console writes the function of the line in the form of Lex: `map(x, n -> n * n)` gives "a function is written (n) => n * n". `->` is no alias of `=>`: one form for one concept. After the whole function, the parser binds each name of its body to its parameter, as it binds the names of a `let`; an inner function or `let` hides an outer name. A call `f(…)` whose name a `let` or a parameter binds is the call of that value, never a command of the host.

**A function is a value with its place of birth.** The value of `(x) => …` is its node and the call of a function in which it was written: no call at the top of the line. It copies no forced value. A name of its body that an outer `let` or an outer parameter binds reads the thunk of that binding, in that call. So `let n = g() in map(l, (x) => x + n)` runs `g()` once, before `map`, in mode `console`, and a function that reads a binding of its line keeps reading the binding, never a copy.

**A call of a function.** The call checks the names of its named arguments and forces its arguments from the left, as the call of an export does, then makes a function call: the function, the call where the function was written, and one thunk for each node of the body that two readers can force: each parameter, and the value of each binding and of each field of a literal. Each other node of a body has one reader in one call, and is computed each time a call forces it. A count of arguments other than the count of the parameters is refused with `Function_Arguments`, named arguments with the names of the parameters. A call of a name whose value is no function is refused with `Not_A_Function`. A call whose text stops in its arguments has no count: the arguments before the fault run, then the refusal of the text comes at its place, as for a command of the host.

**A record literal and a member keep their place too.** A literal written in a body is untyped until its receiver types it, maybe after its call returned: its value names its call, and the receiver forces its fields in that call. A member needs no call: its node holds its name.

**Recursion.** `let f = (n) => f(n - 1) in f(3)` reads `f` in its own body: the value of `f` is forced before the call, so no cycle. Lex has no condition yet, so such a recursion never ends: the evaluation budget ends it, or the evaluation stack bound below.

**The evaluation stack bound.** The evaluator recurses on the stack of its thread, one level for each force inside a force, and a body nested in a recursion reaches any depth before 2^20 steps. So each force measures the bytes of stack that the evaluation took, from the address of a local at its first force, and the evaluation stops with `Stack_Exceeded` past `EVALUATION_STACK_BYTES`, 512 KiB. It is a measure in bytes, not a count of levels: built with `-o:speed`, a level of an operator takes about 1 KiB and a level of a call about 5 KiB. The deepest lines of 200 bytes of today take from 196 KiB (`1+1+…+1`) to 340 KiB (`f(f(…))`), so they pass the bound, and a recursion stops at about 90 calls. The thread of the console that runs the lines had 64 KiB of stack, under what these lines take; it now has the bound and 128 KiB for the host and the command that a call runs at the deepest place, 640 KiB, which its stated budget counts as working memory. A host test builds with larger frames than a module, so its evaluations give a larger bound; the machine test runs the deepest line of calls of a command (31 calls of `hash`), the deepest line of operators and a recursion in the console itself. The console logs the stack of the deepest line of its run as the measure fact `Evaluator_Stack_Deepest`, so the build that runs shows its margin under the bound; a line that the bound stopped measures the bound, and logs nothing.

**The memory of the calls.** The function calls, their thunks and the items of the lists are in fixed arrays of the evaluation, for one line: 256 calls, 512 thunks of calls, 256 items. A call is kept until the line ends, because a function or a literal that it made can outlive it. Past one array, the evaluation stops with `Calls_Full` or `Lists_Full`.

**A list is typed by its use.** `[a, b]` forces its items from the left and gives a List; its items keep their kinds, and an untyped item (a literal, a member) waits for its receiver, as a literal does. `map(list, function)` is a name of the evaluation, not a command of the host: it forces the list, then the function, then calls the function on each item from the first, and gives the list of the results. `map` checks that its first argument is a List (`Not_A_List`) and that its second one is a function of one parameter. A list at the end of a line with an untyped item is refused as that item. An item with no value, a Stream and a Record_Input are refused at the item with `List_Item_Kind`: the last two live in the wiring of their line, and none has an item to draw.

**A function never crosses a border.** No export and no command of the console takes or gives a function or a list: an argument of either kind is refused before the call runs, with `Value_At_Border`. A function is code of Lex, and a list holds values of the evaluation; the receiver of either would have to run Lex or read the memory of the evaluation, against property 19. No variable keeps a function: a function is its node in the syntax tree of its line and the call in which it was written, and it reads the thunks of that line by reference; the tree, the calls and the thunks end with the line. A function that lasts is a field of a declaration, an object with a hash (property 11, property 22), not a variable of one console. A variable keeps a list ("A variable keeps a list").

**A variable keeps a list.** In mode `console`, `x = [1, 2, 3]` keeps the list, and `map(x, (n) => n * n)` on a later line reads it. The line forced the list whole, so its items are values, never thunks. The assignment copies the items into the memory of the variable in the console process: each item, then the bytes of each Text and each Record. A nested list is kept with its items, in the same memory. A line that reads the variable copies the kept items into the items of its own evaluation once, at the first read of the line, so `map` and `filter` read them as the items of any list of that line.

- **The bound.** A variable keeps 64 items at most, the items of its nested lists included (`VARIABLE_LIST_ITEM_CAPACITY`), and 32 KiB of texts and records (`TABLE_KEPT`, the bound of a table of a variable). The 64 items take 5 KiB in each of the 16 variables. A line holds 256 items in all, so a line can read four full list variables and still make a list of 64 results with `map`.
- **The refusal.** A list past a bound is refused with the error record `Over_Limit` (the count and its bound), and the variable keeps its old value: the console copies the list to a separate memory first, then into the variable only when the whole list fits. That memory also lets `x = map(x, f)` read the old items of `x` while it writes the new ones.
- **The items that a variable keeps.** An Integer, a Boolean, a Text, a member of an enum, a Handle, a Record and a list of these. A function in a list is refused for the reason of a function. A Table in a list is refused: a table keeps its rows in its own memory of `TABLE_KEPT` bytes, and a variable keeps one table whole. A Record whose description `join` or `columns` made is refused in a list, because that description lives in the memory of its line. A hash is refused: its value lives in the hash pool of the evaluation of its line.

**No variable keeps a function, and the safe form is not built.** A function that reads no binding of its line, only its parameters, could be kept as its text and parsed again on each line that calls it. That needs a second syntax tree for each line and a check that the body reads no outer name; a closure over `let` bindings would still be refused, so the rule would depend on the body. A function that lasts is a field of a declaration, which has a hash and a name.

**`let` at the top of a line.** `let x = [1, 2, 3]` with no `in` and nothing after its one binding is the assignment `x = [1, 2, 3]`: the parser reads it as an assignment when the line ends after the value. A `let` with `in`, or with two bindings, is the expression `let`.

**The order of the effects in mode `console`.** A call of a function forces its arguments from the left, then its body. A body runs only when a call forces it: a function that no call reaches runs no effect, though the line is forced whole, because its value is the function, not its result. `map` runs its calls in the order of the items.

**What the console shows.** A function is drawn as its text, `(x) => x * 2`. A list of integers, texts, members and functions is drawn on one line, `[2, 4, 6]`; a list of records or tables draws each item in turn. `=>`, `[` and `]` have the color of an operator, a parameter the color of a variable where it is bound and where it is read, and `map` the color of a command. The completion offers the parameters of the functions whose body holds the caret, and `map`.

Refused forms:

- **A function as a copy of the forced values that it reads.** It forces a binding that the body may never read, and its effect then runs in mode `declaration` too early. A reference to the thunk forces it when the body reads it.
- **One thunk for each node of each call.** A body of 200 nodes in a recursion of 50 calls takes 10 000 thunks. The nodes that two readers force are few.
- **The arguments of a function as thunks.** An argument forced when the body reads it runs its effect in the order of the body, not of the line. The call of an export forces its arguments from the left, and the call of a function does the same.
- **A bound of the depth in levels.** A level costs from 1 KiB to 5 KiB of stack; a count of levels either refuses a line of `-` that works today or lets a recursion of calls overflow.
- **The thread of 64 KiB, with a bound under it.** The deepest lines of today would then be refused: built with `-o:speed` for the host, they take more than 64 KiB.
- **A list as a module type.** No export takes a list today; a table is the list of records that crosses a border.
- **`map` as a command of the console.** A command of the host would have to call back into the evaluator to run a function, a second path of the call.
- **No list in a variable.** A list is the first value that a principal builds at the console, and a refusal of `x = [1, 2, 3]` sends the principal to a `let` around each line. The items of a forced list are values, which a copy keeps, as a variable keeps a Record.
- **A list in a variable as a reference to the evaluation of its line.** The evaluation of a line is reset by the next line.
- **One pool of items for all the variables.** A pool shared by the variables needs a compaction at each assignment; a bound for each variable is simpler and states its cost.

Subtle points:

- **A `(` reads ahead.** The parser reads the group of a `(` to its `)` before it knows if it is a function, so a line of 200 bytes reads at most 200 times 200 bytes.
- **The colors read the whole line for each name**, to know the parameters of the functions around it, as they read the bindings of a `let`.
- **`map` comes before a command of that name.** The evaluator finds the name of the evaluation first, so an export named `map` of a loaded module cannot be called by that name; a service keeps its dotted name, `service.map`. A name of the evaluation is a word that a module does not take for an export it wants called alone.
- **`where` inside a function body** still reads a condition: the form of an argument comes from the name of the command, before the parser knows that a `let` binds that name.

### Comments

A comment is `//` outside a text, to the end of its line. The scanner of `console_language` skips it as it skips a space, so it gives no token, the parser makes no node of it, and the nested form of `|>` never reads its bytes: a `|` or a `|>` in a comment is no operator. The colors draw it in the kind Words, the color of a comment. The completion reads the line with the same scanner: it offers nothing while the caret is in a comment, so a word typed there and Enter stay keys of the comment, and a `(` in a comment or in a text opens no group of the arguments. A line of the console can end with a comment, and a line with no token, only spaces and a comment, does nothing. `//` in a text is a part of the text, and `a / / b` is two divisions.

Refused forms:

- **A block comment, `/* … */`.** It nests badly: a `*/` inside it ends it early, and a nesting rule is a second grammar of comments. One comment for each line is enough for a line of the console and for a declaration.

A later option: a doc comment, `///` on the line above a field, kept in the tree with that field, so that the site and the completion show what a field of a declaration is for. It waits for the declarations of layer 6, which have fields to describe.

### `where` keeps the form of a condition

`where(t, status >= 500)` takes a condition: a field, an operator and a value ([`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "Conditions"). It does not take an anonymous function.

The reason is the root service. On a record output of a module that is not started, `where` gives a condition that the root service turns into wiring terms and checks at its border ([module_outputs.md](module_outputs.md)). A condition is a typed record: a field of the description, an operator, a value. An anonymous function is code of the language, and the root service runs no language (property 19). So a function cannot cross to the root service as terms. The console also checks a condition against the record description before the run, and completes its field names.

Anonymous functions serve `map` and the declarations. Inside `where`, `=` is the comparison of the condition, never a named argument: the parser reads the argument of `where` as a condition.

### The evaluation budget

No effect happens during an evaluation in mode `declaration`: no export runs, no network is read, no store is written, no recipe is built.

Recursion is allowed. Each evaluation, in either mode, has the evaluation budget: a fixed count of the steps of the evaluator. The work of an export that the evaluator calls is not a step of the evaluator. Past the budget, the evaluation stops with an error record that names the declaration or the line, its line and column, and the chain of fields that it forced. The budget counts steps, never a time, so one declaration gives the same error on every machine. In mode `console`, the exports that ran before the stop keep their effects, as when an export of a line fails today.

The budget is one constant of the evaluator, the same in both modes:

- A measure sets it when the evaluator first runs a declaration: the largest count of steps over the declarations of the system (the catalog declaration, the system plan and the project of this repository) and the lines of the console tests, with a margin that the measure states. Until then it is 2^20, far above each line of the console ("The evaluator package").
- The tool prints the count of steps of each of these declarations as a measure, never as a condition.
- A declaration cannot ask for more: a foreign declaration then takes the processor time that it wants, and the bound protects nothing. A declaration that needs more is a declaration to change, or a change of the constant, with its measure.

### Declaration inputs, pins and release pointers

A project or a plan names its declaration inputs in one record:

```
project {
  inputs = {
    modus = catalog,
    gt    = follow(publisher = keys.gui_toolkit, name = "gui_toolkit"),
    wren  = declaration(blake3:…),
  },
  outputs = { default = gt.window_app(here()) },
}
```

- `catalog` is the catalog declaration of the system: a declaration whose value is a record of recipes, modules and functions. It is one catalog declaration among others, the default, with no mechanism of its own.
- `declaration(hash)` names one exact declaration.
- `follow(publisher, name)` names the newest release pointer that a publisher signed for a name. A release pointer is a record: the name, a number that only grows, the hash of a tree, and the signature of the publisher. It does the work of a channel of Nix, with no server of authority.

The bytes and the trust are two separate things. The bytes of a declaration come from any source of the substitution policy, because a hash checks itself. The trust comes from the key of the publisher, which the principal names in `keys`, its table of the publisher keys that it trusts.

**The source of an input.** An input that is no exact declaration names a reference that moves: a branch of git, a bookmark or a change of Jujutsu, a branch of Mercurial, a channel of Pijul, an archive at an address, a name that a publisher follows. Each one resolves to a state that does not move, and the system needs only one thing of that state: a modus tree by its hash. So each kind of source is a **source module** of the catalog declaration, with no word of Lex of its own, and fills one contract:

- **A resolver**, an export that only `projects.update` runs, with a network grant for the host of the address and nothing else. It turns the reference into the identity of the state in its format (a commit, a changeset, a state of Pijul, the number of a release pointer) and into the tree hash that the fetcher gives.
- **A fetch recipe**, as `git_fetch` ([recipes.md](recipes.md), "The fetcher"): from the identity, it writes the modus tree and refuses a tree whose hash is not the hash of the pin.

```
inputs = {
  a  = catalog.git.source(address = "https://…/a", branch = "main"),
  b  = catalog.jj.source(address = "https://…/b", bookmark = "main"),
  c  = catalog.jj.source(address = "https://…/c", change = "kxqzv…"),
  d  = catalog.archive.source(address = "https://…/d-1.2.tar.gz"),
  gt = follow(publisher = keys.gui_toolkit, name = "gui_toolkit"),
}
```

- `follow` is the source of a release pointer: it fills the same contract, and its resolver also checks the signature of the publisher.
- A new kind of source is one more module, which a principal can take from a publisher by `follow`: it changes neither Lex, nor the evaluator, nor `projects.update`.
- Jujutsu keeps its states in a git store, so its fetch recipe is the one of git; its resolver reads bookmarks and change ids, which outlive a rebase.
- A neighbour machine of modus needs no resolver: the tree is exchanged by its hash, with the protocol of the cache.
- The identity in the format is provenance, kept in the pin. The tree hash is the one identity that the evaluation and the plan use.

**When the resolution happens.** An evaluation never reads the network to resolve a name, because it has no effect. It uses the pins: for each declaration input, the identity of its state, its tree hash and its publisher when it has one, as it was resolved.

**Where the pins live.** The pins of a project are a Lex file, `pins.lex`, beside `project.lex` at the root of its source tree. Its value is one record literal of hashes, with one field for each declaration input:

```
{
  tool = { commit = "a1b2c3…", tree = blake3:9e7a… },
  gt   = { publisher = keys.gui_toolkit, number = 41, tree = blake3:5f0d… },
}
```

- **A project** is the tree that a principal shares, on GitHub too: `project.lex`, `pins.lex` and its sources. Its tree hash covers both files, so a project given by its hash is wholly fixed, on each machine. Each project that its inputs bring carries its own `pins.lex`, so its inputs do not move either, down the whole graph.
- **No second format.** The one parser reads `pins.lex`, and the evaluation process evaluates it in mode `declaration`, with no effect. The record of the pins types its literal, as each receiver types a record literal.
- **Only `projects.update` writes it**, never a hand. A hand edit cannot pass other bytes: each hash checks itself at the fetch. It can only name another state, which a review sees.
- **Why a text.** A project shared on GitHub must be reviewable. One changed line of `pins.lex` is one input that moved; a binary record shows no useful difference.
- A plan that has no project holds its pins itself.

The commands:

- `projects.update(kernel)` runs the resolver of each input again and writes a new `pins.lex`: a new version of the source tree, whose difference names the lines of the pins that moved. `projects.update(kernel, inputs.gt)` resolves one. With no `projects.update`, the inputs never move.
- The store keeps the tree before as a version (property 9), so the pins of each earlier state of a project stay readable.
- An evaluation with an input that has no pin stops with an error record that names the input and the command `projects.update(kernel, inputs.<name>)`.
- `projects.inputs(kernel)` shows each pin, with its publisher and its hash.

**Composition.** `with` has one meaning: the composition of two records. `a with b` gives the record `a`, with each field of `b` in place of the field of the same name. A field of `b` that `a` does not have is refused, as in a record literal ("A record literal is typed by its use"): the type of `a` receives `b`. So `catalog with { odin = recipe(…) }` changes one recipe.

A declaration input can give a function that changes a catalog declaration. It is called as any function: `gt.overlay(catalog)`, or `catalog |> gt.overlay()` ([pipe_operator.md](pipe_operator.md)). `gt.window_app(here())` is a call of the same kind.

An option of a command is a named argument, never a `with` after the call: `recipes.build(kernel, substitution = { mode = .Verify })`. A `with` after a call composes the record that the call gives; it changes nothing of the call.

### A foreign declaration is safe to evaluate

- The evaluation is pure, and it runs in the sandboxed evaluation process.
- A builder runs in a sandbox of its own ([recipes.md](recipes.md), "The builder").
- A realisation signed by a publisher that the principal does not trust is not used: the recipe is built on the machine, and its builder can change nothing but its empty output store.
- The grants of a foreign plan reach the machine only through the difference that the principal accepts at `plans.apply`.

### Sources and the identity of a source

The identity of a source is the hash of a tree in a store. `here()` gives the tree of the current version of the store of the source of the current project, as a tree reference: a typed value that holds its tree hash and says that it is a tree, so the source of a project is a tree with a hash. A bare hash names no kind, and the field `source` of a project refuses it ([application_projects.md](application_projects.md), "One identity for a recipe"). The versions of property 9 give the history of a source.

Git is an import format and an export format, never a dependency:

- A git repository enters through the fetcher, as a hash given in advance: the commit gives a tree, and the recipe of the fetch holds the hash of its modus tree ([recipes.md](recipes.md), "The fetcher").
- Two machines exchange sources as they exchange modules: a store exchange by hash, with the protocol of the cache. A tree is an object, as a module is.
- Two machines that change one source give two versions with a common version. A three-way merge by the merge export of the module of the store joins them, and a conflict stays in the data as a conflict value, which the principal resolves once ([several_machines.md](several_machines.md), "The exchange of a store between machines").

### The console of a project

The field `console` of a project names what a child console of the project has: the modules that it connects, so that their commands are available, and the stores that it grants.

```
console = { modules = [odin, nasm, qemu], stores = [store("kernel", .Read, .Write)] }
```

- `modules` is a list of module values: `catalog.odin`, `module(blake3:…)`, an output of a declaration input, or a name that a `let` binds to one of them. The name of a module is the name of its commands, as with `connect`: the commands of `odin` are `odin.…`.
- `stores` is a list of stores of the principal, each with its rights.
- `projects.enter(p)`: the service `projects` asks the root service to start a child console of the principal of the caller. At its start, the child console connects each module of `modules`, by its hash: it is what `connect("odin")` does, declared in advance. Its context holds a connection to each store of `stores`, with the rights of the record. Each such store is a store of the principal, and each right is a right that the console that asks already holds.
- Inside the child console, a command of `projects` with no project argument acts on the project that `projects.enter` opened, the project of `here()`: `projects.update()`, `projects.inputs()`.
- `exit()` stops the child console and gives the line back to the console before. It stays a bare name: the console itself does it.
- Nothing is installed. The modules are objects of `module_files`, which a build or the cache gave. Another console sees none of these names.

**Why `console`.** The interface where a principal types is the console, one term for one concept: the field says which console the project gives. The field describes the commands that are available, and nothing more.

### Projects

A project is a record with a source, its declaration inputs, its outputs and its console: `project { source = here(), inputs = {…}, outputs = {…}, console = {…} }`. `project` is the function `modus.project` of the catalog declaration, under a short name (property 22): it adds no mechanism.

- `outputs.default` is the output that `recipes.build(p)` realises.
- Each other output is a field: `recipes.build(kernel.tools)`.
- `projects.enter(kernel)` starts a child console with the field `console` of the project. With no such field, the console connects the builders of the outputs of the project, and grants the store of its source with Read and Write.

An output names an entry of the source tree by the names of its entries from the root of the tree, separated by `/`: `odin.module("src/modules/server")`. The evaluation process takes each name in turn; a name is never `.` or `..`, so the text never reaches above the source tree.

### The services of the declarations

Three services give the commands of the declarations. A command of a service is always `service.command`, as `monitor.count` is:

- **`plans`**: `apply`, `apply_poll`, `rollback`, `rollback_poll`, `difference`. It holds the right to send `Apply` and `Rollback` to the root service for the principal of the caller. The root service computes the difference itself, so `plans` can hide nothing. As built, `plans` computes the difference and keeps the applied plans ("The apply as built").
- **`projects`**: `update`, `enter`, `inputs`. During `update` it runs the resolvers of the source modules, and it writes `pins.lex` in the store of the project, which the caller gives with Write. For `enter` it asks the root service to start a child console.
- **`recipes`**: `build`, `provenance` ([recipes.md](recipes.md)). It asks the root service to realise a recipe, and applies the substitution policy.

The evaluation process is no service. Each of the three starts one when it reads Lex, and the evaluation process holds no right.

Each of the three is a role, with its role contract and its conformance suite: `plans.apply` names the role `Plans`, and the console reaches its holder by the role, never by the name of a module ([roles_and_contracts.md](roles_and_contracts.md)).

Each service acts for the principal of the caller, as the remote display does ([remote_display.md](remote_display.md)). The root service decides each command, with the grants of that principal.

**Why three services, and not one.** Least authority. `recipes` cannot apply a system, and neither can `projects`. A compromised service does only its own part.

**A bare name means one thing only:** the console itself does it, as `where`, `sort`, `start`, `processes` and `exit` ("Bare names for the commands of the declarations" in the refused forms).

### Storage

- **The store `module_files` of the machine** holds the objects by hash: module files, debug objects, trees, release pointers, realisations. A tree is the list of the name, the kind and the hash of each entry, and its hash is the hash of that list ([recipes.md](recipes.md), "Trees").
- **The store `applied_plans` of each principal** holds its applied plans, each as an object named by its number. As built, the private store of the service `plans` holds them, for each principal ("The apply as built").
- **The private store of the service `projects`** holds one object for each loaded project of a principal, `project_<principal>_` and 24 hexadecimal digits of the hash of its name: the name, the evaluation of its `project.lex` and the text of its `pins.lex`, in one write. `projects.update` writes the new `pins.lex` in that object before it moves the pin, so a store that refuses the write moves nothing. The object names the whole name, which the reader checks.
- **The disk grant table** of each principal holds the row "current plan".

### The garbage collector

The garbage collector of `module_files` keeps an object only when a root reaches it. The roots:

- each applied plan that the store `applied_plans` of a principal keeps;
- the signed system description;
- the hash of each row of each disk grant table;
- the modules of each child console of a project that runs, and the recipe of each build that runs.

From each root it follows the imports of each module, the debug object of each module, the entries of each tree, and the output of each realisation. It deletes the rest. An object that two principals reach is kept while one of them reaches it.

## The frequent tasks

| Task | Expression |
|---|---|
| Apply a system | `plans.apply(system)` |
| See the difference before a change of the system | `plans.difference(system)`; `plans.apply(system)` shows it first too |
| Go back to the system before | `plans.rollback()` |
| Go back to one applied plan | `plans.rollback(4)` |
| Declare the console of a project | `console = { modules = [odin, nasm, qemu], stores = [store("kernel", .Read, .Write)] }`, a field of `project { … }` |
| Work in the console of a project, then leave it | `projects.enter(kernel)`, then `exit()` |
| Change one recipe of the catalog declaration | `catalog with { odin = recipe(…) }` |
| Change a catalog declaration with the function of an input | `gt.overlay(catalog)` |
| Build with an option | `recipes.build(kernel, substitution = { mode = .Verify })` |
| Declare a project | `kernel = project { source = here(), outputs = { default = odin.module("src/modules/server"), tools = …, image = modus.image([…]) } }` in `project.lex` |
| Read a project from its source tree | `kernel = declaration(here())` |
| Build a project, or one output | `recipes.build(kernel)`, `recipes.build(kernel.tools)` |
| Resolve each followed input again | `projects.update(kernel)`; in the console of the project, `projects.update()` |
| Resolve one input again | `projects.update(kernel, inputs.gt)` |
| See each pin, with its publisher and its hash | `projects.inputs(kernel)` |
| Take a project from a git repository | `inputs = { tool = catalog.git.source(address = "https://…", branch = "main") }`, then `projects.update(kernel, inputs.tool)` |
| Take a project from Jujutsu by a change | `inputs = { tool = catalog.jj.source(address = "https://…", change = "kxqzv…") }` |

**The check for an incantation.** Each expression names its service and its task: `plans.apply`, `plans.rollback`, `projects.enter`, `projects.update`, `recipes.build`. None names a store of the system, a number of a format, a hash to copy by hand, or an order of two commands.

## The refused forms

- **Environment variables, `PATH` and shared configuration files.** They are ambient state that each process reads (property 8, property 19). The console of a project is a record that one child console starts with.
- **`env` and an environment record, with `tools` as a record of names.** The field says what the principal gets: a console, with modules. A second word for that console, and a record of names beside the names that the modules already have, are two terms for one concept.
- **`shell`.** modus has no shell: the interface where a principal types is the console.
- **`packages`.** A loan from Nix. What a console makes available is modules and their commands.
- **`workspace` and `bench`.** The field describes the commands that are available, not a place of work.
- **A text file that a service reads at its start.** A parser of text in a service, against property 19 and [start_policy.md](start_policy.md). The root service reads the plan, a typed record.
- **A second language beside the console.** Two languages for one principal, against property 22. Lex grows by eight forms of grammar, with one parser and one evaluator.
- **A second parser for the declarations.** Two grammars drift, and a line that the console accepts then means another thing in a declaration. One parser library reads both.
- **Two evaluators (eager console, lazy declarations).** Two semantics of one text, which a test must compare form by form. One lazy evaluator in two modes gives one meaning: the arguments of an export are forced from the left before it runs, and mode `console` forces each line whole.
- **A console that forces only what its result needs.** An export whose result goes unused then never runs, and a line skips an effect that the principal typed. Mode `console` forces each line whole.
- **`with` for the options of a command.** `recipes.build(kernel) with substitution = {…}` gives `with` a second meaning, and the option lands after the call that it changes. A named argument is checked against the parameters before the call.
- **`with` on a function.** `catalog with gt.overlay` gives `with` a second meaning, the call of a function. A call says it.
- **A record literal with a type name, or with no type.** The first repeats the type of its receiver; the second accepts a field with a wrong name in silence.
- **An anonymous function in `where`.** The root service cannot turn a function into wiring terms, and runs no Lex ("`where` keeps the form of a condition").
- **A budget that a declaration asks for.** A foreign declaration then chooses its own bound ("The evaluation budget").
- **A budget set by hand.** A guess has no measure; the measure over the declarations of the system gives the bound and its margin.
- **The resolution of a name during an evaluation.** Such an evaluation reads the network, so two evaluations of one declaration can give two plans. The pins hold the resolution, and `projects.update` changes them.
- **A lock file in a second text format**, such as the JSON of a `flake.lock`. A second format needs a second parser and a second set of rules. `pins.lex` is Lex, which the one parser reads.
- **The pins as a binary typed record.** A project shared on GitHub must be reviewable, and a binary file shows no useful difference. One changed line of `pins.lex` is one input that moved.
- **The pins outside the tree, in a store of the machine.** The source then travels with no pins: a second machine resolves again and gets other states. `pins.lex` is an entry of the tree, which its hash covers.
- **Bare names for the commands of the declarations (`apply`, `update`, `build`, `enter`).** They look like words of the language, and they take generic names that every module wants. A command of a service is always `service.command`, as `monitor.count` is; a bare name is a command that the console itself runs, as `exit`.
- **One service `declarations` with every right.** A fault in its build code could then apply a system. Three services each hold one part ("The services of the declarations").
- **`git(...)` as a word of Lex, or a kind of source in `projects.update`.** Each new format (Jujutsu, Mercurial, Pijul, an archive) would change the language or the command. A source module fills one contract, and the catalog lists them.
- **The commit of git as the identity of an input.** Two formats then give two identities for one tree. The tree hash is the identity; the commit is provenance in the pin.
- **A central registry of names that the system trusts.** A server of authority for every name. A release pointer is trusted by the key of its publisher, and its bytes come from any source.
- **The grants of a foreign plan applied with no view of their difference.** With it, a plan takes a grant in silence. `plans.apply` shows the difference first.
- **A signature on each object.** A hash checks itself. Only a realisation and a release pointer are signed ([recipes.md](recipes.md)).
- **A store at a fixed place.** Property 11: a module holds no place, so the store `module_files` needs none.
- **Git as the identity of a source.** One source then has two identities, and the system depends on a tool that it does not need.
- **An apply that changes the processes that run.** A process that runs holds the handles of its start. A start, or the next start of the machine, gives one state.
- **A rollback that writes a new plan.** Two plans with one content, and a history that a reader must decode.
- **An evaluation in the console process.** A foreign declaration then runs in the process that holds the grants of the principal. The evaluation process holds none.

## Subtle points and hazards

- **The difference is computed by the root service.** The evaluation process runs foreign code; if it computed the difference, it can hide a grant. The root service compares the plan with its own copy of the current applied plan.
- **The commit is the write of the row.** `Apply` writes two stores: `plans`, then the disk grant table. A stop between them leaves a plan that no row names, which the garbage collector removes. It never leaves a row that names no plan.
- **An `Apply` against an old difference is refused.** The command holds the hash of the current applied plan that the principal saw.
- **A plan never names a module that the store lacks.** `Apply` checks the closure: each hash, each import, each debug object.
- **`here()` needs the hash of a tree.** Today a tree that changes has no hash ([`docs/glossary/storage.md`](../../../docs/glossary/storage.md), "Tree"). The design needs it ([recipes.md](recipes.md), "Trees").
- **A lazy record can refer to itself.** `outputs.image` can name `outputs.default`. A cycle stops at the thunk that its own computation forces again, with its place; a work with no end and no cycle stops at the evaluation budget.
- **The plan of principal 0 is measured as the list of its start policy.** A plan with no start policy of its own changes no measure. Its disk processes are measured at their start, as today.
- **A module of the console of a project has no name in Lex.** `modules = [odin, nasm]` evaluates to hashes. `projects.load` names each one `module_` and the first 16 hexadecimal digits of its hash, so two modules of one project never share a name; the console of the project shows that name until a module carries its own name in its module file.
- **The services act for the principal that the root service wrote.** An export of `plans`, `projects` and the collector takes no principal: it reads the principal of the connection and refuses a caller that does not act for it. A caller cannot see or change the plans of another principal by naming it.
- **A ticket is a serial of one run of the trusted display.** A display that started again gives serials from 1 again. A call to a display that stopped fails, and `plans` drops the pending apply then, so a ticket never reads the decision of a dialog of a later run.
- **The store `module_files` of the machine is shared.** Two principals with one module store it once. A question `Has` from one principal tells it whether another holds an object: the cache protocol answers only for the objects that the principal of the connection reaches.

## Open questions

- **The forced values of a declaration reference across lines.** The console evaluates a reference again on each line that needs it. An evaluation process that stays between the lines keeps the forced thunks, and holds their memory with no line that runs.
- **Where the default of a field is written.** A field of a contract record has no mark of a default today, so a record literal must give each field. The mark goes in the record description, or in the function of the catalog declaration that takes the record. The frequent tasks need it: `{ mode = .Verify }` takes the sources and the signers of the plan of the principal.
- **The bounds of a list at the console.** A call takes 12 arguments at most. A record literal is bounded by its record, 64 fields at most, and by the text of a line. A list of a line is bounded by the 256 items of its evaluation, and a list of a variable by 64 items and 32 KiB ("A variable keeps a list").

## The build order

Each layer adds one capability to a system that works, and each is a tested commit:

1. **The parser in one library package.** The parser leaves the console for one library package, with no change of behaviour: the same trees and the same refusals. The package is a private part of the console until the evaluation process is its second owner ("The parser package").
2. **The shared lazy evaluator in mode `console`.** It replaces the eager evaluator of the console: each line is forced whole, and the effects run in the order of their data. The mode is a parameter, and mode `declaration` already refuses an effect at its border ("The evaluator package").
3. **The record literal, named arguments, `let`, `with`, and the placeholder `_` of `|>`** ("The forms of layer 3 as built").
4. **Functions `(x) => …`, the list literal and `map`** ("The functions of layer 4 as built").
5. **Mode `declaration` and the evaluation process.**
6. **`module(...)`, `recipe` and `plan`**, and the evaluation budget measured.
7. **The service `plans`**: `plans.apply`, `plans.difference` and `plans.rollback`, with the root ring commands `Apply` and `Rollback`.
8. **The service `recipes`**: `recipes.build` and `recipes.provenance`, with the builders and the substitution policy ([recipes.md](recipes.md)).
9. **The service `projects`**: `projects.update` with the source modules and `pins.lex`, `projects.inputs`, and `projects.enter` with the child console of a project. `projects.update` comes after `recipes`, because a resolver needs the tree hash that a fetch recipe gives.

## State

Built: layers 1 to 5 of the build order, and the immutable tree format and garbage collector of `module_files`. The shared Lex packages (`console_language`, `console_condition`, `lex_parser` and `lex_evaluator`) live in `src/library/modus`, owned by `src/modules/system/console` and `src/modules/system/declaration_eval`. Lex supports `blake3:<64 lowercase hex>` hash literals, multi-line `.lex` declarations with comments and trailing commas, call on a record literal (`plan { … }`, `project { … }`), postfix `.field` selection, conditionals (`if … then … else …`), comparisons (`=`, `!=`, `<`, `<=`, `>`, `>=`), booleans (`true`, `false`), `map`, `filter`, and `|>` with `_`. In mode `declaration`, record fields and `with` compositions remain lazy thunks until forced, cycles (direct, mutual, record-field and cross-file imports) stop with `Cycle_Detected`, strict step, depth, stack and pool bounds protect against hostile input, side-effecting commands are refused at the border, and `import`/`declaration` read sources through a pure caller-supplied loader with no I/O. The contract `src/library/modus/contract/declaration_eval` defines the read-only input bundle and deterministic canonical output formats, and `src/modules/system/declaration_eval` runs the evaluator inside a zero-authority call host.

The canonical encoding and domain-separated BLAKE3 hash of an immutable tree live in `src/library/modus/contract/tree_hash`, using BLAKE3 derive-key mode so a tree hash never collides with an object hash. Bottom-up tree freezing, verified reads and lookups live in `src/library/internal/storage/immutable_tree`, and the mark-and-sweep collector of `module_files` lives in `src/library/internal/storage/module_gc` (iterative traversal, depth bound, cycle and integrity refusal with zero deletions). Both private parts are wired into `src/modules/system/storage` (`freeze_tree`, `tree_read`, `tree_entry`, `collect_garbage`), with host tests for each package.

The shared contract for plans, recipes, and projects lives in `src/library/modus/contract/plans_recipes`: canonical order-independent plan hashing (`"modus plan v1"`), strict border validation (including cyclic role-chain and trusted-path refusal), `plan_diff_compute` feeding into `powerbox` (`Show_Plan_Difference`), 104-byte `applied_plans` store records and rollback validation, deterministic `pins.lex` formatting and strict parsing, the unified `Source_Resolver_Request`/`Source_Resolver_Response` contract, and the full project-console lifecycle contract (`Project_Declaration`, `Project_Console_Spec`, canonical `project_console_spec_hash`, `project_console_grant_diff`, and `MAX_PROJECT_CONSOLE_DEPTH`). The pure state machines live in `src/library/internal/plans/plans_core`, `src/library/internal/recipes/recipes_core`, and `src/library/internal/projects/projects_core`, wired into the freestanding service modules `src/modules/system/plans`, `src/modules/system/recipes`, and `src/modules/system/projects`, with adversarial host tests for each package. In `projects_core`, `projects.enter` constructs an isolated child-console grant specification from the project's `console` field (refusing unknown projects, empty console fields, duplicate module names, and nesting past `MAX_PROJECT_CONSOLE_DEPTH`), tracks active child consoles per principal, requires verified trusted Display consent when entering adds a store or module grant outside the active session, never modifies the principal's applied plan or installs anything globally, and `exit()` (also registered as a built-in command in `src/modules/system/console`) tears down the innermost child console, revokes its temporary module connections and store shares, and restores the parent console cleanly.

Built with the exports of the services: `src/library/modus/contract/plans_recipes/service_records.odin` holds the rows of the exports and their borders (`plan_of_rows`, `plan_difference_summary_of`, `plan_generation_row_of`, `project_declaration_of_evaluation`, `pins_lex_line_difference`), with host tests of each refusal. The service `plans` exports `difference`, `apply`, `apply_poll`, `rollback`, `rollback_poll` and `generations`, each for the principal of the caller, as "The apply as built" says: `apply` shows the difference with `plan_diff_ask` of the holder of Display and gives a ticket, `apply_poll` reads `plan_diff_poll` and commits an accepted plan to the private store of `plans`, `rollback` shows the difference back to the generation before and gives a ticket, and `rollback_poll` writes the current object once the principal accepted; with no generation before the current one `rollback` is refused with `Absent` and the unit `Versions`. The port of the trusted display is `src/modules/system/plans/ports.odin`; the port of a private store over the storage client is `modus:storage_port`, shared by the three services; the objects and their checks are `src/library/modus/contract/plans_recipes/private_store.odin`. The service `projects` exports `load` (the evaluation of `project.lex` from the evaluation process, and the text of `pins.lex`), `update` (one input to a new tree hash, with the new `pins.lex` and its one changed line), `pins` and `build_recipe` (the recipe of the inputs tree of a project: one input for each pin), from `src/library/internal/projects/projects_core/loaded.odin`; each load and update writes the project object first, and a project that the memory does not hold is read back from the store.

Built with the grants of the services: `plans`, `recipes` and `projects` are no parts of the system. Each has a row of `start_grant_sets` with Serve, Store and a start at the first connection; `plans` also has the boot image, Connect to the role `display` (the trusted display, whichever module holds it) and the start grant Plans, which sends `Plan_Roles` only. `plans` logs `store 1, display 1, roles 1` at its start. The service ring of `plans` and its commands (`Compute_Diff`, `Apply_Plan`, `Rollback_Plan`, `Query_History`), which no starter gave, are removed: its exports are its one face.

Built with the plan at the start: the root service starts `plans` after the read of the choice of principal 0 and before the start policy, and waits for `Loaded` within the hang bound, as "The plan of principal 0 at the start" says. The host tests of `plans_core` boot a store with a holder of Display, with no plan, with a plan that a newer image refuses, and with a damaged store; the host tests of `role_policy` prove the wait and its ends. The machine test `persist` proves it across a restart (`plan_and_audit_scenario.odin`): on a new disk the wait ends at `No_Plan`, a plan of principal 0 names the test module `settings_stand_in` as the holder of Settings and the principal accepts it on the trusted display, and at the next start the row `settings` of the start list starts that holder, with the pass `Boot`, never `settings`. Before that plan, four plans are refused, each with its error record and with generation 0 still current: a `Plan_Expected` of no current plan, a difference that the principal refuses, a holder whose hash names no module of the image, and a module of the image that does not fill the contract of Settings. The test modules are in the boot image `plan_and_audit` only. A key before the arm time of the dialog has a host test of the dialog only: a machine test cannot place a key before it with no bound on the speed of the host.

Left: the measure of the roles of the plan of principal 0 at the start; the service rings of `recipes` and `projects`, which no starter gives either; the applied plans in the root service, with the root ring commands `Apply` and `Rollback` and the row "current plan", the evaluation process that `plans`, `projects` and `recipes` start (today the caller gives the evaluation of `project.lex`), console service-command wiring for `plans`, `recipes`, and `projects.enter`/`projects.update`/`projects.inputs`, the write of `pins.lex` in the store of the project, which the caller gives with Write, live source resolver modules and sandboxed builder execution, machine tests of immutable trees, project consoles, and `module_files` garbage collection, the evaluation budget measured on full system declarations, and field defaults.
