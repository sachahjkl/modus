# Data evolution: stored records through a change of their type

A module keeps records in its private store: the settings, the line history, the disk grant table, the files of `unlock`, the applied plans. A new release of the module can change the record type. From 1.0, the real data of a principal survives each such change. This file records the decisions that 1.0 needs for that: what a stored record carries, which changes the system accepts, where the migration runs, how a rollback takes the data back, and how the tool refuses a change that loses data.

Before 1.0, none of it applies ("Before 1.0").

## The constraints

- **Property 9.** A store belongs to one process. Only the process that owns the store changes it; the root service reads no record of it. Each commit is atomic, and the state before it is a version.
- **Property 11.** A new release of a module is a new module. The store of a package is attached to the identity of the package, not to its hash ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model"), so two modules of one package read one store, at two times.
- **Properties 12 and 19.** A record type has one record description, in the flat tables of the module file. The system has no schema language beside it.
- **The version rule of the record streams** ([module_outputs.md](module_outputs.md), "The version rule of a record type"). Two ends of a wiring need two equal descriptions. That holds because both ends run at once and are built together. Stored data breaks that assumption: its writer is a module of the past.

## Before 1.0

Before 1.0, a change of a stored type, or of any format, breaks the old data. Nothing reads it, converts it or keeps it for the new module. No version number is bumped as a ceremony, and no check refuses a change for the lack of a migration. No machinery of this design runs before 1.0.

The work of this file starts at the preparation of 1.0. The release 1.0.0 ships the first descriptions that the check protects.

## What a stored record carries

A **stored type** is a record type whose records a module keeps in its store. A **typed object** is an object that holds records of stored types. A document (the text of a note, a text of the editor, a picture) has no stored type, and no migration touches it. A module file has its own format and stays outside this design.

**The decision: the object carries the description of its records, and the identity of a description is its hash.**

A typed object has a head (its mark and the count of its tables), the canonical description of each table, then the records of each table. The canonical description holds the name of the type, its size, and for each field its name, offset, type, size, sign, integer unit, field kind and contract enum. For a field of an enum of the module, it holds each member with its value. It holds no documentation text. A sealed or tagged object keeps its seal over the whole typed object, the descriptions too.

The **description hash** is the BLAKE3 hash of a canonical description. The reader computes it from the object; the object does not state it. The tool computes the hash of each stored type of the module at the build.

The owner reads each typed object through one border. The border copies the object, checks each description with the checks of a module file (`module.record_type`) and each record with the border of its description, then compares each hash:

- the hash of a current stored type of the module: the records;
- the hash of a description that a migration of the module reads: the records after the migration;
- any other hash: a refusal that names the object and the hash. **The module never writes over an object that it refused.**

**Why a hash, and not a version number.** A person writes a number and forgets to change it; the tool computes a hash, and no change of a field escapes it. Two branches that each add a field give one number to two layouts, and two hashes. A number gives an order, which the system does not need: a module knows the hashes that its migrations read, and an unknown hash is a refusal, whether newer, foreign or damaged.

**Why the description in the object, and not only its hash.** A hash alone needs a registry of the descriptions that every module writes, which property 8 refuses. With the description in the object, the console shows any typed object by its fields, and a derived migration reads the old layout with no copy of the old type in the source.

## The kinds of change

The tool matches the fields of two descriptions by name, and by a rename that the author declares. A **derived migration** is computed from the two descriptions by a pure procedure; the author writes no code. A **declared migration** is a procedure that the author writes. Each migration has two directions: the **forward migration** to the new description, and the **backward migration** back, for a rollback.

