# Processes from a disk

## Purpose

A developer adds a module to a machine with no new boot image. The module file is an object in a store of the storage service. The root service reads it, checks it, and starts it as a process. Such a process is a disk process ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Disk process").

The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "A module from a disk".

## Constraints

- **What runs is named by its hash.** The boot image is checked against the signed system description before a process starts. A file of a disk has no such check: no tree of the storage service has a hash today, and none is signed.
- **The root service is the only process that creates access from nothing.** It holds the grant table. No other process starts a process with a grant.
- **The storage service is a process.** The root service starts it. A fault in it, or a storage service that another party changed, must not give a process a grant, and must not stop the root service.
- **A name is an identity in two tables.** The grant table of the root service gives a process its grants by its name. The storage service names a private store by the name of its process.
- **No kernel operation is added.** The kernel creates a process from memory that its starter maps. It does not know where the bytes of a module came from.

## The chosen form

### The store and the name

The module files of a principal are the entries of the root tree of the store `module_files` of that principal. The name of an entry is the name of the process: 1 to 23 bytes. The object of the entry is the module file.

The store is the store of the principal whose session the asker belongs to. Its name comes from the one procedure that names each store of a principal, so a principal reaches only its own processes.

### The command names the hash

The principal types the name and the hash:

```
start_from_disk("visitor", "5f0c…64 hexadecimal digits…")
```

The name finds the entry. The hash is the identity: the root service starts the bytes only when their BLAKE3 hash is the hash of the command. The hash comes from the party that built the file (the tool prints it), on a path that does not pass through the storage service.

So the storage service is a transport, as the boot image is. It can refuse to give the bytes. It cannot give other bytes: the root service refuses them with a sentence that holds both hashes.

The command is one record of the root ring, `Start_From_Disk`. A record has seven values: the hash takes four, the name three. This is why the name has 23 bytes at most, as the name of a principal has.

### The root service reads, and never waits

The root service is the load source of each process that it starts. It stays the load source: it opens a connection of its own to the storage service, reads the object into memory of its own budget, checks the hash, and starts the process from that memory.

The root service has one loop that serves every root ring. A call that waits for the storage service inside that loop stops the machine when the storage service does not answer. So the load is a state of the loop, not a call:

| State | The root service waits for | Then |
|---|---|---|
| Idle | nothing | A command `Start_From_Disk` opens the connection and asks for the size |
| Size | the size of the object | It makes the memory and asks for the first bytes |
| Bytes | the next bytes | It asks again from the place that it reached, or checks the hash and starts the process |

The completion of the command is held until the load ends. Between two answers the loop serves each other ring as before.

Four rules bound the load. None of them needs the storage service to be honest:

1. **A stop is an event.** The loop reads the state of the storage service at each pass. A storage service that stopped ends the load.
2. **Each answer must make progress.** An answer with no byte before the end, or with more bytes than the object has left, ends the load. So the count of the calls is at most the bytes of the object.
3. **The size has a limit.** An object over 4 MiB is refused before any memory is made. The memory of the load comes from the budget of the root service.
4. **The whole load has a deadline.** 30 seconds after the command, the load ends with "did not answer". The deadline is a rule of the system, not a measure of the disk: it only frees the one place of the load.

One load runs at a time. A second command during a load is refused with `Busy`.

### The least right

A module of the boot image has a row in the grant table: its name gives it its grants and the limit of its store. A disk process has no row, and gets:

- the log, with the right Write only, and a window, as each process has;
- the date page, the settings page and the glyph caches, read-only, as each process with a window has;
- no start grant: no root ring, no machine handle, no boot image, no endpoint, no service ring, and no store unless the disk grant table gives one to its nickname (see below);
- the budget that its file asks for, up to the largest budget of a disk process, with no budget exception, paid by the one budget of all disk processes; a file that asks for nothing gets the least budget, 2048 pages, one process, one thread ([module_budget_request.md](module_budget_request.md)).

Nothing in the file gives a grant. The root service reads no table of the file to decide a grant: it reads the disk grant table of the principal, which only a command of the principal changes. The table `Budget` of the file is a request, which the root service limits.

**A disk process cannot take a row by its name.** The root service refuses, before any read, a name that a module of the boot image has, a name that the grant table gives a grant, a name of a process of the system, and the name `module_files`. Without this rule a file named `notes` would start with the store of `notes`, and a file named `console` with the root ring.

**The budget of the starter pays nothing for the code.** A process of the boot image maps the shared code of its module from the table of prepared modules of the root service, which the budget of the root service pays. A disk process gets a copy of each of its modules from its own budget. So a disk process holds no page of the root service while it runs, but the pages of the one budget of the disk processes, which the root service set apart at the first disk process.

### The imports

A disk process imports by hash, as each module does. Its load source is the boot image, the replacement table of the machine, and the module files of the store `module_files` of its principal that the root service found and checked for this load. A developer then adds a process and its library modules to a machine that runs, with no new boot image.

**The import scan.** The root service finds an import that the boot image does not hold by an import scan ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Import scan"): it lists the root tree of the store `module_files`, reads the bytes of each entry, computes their BLAKE3 hash, and keeps the bytes whose hash an import names. The scan is a stage of the load of the process, after the check of the hash of the module file and before the start:

| State | The root service waits for | Then |
|---|---|---|
| List | a page of the entries of the root tree | It notes each object of 1 byte to 4 MiB but the entry of the process, and asks for the next page; an empty page ends the list |
| Import size | the size of the next entry to read | It makes the memory, and asks for the first bytes |
| Import bytes | the next bytes of that entry | It asks again, or computes the hash: bytes whose hash an import names are kept, the others are freed |

