# Programs from a disk

## Purpose

A developer adds a program to a machine with no new boot image. The module file of the program is an object in a store of the storage service. The root service reads it, checks it, and starts it. Such a program is a disk program ([`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Disk program").

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "A program from a disk".

## Constraints

- **What runs is named by its hash.** The boot image is checked against the signed system description before a program starts. A file of a disk has no such check: no tree of the storage service has a hash today, and none is signed.
- **The root service is the only program that creates access from nothing.** It holds the grant table. No other program starts a program with a grant.
- **The storage service is a program.** The root service starts it. A fault in it, or a storage service that another party changed, must not give a program a grant, and must not stop the root service.
- **A name is an identity in two tables.** The grant table of the root service gives a program its grants by its name. The storage service names a private store by the name of its program.
- **No kernel operation is added.** The kernel creates a program from memory that its starter maps. It does not know where the bytes of a module came from.

## The chosen form

### The store and the name

The module files of a principal are the entries of the root tree of the store `programs` of that principal. The name of an entry is the name of the program: 1 to 23 bytes. The object of the entry is the module file.

The store is the store of the principal whose session the asker belongs to. Its name comes from the one procedure that names each store of a principal, so a principal reaches only its own programs.

### The command names the hash

The principal types the name and the hash:

```
start_from_disk("visitor", "5f0c…64 hexadecimal digits…")
```

The name finds the entry. The hash is the identity: the root service starts the bytes only when their BLAKE3 hash is the hash of the command. The hash comes from the party that built the file (the tool prints it), on a path that does not pass through the storage service.

So the storage service is a transport, as the boot image is. It can refuse to give the bytes. It cannot give other bytes: the root service refuses them with a sentence that holds both hashes.

The command is one record of the root ring, `Start_From_Disk`. A record has seven values: the hash takes four, the name three. This is why the name has 23 bytes at most, as the name of a principal has.

### The root service reads, and never waits

The root service is the load source of each program that it starts. It stays the load source: it opens a connection of its own to the storage service, reads the object into memory of its own budget, checks the hash, and starts the program from that memory.

The root service has one loop that serves every root ring. A call that waits for the storage service inside that loop stops the machine when the storage service does not answer. So the load is a state of the loop, not a call:

| State | The root service waits for | Then |
|---|---|---|
| Idle | nothing | A command `Start_From_Disk` opens the connection and asks for the size |
| Size | the size of the object | It makes the memory and asks for the first bytes |
| Bytes | the next bytes | It asks again from the place that it reached, or checks the hash and starts the program |

The completion of the command is held until the load ends. Between two answers the loop serves each other ring as before.

Four rules bound the load. None of them needs the storage service to be honest:

1. **A stop is an event.** The loop reads the state of the storage service at each pass. A storage service that stopped ends the load.
2. **Each answer must make progress.** An answer with no byte before the end, or with more bytes than the object has left, ends the load. So the count of the calls is at most the bytes of the object.
3. **The size has a limit.** An object over 4 MiB is refused before any memory is made. The memory of the load comes from the budget of the root service.
4. **The whole load has a deadline.** 30 seconds after the command, the load ends with "did not answer". The deadline is a rule of the system, not a measure of the disk: it only frees the one place of the load.

One load runs at a time. A second command during a load is refused with `Busy`.

### The least right

A program of the boot image has a row in the grant table: its name gives it its grants, its budget and the limit of its store. A disk program has no row, and gets:

- the log, with the right Write only, and a window, as each program has;
- the date page, the settings page and the glyph caches, read-only, as each program with a window has;
- no start grant: no root ring, no machine handle, no boot image, no store, no endpoint, no service ring;
- the budget of a program that no row names: 2048 pages, one program, one thread.

Nothing in the file gives a grant. The root service reads no table of the file to decide a grant.

**A disk program cannot take a row by its name.** The root service refuses, before any read, a name that a module of the boot image has, a name that the grant table gives a grant, a name of a program of the system, and the name `programs`. Without this rule a file named `notes` would start with the store of `notes`, and a file named `console` with the root ring.

**The budget of the starter pays nothing for the code.** A program of the boot image maps the shared code of its module from the table of prepared modules of the root service, which the budget of the root service pays. A disk program gets a copy of each of its modules from its own budget. So a disk program holds no page of the root service while it runs.

### The imports

A disk program imports by hash, as each module does. The load source is the boot image and the replacement table of the machine. An import whose hash is not in the boot image fails the load at the stage Find, with the load error of every load.

### The order of the start

The storage service starts on demand, after the root service, as before. The root service starts no disk program during the start of the machine: the first one starts when a principal asks. So there is no cycle, and a machine with no data disk starts as before.

### How the file reaches the disk

The tool writes a data disk of the format of the storage service that holds the store `programs` with its module files (`modustool` builds such a disk for the test part `disk_programs`). It prints the hash of each file. The module is a row of the module table of the tool that is not in the boot image.

The writer of the tool is checked by the open of the storage service: a host test opens the image with the code that the service uses, and compares each object byte for byte and each hash.

### The grants of a disk program: proposed, not decided

A disk program has no grant. The next step gives the principal a command that grants one. Three choices are open (`docs/DECISIONS.md`, "Open questions for the owner"); this section states the form that is proposed for each, and why.

**What a grant names.** The hash of the file, never its name: `allow(hash, grant)` and `disallow(hash, grant)`, from a caller that acts for the principal. The root service keeps a table of rows, one for each hash: its grants and its budget. A file with another hash, under the same name, has no row. This follows from the rule above: what runs is named by its hash.

**Where the store of a disk program is.** A private store is named today by the name of its program, and a name gives nothing to a disk program. Two forms come from the identity alone, and both have a fault:

- the store has the name of the program: two different files with one name share a store, and a file that takes a name takes the data of another;
- the store has the hash of the file: a new version of a program has another hash, and loses its data.

The proposed form: the principal names the store in the grant, `allow(hash, "store", "my_notes")`. The store is then an object that the principal owns and lends: the same store goes to the next version of a program by one more command, and to no file that the principal did not name. No rule derives a store from a name or from a hash.

**How long a row lasts.** Proposed: a row lasts until the machine stops, in the memory of the root service. A row that survives a start is a file that the root service reads before the principal unlocked a store, and that a reader of the disk can change: it needs the encrypted stores of a principal first.

**The grants that no command gives.** A disk program never gets the ring of the root service, a right over the machine or a device, the right to debug, or the right to act for the principal: each one is the whole machine, or the principal.

## Refused forms

- **The command gives a name only, and the entry gives the hash.** The storage service then chooses what runs. The check of the root service would compare the bytes with a hash that the same party gave: it finds damage, not a changed file.
- **The name of the entry is the hash, and the program has no name.** A reader of the tree then sees 64 digits for each program. The commands `stop`, `grants` and `revoke` name a program by a name.
- **The file states the grants that it asks for.** A file then grants itself. In the model of the storage, a package states the grants that it asks for and a principal grants them ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model"): the statement is data for the principal, never a grant.
- **The storage service starts the program.** It would need the right to create a program with a window and a log. Then two programs create access.
- **The root service reads the disk.** It would hold the block ring and the code of the format. The storage service is the one client of the data disk.
- **The console reads the bytes and gives them to the root service.** This is a good form for bytes that come from the network. It needs a second path for the bytes, a memory object that the console lends. It is left; the check of the hash is the same.
- **A call that waits in the loop of the root service.** One storage service that does not answer stops every command of the machine.
- **A deadline for each answer in place of one for the load.** The bound is then the deadline times the count of the calls. One deadline is one number to state.
- **The table of prepared modules for a disk program.** The budget of the root service would hold the code of a program that has no row.
- **A kernel operation that loads from a store.** The kernel has no file system and no loader for imports.

## Subtle points

- **The hash is computed on the bytes, not read from the entry.** The entry of an object holds the hash of the object, which differs from the BLAKE3 hash of its bytes when the object has a hole before its last block ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "The hash of an object"). The root service reads the bytes, so the hash of a module stays the BLAKE3 hash of its file.
- **A length from the storage service is copied, then checked.** The size is read one time. Each count of bytes is compared with what is left before a copy.
- **The name of the caller of the connection is `programs`.** The root service is no row of its own table of started programs, so the connection has a caller record of its own. Its grant is the limit of the store, with no grant to act for a principal.
- **The connection ends with the load.** The root service holds no handle of the storage service between two loads.
- **The rule of the debug access needs no change.** It reads the grants that a program received at its start. A disk program received none, so a caller that acts for its principal can debug it.
- **A read makes no commit.** The storage service writes the limit of a store at a change only. A machine whose disk has no store `programs` gets no new store from a refused command.

## Built and left

Built: the command `Start_From_Disk` of the root ring and the command `start_from_disk` of the console; the load as a state of the loop of the root service, with its four bounds; the check of the hash; the least right, with the rule of the names; the disk of the tool with the store `programs`; the test part `disk_programs`.

Left:

- **Grants for a disk program.** A command with which the principal gives a disk program a grant or a larger budget. The identity that such a grant names must not be the name alone.
- **A file that comes without the tool.** A console command that stores bytes that came from the network in the store `programs`.
- **Imports from the same store.** The load source of a disk program is the boot image. An import by hash from the store needs the index from a hash to an object ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "5. Not built: the next steps").
- **A list.** No command lists the entries of the store `programs` with their hashes.
- **A service from a disk.** A disk program has no service ring, so no program connects to it.
