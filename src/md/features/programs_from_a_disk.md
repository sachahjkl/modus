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

Two ways: the network, on a machine that runs, or a disk that the tool writes.

**The network.** The module file service ([`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Module file service") is the program `programs` of the boot image. Its private store is the store `programs` of its principal: the root service names the private store of a program by the name of the program, and the store of the module files has the name `programs`. So the service writes there with the grant `Store` that each program with a store has, and with no grant of a new kind. Its other grants: `Network`, a client grant of TCP to one web server (10.0.2.100 port 80, the address that QEMU gives to a server of the host), and `Serve`.

The console calls its two exports through a connection, as for each service (`connect("programs")`):

- `programs.receive(nickname, path)` sends `GET path` to the web server, takes a body of 1 to 4 MiB with a `Content-Length`, writes it as the object `nickname` of the root tree of the store, and gives the 64 hexadecimal digits of the BLAKE3 hash of the bytes that it received. The log says the same. The principal then types `start_from_disk(nickname, hash)`.
- `programs.list()` gives one row for each object of the root tree but `grant_table`: its name, its bytes, and the BLAKE3 hash of its bytes, which the service reads again and computes. The service writes one line of the log for each row.

The hash that `receive` gives is a help for the principal, not a proof: the root service still reads the bytes and checks them against the hash of the command. A service that another party changed, or a web server that gave other bytes, can make the store hold any bytes under the nickname. It cannot make them run under a hash that they do not have.

The rules of the service:

- **A caller that acts for the principal of the store.** The root service gives the service the number of its principal in its context (`disk_program.SERVICE_VALUE_PRINCIPAL`). A caller that does not act for its principal, or whose principal is another, is refused: a service that writes for any caller is a confused deputy.
- **The nickname has the rules of a disk program** (`disk_program.name_problem`): `programs` and `grant_table` are refused, so the service never writes over the disk grant table.
- **The path is one line of 1 to 200 bytes that starts with `/`**, with no space and no control byte: a request carries no second line that the caller wrote.
- **The bounds of a load.** The body has 1 to 4 MiB, the limit of the root service, and the whole call ends 30 seconds after it starts, the deadline of a load. A response with no `Content-Length`, a status that is not 200, or a connection that ends early writes nothing.
- **The store first, then the answer.** The object is written in ranges and made one commit; the hash goes back only after the commit.
- **One call at a time.** The service holds one file in memory, 4 MiB of its own budget.

**The tool.** The tool writes a data disk of the format of the storage service that holds the store `programs` with its module files (`modustool` builds such a disk for the test part `disk_programs`). It prints the hash of each file. The module is a row of the module table of the tool that is not in the boot image.

The writer of the tool is checked by the open of the storage service: a host test opens the image with the code that the service uses, and compares each object byte for byte and each hash.

### The grants of a disk program

The principal gives a disk program a grant with a command. The rules of the table are in `src/library/support/disk_program` (`grant_table.odin`), with no allocator and no kernel operation, so the host tests run each rule.

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

**How long a grant lasts.** A persisted table is the object `grant_table` of the store `programs` of its principal, next to the module files that it grants. It has a tag of keyed BLAKE2b (32 bytes) under a key that a passphrase gives. A reader of the disk who has no passphrase then cannot add a grant: a table whose tag fails is refused with a line of the log, and gives no grant. The persistence is a setting in the table: global, with an exception for each row (`disk_persistence`). The default is to persist.

The name `grant_table` is kept, as the name `programs` is: no disk program has it, so the table is never read as a module file and never written over one.

**Principal 0 and the machine passphrase.** Principal 0 is the machine, and a passphrase for it is optional ([`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Machine passphrase"):

- **No machine passphrase.** No key signs the table of principal 0: it lasts until the machine stops. Its data stays: the store of a nickname is on the disk, and the next grant of `store` finds it.
- **A machine passphrase.** The table of principal 0 is read after the passphrase is typed at the start, and written after each change.

The record of the machine passphrase is the object `machine` of the store of `unlock` (a store of principal 0), beside the file of a named principal. It holds the salt of Argon2id, with the parameters of a named principal, and the machine key sealed with ChaCha20-Poly1305 under the key that Argon2id derives ([`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Machine key"). The machine key is 32 random bytes. A wrong passphrase does not open the seal, so it never gives a wrong key that would write a table no one can read.

**Who holds which key.** `unlock` derives the key of the seal, opens the machine key, and derives from it the key of the tag: keyed BLAKE2b of the machine key over the text `modus disk grant table` (`disk_program.table_key_of_machine_key`). It gives the root service the key of the tag only, in one record of its ring (`Machine_Key`), erases the other keys, and stops. The root service holds the key of the tag in its own memory until the machine stops. So the program that writes the table holds no key that opens the seal or that could sign another thing; the machine key stays a key that the TPM can seal later, with its other uses outside the root service.

**Where the passphrase is set.** `machine_passphrase()` in the console asks the root service (`Machine_Passphrase`), which starts `unlock` in a mode of its own. The window asks for the passphrase two times; it is never a text of the console or of the log, as for a named principal. A machine with a passphrase refuses a second one: a change and a removal are not built.

**The three states of the record.** `unlock` reads the record `machine` as absent, present, or unreadable (a read error of the store, or a record that does not decode). Only an absent record lets a new passphrase be set: an unreadable record can hold a good machine key, and a new record over it would lose that key and, with it, the table. An unreadable record gives no key: `unlock` tells the root service (`Machine_Key`, "unreadable"), which refuses each change of the table of principal 0 and `machine_passphrase()`, each with a sentence.

**One record in a run.** `unlock` writes the record before it gives the key. After the write it never writes a second record in the same run: when the root service does not answer the key in time, `unlock` stops with a line of the log. A root service that took the key late then holds the key of the record on the disk, and the passphrase opens that record at the next start.

**At the start.** The root service starts `unlock`, and tells it whether the root service holds the key already (after a lock it does). `unlock` reads the record of the machine; with a record and no key held, it tells the root service (`Machine_Key`, "awaited") and asks for the machine passphrase before the passphrase of a named principal. Until the passphrase is typed:

- the machine runs, and each other ring is served: the root service waits for nothing;
- the table of principal 0 holds no row, so a disk program of principal 0 starts with no grant;
- a change of the table of principal 0 is refused with a sentence that says to type the passphrase: a change made then would be lost at the read.

Enter with no passphrase skips it: the disk grants of principal 0 stay absent until `unlock` asks again, at the next start of the machine or after a lock.

**The read and the write.** A key always comes with a read, before any write, so no write loses a table that the key signed:

1. The key arrives with its origin: the open of an existing record, or a new passphrase on a machine with no record (`Machine_Key`, "opened" or "new"). The root service reads `grant_table`.
2. A table whose tag verifies becomes the table of principal 0. An absent table gives no row, and the root service writes its own table there.
3. A table that is refused (its tag, or a field) gives no grant, and its line is on the log. What follows depends on the origin of the key (`disk_program.table_read_decision`):
   - **An opened key.** The table is kept: nothing is written over it, and each change of the table of principal 0 is refused with a sentence until the machine starts again. Such a table can be a good table of an older machine key, or one that a byte changed; a write over it would lose its grants with no sign. The way out today is a version of the table that verifies: a caller that acts for principal 0 restores it in the store `programs`, and the next start reads it. A change of the machine passphrase is the other way out, and it is not built.
   - **A new key.** No record existed before this passphrase, so no key of a record signed that table. It is written over with the table of this machine, which holds the rows made before the passphrase.
4. Each later change writes the table again. A change during a write marks one more write after it.

The read and the write are states of the loop of the root service, as the load of a module file is: one call of the storage service at a time, through a connection of its own to the store `programs`, with the deadline of a load. A storage service that stops, or that gives no answer, ends the call with a line of the log. A read that ends so leaves the table unread: changes stay refused, as the root service does not know what the disk holds.

**A write that fails is tried again at once, 3 tries at most.** A `disallow` whose write does not reach the disk would give the grant back at the next start, so the retry cannot wait for a later change. The retry, and not a completion held until the write ends, fits the loop of the root service: each command is answered in the pass that reads it, and one write carries every change that came during it (a held completion would need a queue of completions for each write). Each try has the deadline of a load, so the tries end in a bound. After the third failure the table is unwritten: the log says that the disk keeps an older table and that a grant taken since can come back at the next start, and each change is refused until the machine starts again.

The table of a named principal is not persisted yet. The console, the only program that sends `allow`, acts for principal 0 only ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "5. The session"), so no caller can change the table of a named principal, and a key with no use is only a target.

## Refused forms

- **The command gives a name only, and the entry gives the hash.** The storage service then chooses what runs. The check of the root service would compare the bytes with a hash that the same party gave: it finds damage, not a changed file.
- **The name of the entry is the hash, and the program has no name.** A reader of the tree then sees 64 digits for each program. The commands `stop`, `grants` and `revoke` name a program by a name.
- **The file states the grants that it asks for.** A file then grants itself. In the model of the storage, a package states the grants that it asks for and a principal grants them ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model"): the statement is data for the principal, never a grant.
- **The storage service starts the program.** It would need the right to create a program with a window and a log. Then two programs create access.
- **The root service reads the disk.** It would hold the block ring and the code of the format. The storage service is the one client of the data disk.
- **The console reads the bytes and gives them to the root service.** It needs a second path for the bytes, a memory object that the console lends, and a load from memory beside the load from the store. The console has no grant of the network either. The module file service puts the bytes in the store, so the one load of the root service stays the one path.
- **The console fetches the file.** The console would need the grant `Network`, and the console already holds the most grants of the machine. The module file service holds the one remote and the one store, and nothing else.
- **The root service fetches the file.** The root service would hold TCP and HTTP, the code that reads the most hostile input of the machine.
- **The console writes the store `programs` through `open_store`.** A place of another store reads, restores and clones only. A write there for each caller that acts for the principal lets that caller write each store of the principal, the stores of `notes` and of `unlock` too.
- **A start grant of a new kind for the store `programs`.** The store of a program already has the name of the program; the name `programs` gives the store with the grant `Store` of each program, and a new kind of grant adds a case to each table of the grants.
- **The service starts the program after the write.** Two programs would then start programs, and the service would need the root ring.
- **The hash of the list read from the entry.** The entry of an object holds the hash of the object, which differs from the BLAKE3 hash of its bytes when the object has a hole ("Subtle points", below).
- **A call that waits in the loop of the root service.** One storage service that does not answer stops every command of the machine.
- **A deadline for each answer in place of one for the load.** The bound is then the deadline times the count of the calls. One deadline is one number to state.
- **The table of prepared modules for a disk program.** The budget of the root service would hold the code of a program that has no row.
- **A kernel operation that loads from a store.** The kernel has no file system and no loader for imports.
- **The store refuses an entry whose name another hash has.** The storage service is a transport, and a rule that it holds is a rule of a party that the root service does not trust. The root service checks the hash anyway.
- **A row of the table is made at the first start of a nickname.** A row with no grant protects nothing, and fills a table of 16 rows.
- **`allow` on a nickname with no row and no program that runs, with a read of the bytes.** It needs a second load from the disk for a command that changes a table. The principal starts the program by its hash first.
- **A table of principal 0 on the disk, with no tag or a tag under a key that the disk holds.** A reader of the disk could then add a grant.
- **The key of the tag from the passphrase alone, with no sealed key.** A wrong passphrase then gives a wrong key with no sign of it: the read refuses the table, and the next write signs a table under the wrong key. The seal tells a wrong passphrase at once. It also gives the TPM one random key to seal later, with no change of the table.
- **`unlock` gives the root service the machine key, or the key of the seal.** The root service would then hold a key that opens the record, or that signs what is not a table. It needs the tag only.
- **`unlock` stays, and tags each table for the root service.** A program with the passphrase would run for the whole session, and each change would wait for a second program.
- **The table in the store of the root service, or of `unlock`.** The table grants the files of the store `programs`, and the root service already reads that store. A second store adds a name to reserve and a second limit, for no gain: the tag protects the table in any store.
- **The root service waits at the start for the passphrase.** A machine whose passphrase nobody types would not start. The read is a state of the loop, so the start never waits.
- **A change before the read, merged with the table read.** Two tables with a row of one nickname need a rule of which wins. The change is refused until the read, with a sentence that says why.
- **The machine passphrase as a line of the console.** The console keeps each line in its history and in its store.
- **A table that does not verify is written over after any key.** The rule is that such a table is refused. Under an opened key it can be a good table of another key, and the write would lose it with only a line of the log.
- **A record that cannot be read is taken as no record.** A read error or one changed byte would then let a new passphrase replace a good machine key.
- **The completion of a change held until its write ends.** It needs a queue of completions for each write, as a change during a write joins the next write; a bounded retry gives the same result in the loop.
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
- **The tag does not stop an older table.** The storage service keeps the versions of `grant_table`, and a caller that acts for principal 0 can restore one. The tag of an older version verifies: a grant that `disallow` took can come back. A counter that only grows, in the TPM, ends it; it is not built.
- **The key passes through the ring of `unlock`.** The ring is memory of the root service that only `unlock` maps, and the root service closes it when `unlock` stops. `unlock` erases its own copies of the keys. The root service writes zeros over the record in the ring and over its local copy after it takes the key; the copy of the record in its loop is overwritten by the next record. A refusal of `Machine_Key` puts no value of the record in its answer.
- **The store `programs` has three writers.** The module file service writes the module files, the root service writes `grant_table`, and a caller that acts for the principal restores a version. The storage service keeps the pending changes of each connection apart, and each commit is one commit of the store. The limit of the store is one constant for each of them (`disk_program.STORE_BLOCKS_LIMIT`).
- **A block of zero bytes in a module file is a hole.** The service writes the file in ranges; the storage service keeps a block of zero bytes as a hole, and the hash of the entry then differs from the BLAKE3 hash of the file. The list and the root service compute the hash on the bytes, so a file with a page of zero bytes still has its own hash.
- **The service is no row of the disk grant table, and the store is no grant of a disk program.** A disk program never reaches the store `programs`: the store of a nickname has the prefix `disk-`.
- **A grant made between the start and the report of `unlock`.** The root service learns that the machine has a passphrase only when `unlock` read its store. A change made before is in the table in memory, and the read replaces it; the line of the read counts the rows that it replaced.

## Built and left

Built: the command `Start_From_Disk` of the root ring and the command `start_from_disk` of the console; the load as a state of the loop of the root service, with its four bounds; the check of the hash; the least right, with the rule of the names; the disk of the tool with the store `programs`; the test part `disk_programs`. The disk grant table: the nickname rule, `allow`, `disallow` and `nickname_move` (the commands `Disk_Grant` and `Nickname_Move` of the root ring), the grant `store` with the store of the nickname, and the format of the persisted table with its tag. The machine passphrase: its record in the store of `unlock`, `machine_passphrase()`, the ask at the start, the key of the tag in the root service, the read and the write of the table of principal 0, and the setting of persistence (`disk_persistence`). The module file service: `programs.receive`, a file from a web server into the store, and `programs.list`, the files with the hash of their bytes.

Left:

- **The machine key sealed by the TPM.** By default the TPM seals the machine key and no one types anything; with a passphrase, the TPM and the passphrase together open it. Until then a machine with no passphrase keeps the table of principal 0 until it stops.
- **A change and a removal of the machine passphrase.** A change seals the same machine key under a new passphrase, so the table stays valid.
- **The table of a named principal on the disk.** The same read and write, with a key that `unlock` derives at the unlock. It needs a caller that acts for a named principal and sends `allow`.
- **An older table.** A counter that only grows, in the TPM, so that a restored version of the table is refused.
- **A second ask after a skip.** A command that asks for the machine passphrase again, with no restart and no lock.
- **A second read after a failed read, and a write after a failed write.** Today both wait for the next start of the machine.
- **The principal in the tag.** The table of a named principal needs its number in the tagged bytes or in the text of its key, so that a table of one principal cannot move to the store of another.
- **A store size from the module.** The size of the store of a nickname from the budget that the module asks for, by a policy that the principal sets.
- **The nickname in the windows.** The monitor and the menu show the nickname with the hash faded beside it. The kernel report of a program has its name and no hash, so the monitor needs the hash from the root service.
- **Imports from the same store.** The load source of a disk program is the boot image. The root service must find an import by its hash in the store `programs`, read it with the bounds of a load, and check its hash. The storage service has no index from a hash to an object ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "5. Not built: the next steps"): without it, the root service reads each object of the store to find one hash. The loader also needs a load source with files beside the boot image.
- **Another web server.** The grant of the module file service names one remote. A remote that the principal chooses is a grant that the principal gives, as the grant of a client of `remote` is.
- **The module file service for a named principal.** The service runs for principal 0, which the console acts for. A named principal needs a caller that acts for it, as for its disk grant table.
- **A file from another store.** A copy of an object of another store of the principal into the store `programs`, with no network.
- **A service from a disk.** A disk program has no service ring, so no program connects to it.