The order of the reads: each entry one time, in the order of the list; then an entry that was read before its hash was wanted, one time more. The scan ends when each wanted hash has its bytes, or when no entry is left to read. A hash with no bytes refuses the start with one line of the log, which names the import and its importer:

```
root: refused store_importer from the disk: store_importer imports 3a9c…, and no file of the boot image or of the store module_files has bytes with this hash; the import scan read 7 files
```

**The bounds.** The scan runs inside the load, so each rule of the load holds: one connection, the deadline of 30 seconds for the whole load, a progress at each answer, 4 MiB at most for each file. Three bounds are its own (`src/library/modus/disk_process/import_scan.odin`):

- **64 entries.** The scan notes the first 64 objects of the list. The line of a refusal says when the store has more.
- **8 modules of the store, 4 levels.** The imports of the module are level 1, their imports level 2. A ninth hash, or a fifth level, refuses the start. A process has 16 modules at most anyway.
- **The reads.** 64 entries and two reads for each wanted hash at most: a storage service that changes the bytes at each read cannot make the scan last past this count.

The store `module_files` holds 4096 blocks, 16 MiB: the first pass of a scan never reads more than that, and each wanted hash adds two reads of 4 MiB at most.

**The walk.** The root service reads the import table of the module file, then of each file that it keeps. A hash that a module of the boot image has is not wanted. A replacement of the machine applies as in the loader: the root service wants the hash of the replacement too, and walks the imports of the module that the loader gives. The imports of a module of the boot image are not walked: the boot image holds them, or the loader refuses them at the stage Find.

**The memory.** The bytes of each file that the scan keeps are memory of the root service, paid by the one budget of all disk processes, as the process that imports them is. They stay mapped in the root service until the end of the load: the loader copies each module into the process, and the root service then frees them. A store that does not fit in that budget refuses the start with the status of the budget.

**The loader checks again.** The root service gives the loader each kept file with the hash of its bytes (`system.Source_File`). The loader checks the hash and the tables of each file, as it checks a file of the boot image. A file of the boot image wins over a file of the store with the same hash: the loader looks at the boot image first. The two have the same bytes anyway, as they have the same hash.

**What the log says.** One line when the scan starts, with the count of the hashes that it wants, and one line for each file that it keeps: the hash, the importer and the name of the entry. The name of the entry is a help for the reader only: it names no module, and a load error gives it as the name of the hash.

### The debug object

The debug object of a module file is an object of the same store, named by the 64 hexadecimal digits of the hash of the module. The debugger service reads it at an attach, through a connection that reads only and that the root service ties to the debug access. The design is [debug_object_of_a_disk_process.md](debug_object_of_a_disk_process.md).

### The order of the start

The storage service starts on demand, after the root service, as before. The root service starts no disk process during the start of the machine: the first one starts when a principal asks. So there is no cycle, and a machine with no data disk starts as before.

### How the file reaches the disk

Two ways: the network, on a machine that runs, or a disk that the tool writes.

**The network.** The module file service ([`docs/glossary/code.md`](../../../docs/glossary/code.md), "Module file service") is the module `module_files` of the boot image. Its private store is the store `module_files` of its principal: the root service names the private store of a process by the name of the process, and the store of the module files has the name `module_files`. So the service writes there with the grant `Store` that each process with a store has, and with no grant of a new kind. Its other grants: `Network`, a client grant of TCP to one web server (10.0.2.100 port 80, the address that QEMU gives to a server of the host), and `Serve`.

The console calls its two exports through a connection, as for each service (`connect("module_files")`):

- `module_files.receive(nickname, path)` sends `GET path` to the web server, takes a body of 1 to 4 MiB with a `Content-Length`, writes it as the object `nickname` of the root tree of the store, and gives the 64 hexadecimal digits of the BLAKE3 hash of the bytes that it received. The log says the same. The principal then types `start_from_disk(nickname, hash)`.
- `module_files.list()` gives one row for each object of the root tree but `grant_table` and the debug objects: its name, its bytes, and the BLAKE3 hash of its bytes, which the service reads again and computes. The service writes one line of the log for each row.

The hash that `receive` gives is a help for the principal, not a proof: the root service still reads the bytes and checks them against the hash of the command. A service that another party changed, or a web server that gave other bytes, can make the store hold any bytes under the nickname. It cannot make them run under a hash that they do not have.

The rules of the service:

- **A caller that acts for the principal of the store.** The root service gives the service the number of its principal in its context (`disk_process.SERVICE_VALUE_PRINCIPAL`). A caller that does not act for its principal, or whose principal is another, is refused: a service that writes for any caller is a confused deputy.
- **The nickname has the rules of a disk process** (`disk_process.name_problem`): `module_files` and `grant_table` are refused, so the service never writes over the disk grant table.
- **The path is one line of 1 to 200 bytes that starts with `/`**, with no space and no control byte: a request carries no second line that the caller wrote.
- **The bounds of a load.** The body has 1 to 4 MiB, the limit of the root service, and the whole call ends 30 seconds after it starts, the deadline of a load. A response with no `Content-Length`, a status that is not 200, or a connection that ends early writes nothing.
- **The store first, then the answer.** The object is written in ranges and made one commit; the hash goes back only after the commit.
- **One call at a time.** The service holds one file in memory, 4 MiB of its own budget.

**The tool.** The tool writes a data disk of the format of the storage service that holds the store `module_files` with its module files (`modustool` builds such a disk for the test part `disk_processes`). It prints the hash of each file. The module is a row of the module table of the tool that is not in the boot image.

The writer of the tool is checked by the open of the storage service: a host test opens the image with the code that the service uses, and compares each object byte for byte and each hash.

### The grants of a disk process

The principal gives a disk process a grant with a command. The rules of the table are in `src/library/modus/disk_process` (`grant_table.odin`), with no allocator and no kernel operation, so the host tests run each rule.

