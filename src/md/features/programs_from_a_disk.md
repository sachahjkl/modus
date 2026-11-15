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

A program of the boot image has a row in the grant table: its name gives it its grants and the limit of its store. A disk program has no row, and gets:

- the log, with the right Write only, and a window, as each program has;
- the date page, the settings page and the glyph caches, read-only, as each program with a window has;
- no start grant: no root ring, no machine handle, no boot image, no endpoint, no service ring, and no store unless the disk grant table gives one to its nickname (see below);
- the budget that its file asks for, up to the largest budget of a disk program, with no budget exception, paid by the one budget of all disk programs; a file that asks for nothing gets the least budget, 2048 pages, one program, one thread ([module_budget_request.md](module_budget_request.md)).

Nothing in the file gives a grant. The root service reads no table of the file to decide a grant: it reads the disk grant table of the principal, which only a command of the principal changes. The table `Budget` of the file is a request, which the root service limits.

**A disk program cannot take a row by its name.** The root service refuses, before any read, a name that a module of the boot image has, a name that the grant table gives a grant, a name of a program of the system, and the name `programs`. Without this rule a file named `notes` would start with the store of `notes`, and a file named `console` with the root ring.

**The budget of the starter pays nothing for the code.** A program of the boot image maps the shared code of its module from the table of prepared modules of the root service, which the budget of the root service pays. A disk program gets a copy of each of its modules from its own budget. So a disk program holds no page of the root service while it runs, but the pages of the one budget of the disk programs, which the root service set apart at the first disk program.

### The imports

A disk program imports by hash, as each module does. The load source is the boot image and the replacement table of the machine. An import whose hash is not in the boot image fails the load at the stage Find, with the load error of every load.

### The order of the start

The storage service starts on demand, after the root service, as before. The root service starts no disk program during the start of the machine: the first one starts when a principal asks. So there is no cycle, and a machine with no data disk starts as before.

### How the file reaches the disk

The tool writes a data disk of the format of the storage service that holds the store `programs` with its module files (`modustool` builds such a disk for the test part `disk_programs`). It prints the hash of each file. The module is a row of the module table of the tool that is not in the boot image.

The writer of the tool is checked by the open of the storage service: a host test opens the image with the code that the service uses, and compares each object byte for byte and each hash.

### The grants of a disk program

The principal gives a disk program a grant with a command (`docs/DECISIONS.md`, D-260). The rules of the table are in `src/library/support/disk_program` (`grant_table.odin`), with no allocator and no kernel operation, so the host tests run each rule.

**The nickname.** The name of the entry of a file in the store `programs` is its nickname: the principal chooses it, and the file never does. The root service names the program by its nickname (the slot, the log, `grants`, `stop`, the monitor), and the log writes the hash of the file beside it.