| Change | Forward | Backward |
|---|---|---|
| Add a field | Derived: zero, which the contract makes valid ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Base types") | Derived: dropped, a stated loss |
| Remove a field | Derived: dropped, a stated loss | Derived: zero |
| Rename a field or the type, move a field | Derived | Derived |
| Widen an integer or a Text field | Derived | Derived; a value that does not fit refuses the record. No clamp, no cut text |
| Change only the field kind (Plain to Hexadecimal) | Derived | Derived |
| Narrow, change the sign, the unit or the type of a field | Declared | Declared |
| Split or merge fields, or tables of one object | Declared | Declared |
| Add a member to an enum | Derived | Declared: a map to a member before, or a refusal. Never a default member |
| Remove a member | Declared: a map of the member that leaves | Derived |
| Keep the fields and change their meaning | A new name of the type, so declared | Declared |
| Move records into another object | Refused | Refused |

A **stated loss** is a value that is not zero and that a migration drops. A rollback shows each stated loss before the principal accepts it.

**What modus takes, and what it refuses:**

- **The record streams:** a reader reads only records of its own description. The migration is the one code that knows two descriptions, and it runs once for each object.
- **Protocol Buffers:** the added field with a zero default as the cheap case. Refused: the tolerant reader, which reads a type that it was not built for with no error, and the field numbers reserved for ever.
- **Cap'n Proto:** nothing. Its prefix rule (a struct that grows at its end, a field that never leaves) is the rule that the record streams refused already, and that the settings use today with no check of what changed.
- **Avro:** the description of the writer goes with the data, and the tool derives the mechanical changes from two descriptions. Refused: the resolution at each read, which keeps two descriptions in each reader for ever, and the schema registry.
- **Expand–contract migrations of databases:** the safety of a rollback. Refused: the phase in which old code and new code run on one database at once. A store has one owner process, so two descriptions are never current at once.

## Where the migration runs

**The decision: a migration is a procedure that the new module declares. It runs in the process that owns the store, eagerly at the first start of the new module, before the module serves. The same border runs it again at a read that meets an older description.**

- **The declaration.** The module file names the stored objects of the module (an object, or a tree whose objects hold one set of stored types) and its migrations: the hash before, the hash after, the direction, and the procedure. The module never walks its store to guess which object holds records. A migration is no export: no other process calls it.
- **Eagerly, at the first start.** A refused record stops the start, with the object and the record named, in place of a failure in the middle of the work of the principal. After the pass, the module reads one description.
- **Again at a read.** A process that acts for the principal can restore an older version while the owner runs, and a read of a version gives the bytes of its time. The owner migrates a current object of an older description and commits it. It migrates a version in memory only, because a version never changes. A reader that is not the owner never writes: it shows the records by the description in the object.
- **Atomic.** One object is the unit: one read, one commit. The state before is a version of the same object, so its history stays whole. The commit goes through `write_range` and `commit`, which the storage service refuses when the object changed after the first pending change ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "Ranges"). So a restore during the pass is never lost under a migration.
- **Resumed.** A stop during the pass leaves objects of two descriptions. Each object carries its own, so the store reads through the border with no repair, and the next start goes on. The state of the store is the progress: no mark of a step.

### A rollback

After `plans.rollback()` ([declarations.md](declarations.md), "Apply, the difference and the rollback"), the older module finds a description that it does not know. Only the newer module knows both.

- **The difference.** The root service reads the module files of both plans already. It compares their stored objects and migrations, and the difference that the principal accepts names each stored type that goes back and each stated loss. The root service reads no record.
- **The migration start.** Before the next start of the older module, the root service starts the newer module with the store of the package and no other grant, and with the descriptions to reach in its context. It runs its backward migrations and stops with the outcome Done; then the older module starts. A refused record stops it with the outcome Refused and its error record, and the older module does not start.
- **No backward migration.** `plans.rollback` is refused before any change, with the module and the type named.
- **A rollback of the system image.** The older image has no copy of the newer module, so no migration start runs. The older module refuses the object, runs on zero records in memory, and refuses a write of that object with an error record that names the newer description. The data waits on the disk for the newer system, or for a restore that the principal chooses.

## The tests and the check

A module that changes a stored type declares its migration in both directions, and a test that reads the data of the description before. The tool checks this before any machine, as it checks the fact waits ([../infrastructure/scenario_fault_loop.md](../infrastructure/scenario_fault_loop.md), "The check of the fact waits").