**The nickname.** The name of the entry of a file in the store `module_files` is its nickname: the principal chooses it, and the file never does. The root service names the process by its nickname (the slot, the log, `grants`, `stop`, the monitor), and the log writes the hash of the file beside it.

**The disk grant table.** The root service keeps one disk grant table for each principal ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Disk grant table"). A row binds a nickname to the hash of one file, and holds the grants of that file. 16 rows at most. It is apart from the table of the start grant sets by name of the root service (`start_grant_sets`), which a disk process never reaches.

**Two hashes never share a nickname.** The rule holds in the root service, at `start_from_disk`, and not in the storage service:

- The storage service is a transport. Each process with a grant of the store `module_files` can write a new object under a name, and the store has one object for each name anyway. A rule in the store holds only as long as the store is honest.
- The root service computes the hash of the bytes before a start. It compares the hash with the row of the nickname: a row with another hash refuses the start before any read, with the two hashes in the sentence.
- A nickname with no row gets no grant. So a file under it gains nothing, and the root service does not refuse it.

`start_from_disk(nickname, "")` takes the hash from the row of the nickname. The hash is still the identity: the bytes are checked against it, and the log writes it.

One file can have two nicknames. Each nickname has its own row, its own grants and its own store: a grant names the file and the nickname together.

**What a grant names.** `allow(nickname, grant)` and `disallow(nickname, grant)` write the row of the hash that the nickname names now: the hash of its row, or, with no row, the hash of the disk process of that nickname that runs. A nickname with neither is refused: the root service knows a hash only from a row or from a check of the bytes. The caller acts for its principal (`acts_for_principal`, not revoked), and changes the table of that principal only. A grant takes effect at the next start of the process: the kernel gives the handles of a grant at the start. `revoke` ends a grant of a process that runs, as for each process.

**The store of a disk process.** The grant `store` gives an isolated store of its own, attached to the nickname, not to the hash. Its name is `disk-` and the nickname, with the ending of the principal (`disk-visitor`, `disk-visitor.principal.1`).

- The store of a hash: a new version of a module has another hash, and loses its data. Refused.
- The store of the nickname: an update is the principal pointing the nickname to a new hash, and the store follows. A file under another nickname gets a new, empty store. No file chooses its store.
- The prefix `disk-` keeps the stores of the disk processes apart from the stores of the boot image: the name of a module has no byte `-`. A nickname with a store has letters, digits, `-` and `_` only, so it cannot build the ending `.history` or `.principal.N` of another store.
- A name of a store has 31 bytes at most. A nickname whose store name does not fit is refused at `allow`, not cut.

The size of the store is a line of the budget that the module asks for (`src/md/features/module_budget_request.md`). The request of that budget has no part for the store yet: the store has the default limit of a store, 64 blocks.

**The update.** `nickname_move(nickname, hash)` points the nickname to another file. Its grants and its store follow. Before the change, the log says "root: the file <hash> will get the data of <nickname>". A process of the nickname that runs keeps the grants of its start.

**The nickname in the windows.** The monitor and the menu of the windows show a disk process by its nickname, with the hash prefix of its file faded beside it ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Hash prefix"): on the same line in the menu, on the line under the nickname in the monitor, whose column of names holds a nickname and no more. A reader then sees which file runs under a name. The nickname and the hash come from the root service, the one party that checked the bytes, on two paths that exist already:

- **The menu of the windows.** The root service tells the compositor of each new window in the record `Client_Add` of the control ring between them. For a disk process the record also holds the nickname (values 1 to 3) and the first 8 bytes of the hash (value 4). The compositor names the window by that nickname: in the menu, in the title bar and in the palette. The title that the process sends with its surface is not read: the window of a disk process cannot have the title `console`. The menu and the palette show the hash prefix after the nickname, the palette for the window and for its close: a nickname that looks like the name of a process of the system (`consoIe`, `console_`) passes the rule of the names, and the prefix tells it apart.
- **The monitor.** The root service writes the disk process page ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Disk process page"): one page with one row for each disk process that runs, its process slot, its process serial, its nickname and its whole hash. It maps the page read-only, at its fixed range, into each process that it starts with the right Inspect of the machine, as it maps the date page. The monitor reads the process slot and the process serial of each process from the kernel, as before, and the row of the page with the same two numbers gives it the nickname and the hash.

**The hash in the exports of the monitor.** `monitor.processes()` gives what the window shows, so the console and the host read it as a table. A row of a disk process has its nickname from the page in the field `name`, and the whole hash of its file, 64 hexadecimal digits, in the field `hash`. A row of any other process has an empty `hash`. The match is the match of the window: the process slot and the process serial. So a row has a hash only when the root service started that process from a disk.

- The whole hash, not the hash prefix: the prefix is a help for a narrow window, and a reader of a table filters, joins and compares. The rows of `manual.running()` and `manual.modules()` give the whole hash in a field `hash` of 64 bytes too, so `join` matches a disk process with its module by the hash.
- The nickname in the field `name`: the kernel name of a disk process is its nickname already, as the root service gives it at the start. The page is the source that the root service states, as for the window, and a second field would hold the same text. The empty `hash` is what tells a process of the system that has the same name.
- No version of the record. A new field changes its description, and the console and the host read each table by its description and its field names. No field kept its place with another meaning.

The root service learns the process slot and the process serial of the process that it started from `Process_State`, which gives them as its results 5 and 6 (the reference of the operation in `src/library/modus/contract/operation`). A process handle with the right Read already gives the state of that one process; its place in the table of the kernel is a fact of the same process.