**The disk grant table.** The root service keeps one disk grant table for each principal ([`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Disk grant table"). A row binds a nickname to the hash of one file, and holds the grants of that file. 16 rows at most. It is apart from the tables by name of the root service (`grants_of`), which a disk program never reaches.

**Two hashes never share a nickname.** The rule holds in the root service, at `start_from_disk`, and not in the storage service:

- The storage service is a transport. Each program with a grant of the store `programs` can write a new object under a name, and the store has one object for each name anyway. A rule in the store holds only as long as the store is honest.
- The root service computes the hash of the bytes before a start. It compares the hash with the row of the nickname: a row with another hash refuses the start before any read, with the two hashes in the sentence.
- A nickname with no row gets no grant. So a file under it gains nothing, and the root service does not refuse it.

`start_from_disk(nickname, "")` takes the hash from the row of the nickname. The hash is still the identity: the bytes are checked against it, and the log writes it.

One file can have two nicknames. Each nickname has its own row, its own grants and its own store: a grant names the file and the nickname together.

**What a grant names.** `allow(nickname, grant)` and `disallow(nickname, grant)` write the row of the hash that the nickname names now: the hash of its row, or, with no row, the hash of the disk program of that nickname that runs. A nickname with neither is refused: the root service knows a hash only from a row or from a check of the bytes. The caller acts for its principal (`acts_for_principal`, not revoked), and changes the table of that principal only. A grant takes effect at the next start of the program: the kernel gives the handles of a grant at the start. `revoke` ends a grant of a program that runs, as for each program.

**The store of a disk program.** The grant `store` gives an isolated store of its own, attached to the nickname, not to the hash. Its name is `disk-` and the nickname, with the ending of the principal (`disk-visitor`, `disk-visitor.principal.1`).

- The store of a hash: a new version of a program has another hash, and loses its data. Refused.
- The store of the nickname: an update is the principal pointing the nickname to a new hash, and the store follows. A file under another nickname gets a new, empty store. No file chooses its store.
- The prefix `disk-` keeps the stores of the disk programs apart from the stores of the boot image: the name of a module has no byte `-`. A nickname with a store has letters, digits, `-` and `_` only, so it cannot build the ending `.history` or `.principal.N` of another store.
- A name of a store has 31 bytes at most. A nickname whose store name does not fit is refused at `allow`, not cut.

The size of the store is a line of the budget that the module asks for (`src/md/features/module_budget_request.md`). The request of that budget has no part for the store yet: the store has the default limit of a store, 64 blocks.

**The update.** `nickname_move(nickname, hash)` points the nickname to another file. Its grants and its store follow. Before the change, the log says "root: the file <hash> will get the data of <nickname>". A program of the nickname that runs keeps the grants of its start.

**The grants that no command gives.** A disk program never gets the ring of the root service (`root_ring`, `connect`, `principals`, `debugger`), a right over the machine or a device (`inspect`, `stop`, `schedule`, `events`, `data_disk`, `scratch_disk`, `network_device`, `settings`, `clock`, `replace`, `system_part`), or the right to act for the principal: each one is the whole machine, or the principal. The root service refuses each one with a sentence that says it. The other grants are not built: a command gives `store` only.

**How long a grant lasts.** The disk grant table of a named principal persists across a restart. It is an object of a store of the principal, with a tag of keyed BLAKE2b (32 bytes) under a key that is derived from the passphrase, as the key of the unlock is. A reader of the disk who has no passphrase then cannot add a grant: a table whose tag fails is refused with a line of the log, and no grant. The persistence is a setting in the table: global, with an exception for each row. The default is to persist.

Principal 0 has no passphrase, so no key signs its table: the table of principal 0 lasts until the machine stops. Its data stays: the store of a nickname is on the disk, and the next grant of `store` finds it.

The format of the persisted table is built and tested on the host: `table_encode`, `table_decode`. The root service does not read or write it yet. The console, the only program that sends `allow`, acts for principal 0 only ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "5. The session"), so no caller can change the table of a named principal yet, and a key with no use is only a target.

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
- **The store refuses an entry whose name another hash has.** The storage service is a transport, and a rule that it holds is a rule of a party that the root service does not trust. The root service checks the hash anyway.
- **A row of the table is made at the first start of a nickname.** A row with no grant protects nothing, and fills a table of 16 rows.
- **`allow` on a nickname with no row and no program that runs, with a read of the bytes.** It needs a second load from the disk for a command that changes a table. The principal starts the program by its hash first.
- **A table of principal 0 on the disk, with no tag or a tag under a key that the disk holds.** A reader of the disk could then add a grant.
- **The console acts for the named principal of the session.** The console acts for its own session only; a console that acts for another principal is a confused deputy.

## Subtle points

- **The hash is computed on the bytes, not read from the entry.** The entry of an object holds the hash of the object, which differs from the BLAKE3 hash of its bytes when the object has a hole before its last block ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "The hash of an object"). The root service reads the bytes, so the hash of a module stays the BLAKE3 hash of its file.
- **A length from the storage service is copied, then checked.** The size is read one time. Each count of bytes is compared with what is left before a copy.
- **The name of the caller of the connection is `programs`.** The root service is no row of its own table of started programs, so the connection has a caller record of its own. Its grant is the limit of the store, with no grant to act for a principal.
- **The connection ends with the load.** The root service holds no handle of the storage service between two loads.
- **The rule of the debug access needs no change.** It reads the grants that a program received at its start. A disk program with no grant can be debugged by a caller that acts for its principal. A disk program with the grant `store` cannot: a store is a grant of one program.
- **The root service finds a disk program by a flag of its slot, not by its name.** The connection of a disk program to the storage service gets the store of its nickname and the limit of that store, from the grants of its start, and never the grants that `grants_of` gives a name.
- **A move does not change a program that runs.** It keeps its grants and its connections. The next start reads the row again.
- **A read makes no commit.** The storage service writes the limit of a store at a change only. A machine whose disk has no store `programs` gets no new store from a refused command.

## Built and left

Built: the command `Start_From_Disk` of the root ring and the command `start_from_disk` of the console; the load as a state of the loop of the root service, with its four bounds; the check of the hash; the least right, with the rule of the names; the disk of the tool with the store `programs`; the test part `disk_programs`. The disk grant table: the nickname rule, `allow`, `disallow` and `nickname_move` (the commands `Disk_Grant` and `Nickname_Move` of the root ring), the grant `store` with the store of the nickname, and the format of the persisted table with its tag.

Left:

- **The persisted table in the machine.** The root service reads the table of a named principal after the unlock and writes it after each change, with the key that `unlock` derives; the setting of persistence as a command. It needs a caller that acts for a named principal and sends `allow`.
- **A store size from the module.** The size of the store of a nickname from the budget that the module asks for, by a policy that the principal sets.
- **The nickname in the windows.** The monitor and the menu show the nickname with the hash faded beside it. The kernel report of a program has its name and no hash, so the monitor needs the hash from the root service.
- **A file that comes without the tool.** A console command that stores bytes that came from the network in the store `programs`.
- **Imports from the same store.** The load source of a disk program is the boot image. An import by hash from the store needs the index from a hash to an object ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "5. Not built: the next steps").
- **A list.** No command lists the entries of the store `programs` with their hashes.
- **A service from a disk.** A disk program has no service ring, so no program connects to it.