- **The shipped descriptions.** At each release from 1.0.0, `modustool changelog release` writes the canonical description of each stored type of the release, beside `src/library/contract/release/release.odin`. No person edits them.
- **The check refuses** a stored type whose description no release shipped, with no forward migration from each shipped description of that type and no backward migration to it; a migration from a description that no release shipped (a stale migration, as a stale wait); a declared rename that no shipped description needs; a stored type with a Handle field, padding, or an enum field with no members in its description.
- **The samples.** For each shipped description, the tool writes a typed object of edge values: 0, 1, the largest and the smallest value of each type, each member of each enum, a Text field full to its last byte. The forward migration of the sample passes the border of the new description; the backward migration of that result gives the sample again, but for the stated losses; a damaged sample is refused by the border before any migration.
- **A declared migration** also has a host test of its author, with real records of the version before: the meaning of a split or of a map is not in the description.
- **The border is a fuzz target** ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)): it reads bytes from a disk that another party can write.

## The refused forms

- **A version number in each record**, and **a hash with no description** ("What a stored record carries").
- **The type in the entry of the storage service.** The engine would know record descriptions; it stays a store of bytes.
- **A walk of the store to find typed objects.** A document whose first bytes look like the mark would meet a migration.
- **A lazy migration as the only form.** A failure shows in the middle of the work, and each read path keeps two descriptions.
- **A migration in the root service or in a migration service.** It reads the private records of every store, against property 9.
- **A rollback that restores the store as it was at the apply.** It drops each change of the principal since, in silence. It stays a choice of the principal, through the versions.
- **A move of records between objects.** The storage service commits one object at a time; a stop between two commits breaks the link of the two objects.
- **Writing over an object of an unknown description.** That turns a rollback into a loss.

## Subtle points

- **The description in the object is data from a disk.** It is copied and checked before its hash is computed.
- **An enum field of a stored type carries its members.** An enum of a module in a field is a plain Integer in a module file today ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The kind of a field"). With no members in the description, an added member changes no hash, and the older module refuses each record after a rollback.
- **A change of display only changes the hash.** A change of a field kind rewrites each object of the type once, through a derived migration. One rule is worth one commit for each object.
- **A sealed object migrates where its key is.** The file of a principal migrates in `unlock` after its open, and is sealed again. The disk grant table migrates in the root service when it reads the table with its key.
- **An archive is never migrated.** The collector keeps the records of other modules ([module_outputs.md](module_outputs.md)); an audit must not change, so each segment keeps the description of its writer and is read through it.

## The order of the work

All of it starts at the preparation of 1.0:

1. The stored type in the module file: its canonical description and hash, the members of each enum field, the stored objects, and their refusals.
2. The typed object and its border, in a contract package, with host tests of each refusal and a fuzz target.
3. The typed store package: the pass at the start, the border at a read, the never-write-over rule, the derived migrations.
4. The stores of that time in the typed form, each breaking its old data, as before 1.0.
5. The shipped descriptions and the check, from the release 1.0.0.
6. The migration start at a rollback, with the stored types in the difference. It needs the service `plans`.
7. The upgrade test: a machine test boots the signed image of the release before, writes each store, then boots the new image and reads it.

## Open questions

- **The oldest release whose data a module reads.** Each migration of each release step stays, or a release states a floor and the principal steps through an intermediate release.
- **A version kept for a rollback.** The state before a forward migration is an ordinary version, which the retention rule can thin.
- **A store with many typed objects.** The pass at the start reads each stored object. A store of a million records needs a measure, then a pass while the module serves or an index of the descriptions.
- **A move of records between objects.** It needs a commit of several objects in one commit of the storage service.
- **A rollback of the system image.** The newer modules can stay in the store `module_files` after an update, so that the rollback of an image runs their backward migrations.

## State

Designed for after 1.0, not built; nothing of it runs before 1.0. Each store keeps its own form today, and a change of it breaks the old data.