**A disk process has no child.** Its budget holds one process, its own slot (`disk_process.LARGEST_BUDGET`, whatever its file asks for). The process itself takes that one process of its budget at its start, and a budget that it makes takes from the same amounts, so `Process_Create` refuses each child with `No_Budget`. Each process from a disk is then a process that the root service started, with a row of the page. A child could take any kernel name, `console` too, and the monitor would show that name with no hash, as it shows the real console. A disk process that needs a child needs a mark of a name that the root service did not give first.

The page is a fact that the root service states, not a grant: it gives no handle and no right to act. A holder of the right Inspect already reads the name, the process slot and the module records of each process; the page adds which of them the root service started from a disk, and the hash that it checked.

**The grants that no command gives.** A disk process never gets the ring of the root service (`root_ring`, `connect`, `principals`, `debugger`), a right over the machine or a device (`inspect`, `stop`, `schedule`, `events`, `data_disk`, `scratch_disk`, `network_device`, `settings`, `clock`, `replace`, `system_part`), or the right to act for the principal: each one is the whole machine, or the principal. The root service refuses each one with a sentence that says it. The other grants are not built: a command gives `store` only. The table of principal 0 also holds the chosen start policy, as one row whose one disk grant is `Start_Policy`; no grant command gives it, and that row takes no `store` ([start_policy.md](start_policy.md), "A start policy from the disk").

**How long a grant lasts.** A persisted table is the object `grant_table` of the store `module_files` of its principal, next to the module files that it grants. It has a tag of keyed BLAKE2b (32 bytes) under a key that a passphrase gives. A reader of the disk who has no passphrase then cannot add a grant: a table whose tag fails is refused with a line of the log, and gives no grant. The persistence is a setting in the table: global, with an exception for each row (`disk_persistence`). The default is to persist.

The table also holds the client keys of `remote` that its principal allowed, 4 at most, after the rows and under the same tag ([remote_client_keys.md](remote_client_keys.md)). They follow the global setting, with no exception of their own. So the read, the write, the states and the refusals of this section hold for them too, with one difference: a revocation of a key is never refused, as it ends a grant at once. Such a revocation starts the writes of an unwritten table again, and a revocation before a read of the run is taken out of the table that the read gives.

A table of 1008 bytes is a table of the format 1, which had no client keys: the read refuses it as an older format that this system does not read, and the refusal of a change does not ask for a restore, as no version of it verifies.

The name `grant_table` is kept, as the name `module_files` is: no disk process has it, so the table is never read as a module file and never written over one.

**Principal 0 and the machine passphrase.** Principal 0 is the machine, and a passphrase for it is optional ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Machine passphrase"):

- **No machine passphrase.** No key signs the table of principal 0: it lasts until the machine stops. Its data stays: the store of a nickname is on the disk, and the next grant of `store` finds it.
- **A machine key sealed by the TPM** (`machine_seal()`). The TPM releases the machine key at each start of the same system, with no typing, and the table of principal 0 is read and written as with a machine passphrase. A changed system asks for the recovery key ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md)).
- **A machine passphrase.** The table of principal 0 is read after the passphrase is typed at the start, and written after each change.

The record of the machine passphrase is the object `machine` of the store of `unlock` (a store of principal 0), beside the file of a named principal. It holds the salt of Argon2id, with the parameters of a named principal, and the machine key sealed with ChaCha20-Poly1305 under the key that Argon2id derives ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Machine key"). The machine key is 32 random bytes. A wrong passphrase does not open the seal, so it never gives a wrong key that would write a table no one can read.

**Who holds which key.** `unlock` derives the key of the seal, opens the machine key, and derives from it the key of the tag: keyed BLAKE2b of the machine key over the text `modus disk grant table` (`disk_process.table_key_of_machine_key`). It gives the root service the key of the tag only, in one record of its ring (`Machine_Key`), erases the other keys, and stops. The root service holds the key of the tag in its own memory until the machine stops. So the process that writes the table holds no key that opens the seal or that could sign another thing; the machine key stays a key that the TPM can seal later, with its other uses outside the root service.

**Where the passphrase is set.** `machine_passphrase()` in the console asks the root service (`Machine_Passphrase`), which starts `unlock` in a mode of its own. The window asks for the passphrase two times; it is never a text of the console or of the log, as for a named principal. A machine with a passphrase refuses a second one: a change and a removal are not built.

**The three states of the record.** `unlock` reads the record `machine` as absent, present, or unreadable (a read error of the store, or a record that does not decode). Only an absent record lets a new passphrase be set: an unreadable record can hold a good machine key, and a new record over it would lose that key and, with it, the table. An unreadable record gives no key: `unlock` tells the root service (`Machine_Key`, "unreadable"), which refuses each change of the table of principal 0 and `machine_passphrase()`, each with a sentence.

**One record in a run.** `unlock` writes the record before it gives the key. After the write it never writes a second record in the same run: when the root service does not answer the key in time, `unlock` stops with a line of the log. A root service that took the key late then holds the key of the record on the disk, and the passphrase opens that record at the next start.

**At the start.** The root service starts `unlock`, and tells it whether the root service holds the key already (after a lock it does). `unlock` reads the record of the machine; with a record and no key held, it tells the root service (`Machine_Key`, "awaited") and asks for the machine passphrase before the passphrase of a named principal. Until the passphrase is typed:

- the machine runs, and each other ring is served: the root service waits for nothing;
- the table of principal 0 holds no row, so a disk process of principal 0 starts with no grant;
- a change of the table of principal 0 is refused with a sentence that says to type the passphrase: a change made then would be lost at the read.

Enter with no passphrase skips it: the disk grants of principal 0 stay absent until `unlock` asks again, at the next start of the machine or after a lock.

**The read and the write.** A key always comes with a read, before any write, so no write loses a table that the key signed:

1. The key arrives with its origin: the open of an existing record, or a new passphrase on a machine with no record (`Machine_Key`, "opened" or "new"). The root service reads `grant_table`.
2. A table whose tag verifies becomes the table of principal 0. An absent table gives no row, and the root service writes its own table there.
3. A table that is refused (its tag, or a field) gives no grant, and its line is on the log. What follows depends on the origin of the key (`disk_process.table_read_decision`):
   - **An opened key.** The table is kept: nothing is written over it, and each change of the table of principal 0 is refused with a sentence until the machine starts again. Such a table can be a good table of an older machine key, or one that a byte changed; a write over it would lose its grants with no sign. The way out today is a version of the table that verifies: a caller that acts for principal 0 restores it in the store `module_files`, and the next start reads it. A change of the machine passphrase is the other way out, and it is not built.
   - **A new key.** No record existed before this passphrase, so no key of a record signed that table. It is written over with the table of this machine, which holds the rows made before the passphrase.
4. Each later change writes the table again. A change during a write marks one more write after it.

The read and the write are states of the loop of the root service, as the load of a module file is: one call of the storage service at a time, through a connection of its own to the store `module_files`, with the deadline of a load. A storage service that stops, or that gives no answer, ends the call with a line of the log. A read that ends so leaves the table unread: changes stay refused, as the root service does not know what the disk holds.

**A write that fails is tried again at once, 3 tries at most.** A `disallow` whose write does not reach the disk would give the grant back at the next start, so the retry cannot wait for a later change. The retry, and not a completion held until the write ends, fits the loop of the root service: each command is answered in the pass that reads it, and one write carries every change that came during it (a held completion would need a queue of completions for each write). Each try has the deadline of a load, so the tries end in a bound. After the third failure the table is unwritten: the log says that the disk keeps an older table and that a grant taken since can come back at the next start, and each change is refused until the machine starts again.

**A named principal.** Its table is persisted with the same read, the same write, the same states and the same refusals as the table of principal 0. Three parts differ: who changes it, its key, and when the key comes.

**Who sends `allow` for a named principal.** A process of the session of that principal that acts for its principal: a console that the desktop starts while the session runs. The root service already records the session of each process at its start (the desktop starts a process in the session that runs), and the grant `acts_for_principal` already acts for the principal of the own session of its holder only ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "5. The session"). So the commands `Disk_Grant`, `Nickname_Move` and `Disk_Grant_Persistence` need no change, and no process gets a new grant. That console is no confused deputy: the principal that it acts for is a fact of its start, that the root service wrote, and not a value that a caller names. The console of the machine still acts for principal 0 only, and a console of the session never acts for principal 0.

**Where the table is.** The object `grant_table` of the store `module_files` of the principal (`module_files.principal.1`), next to the module files of that principal that it grants, as for principal 0.

**The key.** `unlock` derives the key of the tag from the secret unlock key of the principal (X25519, the key that unlocks the documents of the principal): keyed BLAKE2b over the text `modus disk grant table of a named principal` (`disk_process.table_key_of_principal_key`). It gives the key in the record `Principal_Unlock` that starts the session (values 0 to 3, and its origin in value 5), then erases the secret keys. The root service takes the key before the session starts, and writes zeros over the slot of the ring, as for `Machine_Key`.

- The origin is "new" at the creation of the principal: no record of this principal signed a table in its store, so a table that does not verify is written over. Any other unlock gives "opened": such a table is refused and kept, as for principal 0.
- The root service checks the origin "new" itself: it takes it only for a principal whose record a creation made in this run (`Principal_Record` while `unlock` creates). Else it refuses the unlock. So the one rule that lets a table be written over holds in the root service, not in the code of `unlock` alone.
- Each principal has its own unlock key, so a table of one principal does not verify in the store of another, and never under the machine key: the text differs too. The number of the principal is not in the tagged bytes: the key already binds the table to its principal.
- **The rule for each use of the unlock key.** The secret unlock key is never used as it is, outside the derivation of the public key. Each use derives its own key from it by keyed BLAKE2b over a text of its own, which no other use has: the tag of the disk grant table is the first such use, and the encryption of the stores of the principal will be another. Keyed BLAKE2b is a pseudorandom function, so a derived key reveals nothing of the unlock key or of another derived key.
- The root service keeps the key until the machine stops. A lock does not erase it: a write that runs at the lock, or a change that joins it, still needs the key. After a lock, `unlock` gives the key again; a key that differs from the first one refuses the unlock.

**When the table is read.** At the first unlock of the run, with the start of the session. No process of the session runs before it, so no change comes before the key. A read that failed starts again at the next unlock, when its key equals the first one: no write ran since the failure, so the origin of the first key still holds. While the read runs, a change is refused, as for principal 0. While the session is locked, a change is refused: a record of a process that the lock stopped can still be in its ring.

## Refused forms

- **The command gives a name only, and the entry gives the hash.** The storage service then chooses what runs. The check of the root service would compare the bytes with a hash that the same party gave: it finds damage, not a changed file.
- **The name of the entry is the hash, and the process has no name.** A reader of the tree then sees 64 digits for each process. The commands `stop`, `grants` and `revoke` name a process by a name.
- **The file states the grants that it asks for.** A file then grants itself. In the model of the storage, a package states the grants that it asks for and a principal grants them ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model"): the statement is data for the principal, never a grant.
- **The storage service starts the process.** It would need the right to create a process with a window and a log. Then two processes create access.
- **The root service reads the disk.** It would hold the block ring and the code of the format. The storage service is the one client of the data disk.
- **The console reads the bytes and gives them to the root service.** It needs a second path for the bytes, a memory object that the console lends, and a load from memory beside the load from the store. The console has no grant of the network either. The module file service puts the bytes in the store, so the one load of the root service stays the one path.
- **The console fetches the file.** The console would need the grant `Network`, and the console already holds the most grants of the machine. The module file service holds the one remote and the one store, and nothing else.
- **The root service fetches the file.** The root service would hold TCP and HTTP, the code that reads the most hostile input of the machine.
- **The console writes the store `module_files` through `open_store`.** A place of another store reads, restores and clones only. A write there for each caller that acts for the principal lets that caller write each store of the principal, the stores of `notes` and of `unlock` too.
- **A start grant of a new kind for the store `module_files`.** The store of a process already has the name of the process; the name `module_files` gives the store with the grant `Store` of each process, and a new kind of grant adds a case to each table of the grants.
- **The service starts the process after the write.** Two processes would then start processes, and the service would need the root ring.
- **The hash of the list read from the entry.** The entry of an object holds the hash of the object, which differs from the BLAKE3 hash of its bytes when the object has a hole ("Subtle points", below).
- **A call that waits in the loop of the root service.** One storage service that does not answer stops every command of the machine.
- **A deadline for each answer in place of one for the load.** The bound is then the deadline times the count of the calls. One deadline is one number to state.
- **The table of prepared modules for a disk process.** The budget of the root service would hold the code of a process that has no row.
- **A kernel operation that loads from a store.** The kernel has no file system and no loader for imports.
- **The store refuses an entry whose name another hash has.** The storage service is a transport, and a rule that it holds is a rule of a party that the root service does not trust. The root service checks the hash anyway.
- **A row of the table is made at the first start of a nickname.** A row with no grant protects nothing, and fills a table of 16 rows.
- **`allow` on a nickname with no row and no process that runs, with a read of the bytes.** It needs a second load from the disk for a command that changes a table. The principal starts the process by its hash first.
- **A table of principal 0 on the disk, with no tag or a tag under a key that the disk holds.** A reader of the disk could then add a grant.
- **The key of the tag from the passphrase alone, with no sealed key.** A wrong passphrase then gives a wrong key with no sign of it: the read refuses the table, and the next write signs a table under the wrong key. The seal tells a wrong passphrase at once. It also gives the TPM one random key to seal later, with no change of the table.
- **`unlock` gives the root service the machine key, or the key of the seal.** The root service would then hold a key that opens the record, or that signs what is not a table. It needs the tag only.
- **`unlock` stays, and tags each table for the root service.** A process with the passphrase would run for the whole session, and each change would wait for a second process.
- **The table in the store of the root service, or of `unlock`.** The table grants the files of the store `module_files`, and the root service already reads that store. A second store adds a name to reserve and a second limit, for no gain: the tag protects the table in any store.
- **The root service waits at the start for the passphrase.** A machine whose passphrase nobody types would not start. The read is a state of the loop, so the start never waits.
- **A change before the read, merged with the table read.** Two tables with a row of one nickname need a rule of which wins. The change is refused until the read, with a sentence that says why.
- **The machine passphrase as a line of the console.** The console keeps each line in its history and in its store.
- **A table that does not verify is written over after any key.** The rule is that such a table is refused. Under an opened key it can be a good table of another key, and the write would lose it with only a line of the log.
- **A record that cannot be read is taken as no record.** A read error or one changed byte would then let a new passphrase replace a good machine key.
- **The completion of a change held until its write ends.** It needs a queue of completions for each write, as a change during a write joins the next write; a bounded retry gives the same result in the loop.
- **The console acts for the named principal of the session.** The console acts for its own session only; a console that acts for another principal is a confused deputy. A second console that the desktop starts in the session of the named principal belongs to that session: it is the caller that acts for that principal.
- **A process of its own that sends `allow` for a named principal, or a mode of `unlock` that does.** The console of the session already holds the grant to act for its principal, and the commands already change the table of the principal of the caller. A new process adds a grant to give and to review, for no gain.
- **A random key for the table, sealed in the file of the principal.** It changes the format of the file and needs a second seal. The sealed unlock key is already a random key that only the passphrase opens; a key derived from it over its own text reveals nothing of it.
- **The key from the signing key.** The signing key signs grants of the principal for other principals. The unlock key is the key of the data of the principal, and the table is data of the principal.
- **A command of its own for the key of a named principal.** The key comes with `Principal_Unlock`, so no session starts without its key, and no key comes for a session that did not start.
- **The key erased at the lock.** A write that runs at the lock, or a change that joins it, would have no key; the next unlock would read the table again, and lose each row that lasts until the machine stops. A reader of the memory of the root service holds each grant of the machine anyway.
- **The number of the principal in the tagged bytes.** The key of each principal differs already; the number would change the format for no gain.
- **An import by name.** The import table names a hash; a name of an entry is chosen by whoever writes the store. An import found by the name `store_library` would run the bytes that the store holds under that name, with no check against the identity that the importer was built with.
- **The name of the entry as a guess, then the check of the hash.** It finds a file only when the developer kept the name of the module as the nickname, and a refusal then says nothing of the other files. The scan finds the file under any nickname, and costs at most the 16 MiB of the store.
- **The storage service resolves a hash.** The storage service is a transport that the root service does not trust. An index of hashes in it would choose which bytes the root service reads; the hash of its entry is not even the BLAKE3 hash of the bytes when the object has a hole. The root service would still read and check the bytes, so the index gains nothing but speed, and adds an export that each store pays.
- **The root service trusts the hash of an entry, or a list of `module_files.list`.** Both come from processes that the root service does not trust, and the hash of an entry differs from the hash of the bytes after a hole. A hint that is false only costs a read, but a hint that is true is never needed: the scan reads the bytes anyway.
- **An index of the hashes in the root service, kept across loads.** It saves the reads of a second load, by the generation of each entry. It is a cache with its own rules of change, for a cost that the store bounds at 16 MiB. Left for when a measure asks for it.
- **The module file service gives the imports to the root service.** It would be a second path of bytes into the root service, beside the one load.
- **The bytes of an import in the budget of the root service.** The budget of the root service pays for the processes of the boot image; a store that a principal fills must not take from it. The budget of all disk processes pays for the process and its imports.
- **A loader that reads the store itself.** The loader is a library with no connection and no state of a loop: it would wait for the storage service inside the loop of the root service.
- **The hash from the module record of the process.** The loader of the root service writes the module record of the first module, and the kernel keeps the process from a change of it ([module_record_writer.md](module_record_writer.md)). That makes the record true, but not the name: a disk process that may start a child names it as it likes, and gives it any module record. The monitor would then show a hash of the root service beside a process that the root service never started.
- **The title of the window, with the hash added by the compositor.** The process chooses its title, and the compositor knows no hash. The nickname must come from the party that checked the bytes.
- **A connection from the monitor to the root service, or to the compositor.** The monitor would get a ring and a command of a new kind: a new right, for a fact that one page states. The compositor learns the nickname from the record that it receives anyway.
- **The disk process page for the compositor too.** The compositor knows a window by the handle of its ring, not by the process slot: it has nothing to match a row of the page with. The record `Client_Add` is the moment the window starts, from the same party.
- **The page matched by the name of the process.** A process of the boot image that starts children (`errors` starts `fault`) names them as it likes, and a later process with a child would too; a match by name would give such a child the hash of a disk process. The process slot and the process serial name one process.
- **The budget of a disk process from its file alone, with children.** A child of a disk process takes any kernel name, and nothing in the monitor tells it from a process of the system. One process in the budget closes that until a mark exists.
- **The root service finds the process slot by a search of the reports of the kernel.** Another process can create a process with the same name at the same time, and a process can stop at once. The process handle names one process with no search.
- **The whole hash in the menu.** 64 digits do not fit a line of the menu beside a nickname. The hash prefix is a help to recognize a file; the lines of the root service and of the monitor on the log give the whole hash.
- **The hash prefix in the exports of the monitor.** 16 digits identify no file: a reader of the table checks the hash of a file, and joins it with the rows of the manual, which give 64 digits.
- **A field `nickname` beside the name.** The kernel name of a disk process is its nickname; two fields would hold one text, and a reader would have to choose. The field `hash` alone says which rows the root service started from a disk.
- **The page for each process.** A process with no right Inspect does not see the other processes; the page would tell it which processes run from a disk.

## Subtle points

- **The hash is computed on the bytes, not read from the entry.** The entry of an object holds the hash of the object, which differs from the BLAKE3 hash of its bytes when the object has a hole before its last block ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "The hash of an object"). The root service reads the bytes, so the hash of a module stays the BLAKE3 hash of its file.
- **A length from the storage service is copied, then checked.** The size is read one time. Each count of bytes is compared with what is left before a copy.
- **The name of the caller of the connection is `module_files`.** The root service is no row of its own table of started processes, so the connection has a caller record of its own. Its grant is the limit of the store, with no grant to act for a principal.
- **The connection ends with the load.** The root service holds no handle of the storage service between two loads.
- **The rule of the debug access needs no change.** It reads the grants that a process received at its start. A disk process with no grant can be debugged by a caller that acts for its principal. A disk process with the grant `store` cannot: a store is a grant of one process.
- **The root service finds a disk process by a flag of its slot, not by its name.** The connection of a disk process to the storage service gets the store of its nickname and the limit of that store, from the grants of its start, and never the grants that `start_grant_sets` gives a name.
- **A move does not change a process that runs.** It keeps its grants and its connections. The next start reads the row again.
- **A read makes no commit.** The storage service writes the limit of a store at a change only. A machine whose disk has no store `module_files` gets no new store from a refused command.
- **The tag does not stop an older table.** The storage service keeps the versions of `grant_table`, and a caller that acts for the principal of the table can restore one in its store `module_files`. The tag of an older version verifies: a grant that `disallow` took can come back. A counter that only grows, in the TPM, ends it; it is not built.
- **The key passes through the ring of `unlock`.** The ring is memory of the root service that only `unlock` maps, and the root service closes it when `unlock` stops. `unlock` erases its own copies of the keys. The root service writes zeros over the record in the ring and over its local copy after it takes the key; the copy of the record in its loop is overwritten by the next record. A refusal of `Machine_Key` or of `Principal_Unlock` puts no value of the record in its answer, and the record of the general refusal is never built from their values, which hold a key where a name would be.
- **The store `module_files` has three writers.** The module file service writes the module files, the root service writes `grant_table`, and a caller that acts for the principal restores a version. The storage service keeps the pending changes of each connection apart, and each commit is one commit of the store. The limit of the store is one constant for each of them (`disk_process.STORE_BLOCKS_LIMIT`).
- **A block of zero bytes in a module file is a hole.** The service writes the file in ranges; the storage service keeps a block of zero bytes as a hole, and the hash of the entry then differs from the BLAKE3 hash of the file. The list and the root service compute the hash on the bytes, so a file with a page of zero bytes still has its own hash.
- **The service is no row of the disk grant table, and the store is no grant of a disk process.** A disk process never reaches the store `module_files`: the store of a nickname has the prefix `disk-`.
- **A file is checked two times.** The root service computes the hash when it reads the bytes, and the loader computes it again when it takes the file. The second check costs one hash of each file; it keeps one rule in the loader for each file of each load source.
- **An entry read two times can give other bytes.** A file of the module file service can change the entry between two reads. The second read then gives another hash, which is noted, and the entry is not kept. The bound of the reads ends the scan.
- **The name of an entry is not the name of a module.** A load error and a line of the log give the name of the entry beside a hash of the store, so that a reader finds the file. A replacement and a grant never read it.
- **A disk process with no import outside the boot image makes no scan.** Its load is as before: the size, the bytes, the check.
- **Two tables can have a call at the same time.** Each principal has its own connection to the storage service for its table, and its own state of the loop: a read of the table of a named principal does not wait for a write of the table of principal 0.
- **The connection of a table names the store of its principal.** Its caller record has the name `module_files` and the number of the principal, so the storage service gives the store `module_files.principal.1` by the one rule of the names of the stores.
- **The hash prefix is a help, not an identity.** It holds 64 bits of the hash: a party that wants a file with the prefix of another file must try about 2^64 files. The identity of a start stays the whole hash of the command, which the root service checks.
- **The page has one writer and many readers, and the writer never reads it.** The root service makes a change count odd, writes a row, then makes it even, as the process `date` writes the date page. A reader copies the rows while the count stays even and the same, a bounded count of times; a page that changes at each try gives no row in that picture, and the reader never waits for the root service.
- **A row lives as long as the slot of the root service.** The row of a disk process is the place of its slot in the table of the started processes; the root service clears it when it releases the slot. The kernel keeps the process slot of a stopped process until its last handle closes, and the root service closes that handle in the same release, so a row never names the slot of another process. The process serial guards the case where a reader read the row before the clear.
- **A start has 12 mappings, and the worst start uses 11.** The storage file, the date page, the debug image, the disk process page, the settings page with 5 glyph caches, and the file of a service. The disk process page comes before the settings page and the glyph caches; a mapping that does not fit is dropped with one line of the log ("root: no room for ... in the mappings of a start"), never in silence, so the next mapping that fills the list shows at its first start.
- **The compositor names the window by the nickname from its first record.** `Client_Add` comes before the process runs, so the process has no window under another name before it.
- **A grant made between the start and the report of `unlock`.** The root service learns that the machine has a passphrase only when `unlock` read its store. A change made before is in the table in memory, and the read replaces it; the line of the read counts the rows that it replaced.

## Built and left

Built: the command `Start_From_Disk` of the root ring and the command `start_from_disk` of the console; the load as a state of the loop of the root service, with its four bounds; the check of the hash; the least right, with the rule of the names; the disk of the tool with the store `module_files`; the test part `disk_processes`. The disk grant table: the nickname rule, `allow`, `disallow` and `nickname_move` (the commands `Disk_Grant` and `Nickname_Move` of the root ring), the grant `store` with the store of the nickname, and the format of the persisted table with its tag. The machine passphrase: its record in the store of `unlock`, `machine_passphrase()`, the ask at the start, the key of the tag in the root service, the read and the write of the table of principal 0, and the setting of persistence (`disk_persistence`). The table of a named principal: its key from the unlock key, given with `Principal_Unlock`, its read at the first unlock, its write after each change from a console of its session, and the test of a grant that comes back after a restart and an unlock. The module file service: `module_files.receive`, a file from a web server into the store, and `module_files.list`, the files with the hash of their bytes. The imports from the store: the import scan as three states of the load, its bounds, the files beside the boot image in the load source, and the test of a process that calls a library module of the store, then is refused when the file of the library has other bytes. The nickname in the windows: the nickname and the hash prefix in the record `Client_Add`, the window named by its nickname, the hash prefix in the menu of the windows and in the palette, the line of the log of a dropped mapping, the disk process page in each process with the right Inspect, the process slot and the process serial from `Process_State`, and the test of the menu and of the monitor with a disk process that has a window. The whole hash of a disk process in the field `hash` of `monitor.processes()`, with the test of its row in the console.

Left:

- **The TPM and the machine passphrase together.** `machine_seal()` gives a machine with no passphrase a machine key that the TPM releases to the measured system, with a recovery key ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md)). With a passphrase, the TPM and the passphrase together open it; that form is left.
- **A change and a removal of the machine passphrase.** A change seals the same machine key under a new passphrase, so the table stays valid.
- **An older table.** A counter that only grows, in the TPM, so that a restored version of the table is refused. It matters most for a client key of `remote` that a principal revoked, such as the key of a stolen device: a restore brings it back (`ROADMAP.md`, "A disk grant table that a restore cannot roll back").
- **A second ask after a skip.** A command that asks for the machine passphrase again, with no restart and no lock.
- **A second read after a failed read, and a write after a failed write.** For principal 0 both wait for the next start of the machine; for a named principal a failed read starts again at its next unlock, and a failed write waits for the next start of the machine.
- **A store size from the module.** The size of the store of a nickname from the budget that the module asks for, by a policy that the principal sets.
- **The hash prefix in the title bar.** The title bar of the window of a disk process has its nickname and no hash prefix: the title bar of a small window has no room for both. The menu of the windows and the palette show the prefix.
- **A mark of a name that the root service did not give.** A child of a process, in the monitor, with a mark that says that the root service did not name it. A disk process with a child needs it first.
- **A cache of the import scan.** The hash of each entry, kept in the root service by the generation of the entry, so that a second load reads only the entries that changed. It needs a measure that shows the cost of the scan first.
- **Another web server.** The grant of the module file service names one remote. A remote that the principal chooses is a grant that the principal gives, as the grant of a client of `remote` is.
- **The module file service for a named principal.** The root service starts the service on demand for principal 0, so it serves the store `module_files` of principal 0 only, and refuses a console of a named session. A named principal needs a start of the service in its session.
- **A file from another store.** A copy of an object of another store of the principal into the store `module_files`, with no network.
- **A service from a disk.** A disk process has no service ring, so no process connects to it.
