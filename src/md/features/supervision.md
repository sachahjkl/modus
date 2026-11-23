# Supervision: a stopped holder starts again from its store

A service of the system can stop: a fault, a broken invariant, a device that stops to answer. Today most stops are final for the run of the machine: a row of the start list starts again only within its count, a connection to the stopped service is lost, and a client has no rule for the calls that it had in flight. This file designs supervision: the starter of a process starts it again when it stops, the process takes its state back from its private store, and each client keeps its connection and sends again the calls that had no answer.

The model is the one that Erlang found: an actor is isolated, a crashed actor starts again clean, and its state comes from a place that the crash did not reach. modus takes the model and adds no runtime for it. In modus the actor is already a process: its own address space, typed records on rings, and no shared state but what a handle gives. So supervision is a few rules over three things that exist: the stop of a process with its stop cause and its stop outcome ([../api/process_stop.md](../api/process_stop.md)), the end words of a stream ([module_outputs.md](module_outputs.md)), and the private store with its atomic change ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process"). It is not a framework.

## The constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": each change is one commit, on the disk when the call returns. The state that must outlive a process is in its store already.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", and "20. No ambient access: the other holes to close": a restart gives no new access. A process that starts again gets the grants of its start grant set, and a client gets no new grant to reach it.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "4. Base interface: non-blocking command buffers", and "6. One communication mechanism between processes": no new kernel operation for a call, and no second way to signal a stop.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "16. Removed concepts": no signals, no init system with units. A start is asked for by a process.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": one mechanism for a restart, whoever the starter is.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable", and [roles_and_contracts.md](roles_and_contracts.md): a client holds a connection to a role, which the root service gives, and never discovers a holder. A restart changes the holder of a role and nothing that the client names.
- [../api/root_service_split.md](../api/root_service_split.md): the part of the system that nothing can restart must be small.
- **A test checks a condition, never a speed** ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). A restart rule that a test checks must give the same result on a slow and on a fast machine.

## The chosen form

### The ideas of the BEAM, mapped onto modus

The BEAM runs many light processes inside one process of the host, with a scheduler and a garbage collector of its own. modus runs each actor as a real process, with an address space that the hardware isolates and a budget that the kernel counts. The pattern of Erlang then costs nothing more: the isolation that the BEAM builds in software is there already.

| Idea of the BEAM | In modus | Taken? |
|---|---|---|
| Process isolation: a heap for each process, no shared memory | A process with its own address space, its own budget and its own handle table. A fault stops one process, and no fault of a library in another process reaches it, where a fault of a native function stops the whole BEAM | Taken, by the hardware |
| A monitor: a process learns that another stopped, and why | A process handle with the right Read: the stop is an event of a wait, and `Process_State` gives the stop cause and the stop outcome. On a stream, the end word `Writer_Stopped` or `Reader_Stopped` with the same two words. On a connection, the connection page (below) | Taken, with no new mechanism |
| A link: a stop kills the linked process | No mechanism. A process that cannot run with no provider reads the stop of the provider and stops itself with `Failed`. A dependency in the context of a process gives the same result through the restart group (below) | Refused as a kernel or library mechanism |
| The exit reason: `normal`, `shutdown`, another term | The stop outcome: `Done`, `Stopped_On_Request`, `Failed`, `Refused`, and the stop cause for a stop that the process did not choose | Taken. It is a closed enum, not a term |
| "Let it crash": no defensive code, a restart in place of a repair | A holder stops at a broken invariant of its own, and starts again from its store. A refusal of the input of a client is never a crash: it is an error record for that client | Taken, for the invariants of the holder only |
| The supervisor and its strategies `one_for_one`, `one_for_all`, `rest_for_one` | The starter of a process is the one that starts it again. One for one is the rule. One for all comes from the context of a process, as a restart group | Taken: one for one, and one for all by the context. `rest_for_one` is refused |
| The restart intensity: at most R restarts in T seconds | The restart bound of a start row: a count, and a restart window that is the whole run by default | Taken, with the whole run as the zero value |
| The restart types `permanent`, `transient`, `temporary` | A stop with `Done` or `Refused` starts no restart, which is `transient`. A row with a count of 0 is `temporary` | Taken, as rules of the start list that exist |
| The mailbox | A ring for each pair of processes and each concern: a call ring, a wiring ring, a class ring. A ring has a stated capacity: a full ring holds its writer or refuses with a count | Taken, bounded. The unbounded mailbox is refused |
| The selective receive: a scan of the mailbox for a pattern | Not needed. A process waits on all its rings with one `Word_Wait` and reads the ring that it chooses, so no record waits behind another of another concern | Refused |
| Hot code loading: two versions of a module, a switch at a qualified call | A replacement of a module ([../api/module_replacement.md](../api/module_replacement.md)) takes effect at the next load. A holder takes it at its next start, from its store | Taken, as a restart. A switch inside a running process is refused |
| Distribution: a process on another node is named as a local one | A remote client is a client of `remote`, with the key of a principal ([remote_client_keys.md](remote_client_keys.md)) | Out of the scope of this file |

### Who starts whom again: the start tree

The process that asked for the start of a process is its **starter**, and the starter is the one that starts it again. The tree of supervision is the tree of the starts, which exists. No second tree is declared.

- **The kernel** starts the root service. Nothing starts the root service again: it holds every grant, and its stop ends what it holds. The split of the root service makes this part small: the core keeps only the grants and the loop of its ring, and each delegated service is a process that the core starts again.
- **The core of the root service** starts again what it started by its own procedure: the delegated services, the services of the start before the start policy (the entropy service, the TPM service, and at step 4 the block service of the data disk, the storage service and `unlock` with no window), and each service that starts on demand at its first connection (`connection_open` in `src/modules/system/root/main.odin`). A service on demand starts again while a connection to it is held, and at the next `Connect` when none is.
- **The start policy** starts again the rows of its list ([start_policy.md](start_policy.md)). A part of the system that a start policy asked for (`input`, `compositor`) has the start policy as its starter, though the root service runs its start procedure.
- **Any process** that started a child, as the console does with `start`, is the starter of that child. It starts the child again with the same `Start`, or not: the library gives no automatic restart to a process that does not ask for it.

A starter learns of the stop of a child by the handle of the child, with the right Read. Today a start policy receives that handle with each `Start` ([start_policy.md](start_policy.md), "The start policy is a process with one start grant").

### The restart strategies

**One for one is the rule.** A stopped holder starts again alone. Its clients keep their connections (below), so no client stops with it.

**One for all comes from the context of a process.** A connection that a client gets after its start can be given to a new holder. A ring in a context slot of a process that the client cannot receive again is different: the block ring in the context of the storage service, which the root service makes for each start of the block service. When the provider of such a ring stops, the dependent cannot go on, so the starter stops the dependent and starts both again, the provider first. This set is the **restart group** of the provider. The root service derives it from the role table (`start_grant_sets`), the data that already says which context needs which service ([start_policy.md](start_policy.md), "What the root service keeps in code"). No list declares it.

**The input service restarts alone.** The input ring is in the context of the compositor too, but the root service makes it once for the whole run and keeps it (`input_memory` in `src/modules/system/root/main.odin`): each start of the input service maps that same ring, and `ring_open` maps the memory and changes no byte of it. The compositor keeps reading the one ring, at its own place, so a stop of the input service loses at most the records that it had not written yet, and its group is the input service alone. Its start row has restarts with a window ([start_policy.md](start_policy.md)).

The way to make a group smaller is to move a ring out of the context and into a connection that a new holder takes. Property 23 does this for each role: a client gets the connection to a role in a context slot or with `connect`, and either survives a restart of the holder under the rules below.

**`rest_for_one` is refused.** It needs an order of the children that means "each one after it depends on it". The start list is an order of the start, not a graph of the dependencies, and a second meaning of one order is a hidden rule. The restart group says the dependency where it is: in the role table.

### The restart bound

A start row keeps its count of restarts, at most 16. It gains one field: the **restart window**, in seconds of the clock of the system. The rule: past the count of restarts inside one window, the row starts no more, and the starter escalates (below).

- **The zero value is the whole run.** A row with no window counts its restarts for the whole run of the machine, which is the rule of today. So no clock decides the restarts of a row that names no window.
- **Only a row that names a window uses the clock.** [start_policy.md](start_policy.md) refuses a period of time as the only bound, "so no clock decides it", and that reason holds for each row that names no window. A machine that runs for months needs the window for a holder that the design wants to start again: with no window, a rare fault once a week spends the count, and the role then stays stopped. Example: `restarts = 5` and `restart_window = 60` give at most 5 restarts in each minute, as the restart intensity of Erlang.
- **A test checks the order, never the time.** A machine case gives a row a count of 2 and a window of the whole run, stops the holder three times, and checks the escalation after the third stop. A window shorter than the whole run is tested on the host, with the clock as an argument of the pure rule.
- **The bound of a start policy from the disk** stays in the root service, as today: 16 restarts of a name, with the same window field in the command `Start`.

### What a client sees when the holder of its role stops

A client holds a connection: a call ring and a call region that the root service made. Today the root service gives both memory objects and closes its own handles (`connect`, `src/modules/system/root/main.odin:1725`). A client also holds the process handle of the holder with the right Read, so a stop is an event in its wait.

**The connection outlives its holder.** The root service keeps its handles of the call ring and the call region for as long as the connection lasts. When a holder stops, the client keeps the same two memory objects mapped. When a new holder starts, the root service gives it the same two objects with `Connect` on its new service ring, with the flag `Again` and the serial of the connection. The client gets nothing new: no handle, no ring, no grant. So a client with no root ring survives a restart of its holder: it cannot receive new handles, and it needs none. The connection is the grant; a new holder takes over that grant.

**The connection page.** Each connection gets one page that the root service writes alone and that the client and the holder map with the right Read only, in the form of the end page of a wiring ([module_outputs.md](module_outputs.md), "The end words"). Its words:

1. the holder serial: the process serial of the holder that serves the connection now;
2. the connection state, a member of `Connection_State`: `Held = 1`, `Holder_Stopped = 2`, `Ended = 3`, and `None = 0`, which a page that the root service did not write yet holds;
3. the stop cause and the stop outcome of the last holder that stopped, 0 while the state is `Held`.

The client waits on the state word beside its call ring, in the same wait. One border of a contract package reads the page: it refuses a state that names no member, a stop word beside `Held`, and a reserved word that is not 0.

**The order of the words.**

1. The holder stops. At the reap, the root service writes the stop cause and the stop outcome, then `Holder_Stopped` with a release, and wakes the client.
2. The starter starts a new holder, or does not.
3. With a new holder, the root service gives it each connection of the role, then writes the new holder serial and `Held`, and wakes the client.
4. With no new holder (the bound is past, the stop was `Done` or `Refused`, or the starter itself stopped), the root service writes `Ended` and ends the connection. Each call that waits gets the library status `Ended`, with the stop cause and the stop outcome.

A page and a state are new mechanism, so they must be the smallest form. A second fact on the end page of a wiring was refused: "one end word for each end page, ever" is the rule that keeps a stream end true, and a connection changes its holder many times.

**The calls in flight.** The library keeps, for each connection, the tag of each call that it wrote and whose completion it did not read, with the holder serial at the time of the write. The call ring continues across the restart: the new holder copies its counters and checks them, as each side of a ring does. A call that the old holder did not take is still in the command queue, and the new holder serves it. A completion that the old holder wrote is valid, and the client reads it. A call that the old holder took and did not answer is **in doubt**: it ran, or it did not.

**The replay.** At the new holder serial, the library writes each call in doubt again, in its order, with the same arguments, which are still in the call region. A call in doubt is written again once only. If the holder stops again while the replayed call is in flight, the library gives that call to its caller with the status `Holder_Stopped`, and replays it no more. A call that a holder cannot survive then costs at most two restarts, and the restart bound sees the loop.

**What a caller sees.** A blocking call waits across the restart, within its own deadline, and returns the answer of the new holder. A caller that asked for no wait gets `Holder_Stopped` while the state says so. A call whose deadline passes during the stop gets `No_Answer`, and stays in doubt for the library: its replay can still run it, so the caller that set the deadline must treat it as one that ran or did not.

### The rule that makes a replay safe

A replay is safe when the second run of a call gives the effect and the answer of one run. Two forms give this, and the description of each export names its form. An export that names neither is never replayed: a call of it in doubt gets `Holder_Stopped`. That is the zero value, so an export that a developer did not mark is safe, and only less available.

- **An idempotent export.** A second run changes nothing more, and gives the same answer: a read, a `size`, a `list`, a `set_size` to one size. The description marks it with the attribute `idempotent`. The library replays it with no other step. The tool cannot prove the claim; the test of the role that stops the holder in each call checks it.
- **A request serial.** Each call of an export that is not idempotent carries a request serial: a number that the library gives, which grows by 1 on each connection. The holder writes the request serial and the completion record of the call in the same commit as its effect. At its start, the holder reads the serials that its store keeps for each connection. A call whose serial is at or below the kept serial is not run again: the holder gives the kept completion. A serial above it runs.

**How many serials a holder keeps.** The answers of each call that a client can still have in doubt: at most `REQUEST_SERIALS_IN_FLIGHT` for each connection, 8, a constant of the contract. The library holds a ninth call that is not idempotent until an answer frees a place, so the bound is a rule of the client, never a guess of the holder. A completion is 64 bytes, so 8 answers of 8 connections are 4 KiB.

**The answer of a replay has no bytes in the region.** A kept completion holds the kind and the seven values of the record. An export that is not idempotent gives its answer in those values: the generation of a commit, a count, a status. An export that writes a result into the call region must be idempotent. The tool checks the pair at each build: an export with a request serial and a Table or a Text result is refused.

**The connection serial.** The root service gives each connection a serial that no other connection takes in the run of the machine, and passes it with `Connect`. The holder keys the request serials by it. At `Disconnect` it removes them in its next commit. At the first start of a holder in a run of the machine, no connection is held, so it drops the whole table. A context value tells the holder whether this start is the first one of the run or a restart.

### How a holder writes its state: done means committed

A holder tells a client that a call is done only after the commit that holds its effect. This is the rule of the storage service already: "each change is one commit, so it is on the disk when the call returns" ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "4. The interface of the service"). Supervision makes it the rule of each holder of a role that keeps state.

- **The effect and the request serial in one commit.** A commit of the storage service changes one object. So a holder keeps the request serials of its connections in the same object as the state that the call changes. A holder whose call changes two objects at once needs a commit of several objects of one store, which the storage service does not have. Until it has it, such a holder keeps the two in one object.
- **The state in memory is a cache of the store.** A holder can keep any table in memory for speed. Each such table can be read again from the store, or rebuilt by its clients. A table that is neither is a loss at the next stop, and a fault of the design of that holder.
- **The connection state is rebuilt by the client.** Some state belongs to one connection and lives only while it lives: the places of a connection to the storage service, the surface of a window in the compositor. The holder does not write it to its store. The contract of the role names it and the calls that make it again, and the library of the client makes them again after the new holder serial, before the replay. Example: the library of the storage service keeps the path of each place that it opened, opens each again, and maps the old number to the new one.
- **The storage service is the end of the chain.** Its store is the data disk, and its start is the open of the disk (`storage_mount`), which the tool checks on the host against each image that a loss of power can leave ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "U5. Storage service"). Its request serials go in the store block of the store of each connection, which each commit of that store writes already.
- **A holder with no state starts clean.** A device service keeps nothing that outlives it. The block service ends each request in flight with `No_Answer` at its stop ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "4.9 A disk that stops to answer"). Today its block ring is in the context of the storage service, so the two are one restart group, and the storage service starts again from the disk. When the block ring becomes a connection that a new block service takes, the storage service keeps running and sends each request that got `No_Answer` again, as the file server of MINIX 3 does: a write of a block at a place is idempotent.

### A holder that stops in a loop, and the escalation

A holder that stops past its restart bound does not start again. Then:

1. Its starter writes one line that names the holder, the count and the window, and the stop cause and the stop outcome of the last stop.
2. The root service writes `Ended` on each connection of the role and ends it. Each client reads the end, and each call that waits gets `Ended`.
3. If the row has the mark `Needed`, the start policy stops with `Failed`. Its starter, the root service, stops each process that the start policy asked for and starts the rescue start policy, with its line. The rule is the same before and after `Machine_Usable`: the rows of a stopped policy never run on with no starter.
4. If the rescue start policy fails too, the boot display shows the cause, as today ([start_policy.md](start_policy.md), "No start policy at all").

A row that is not `Needed` stays stopped with its line, and the machine runs on with one role fewer, as for an absent part of the machine ([missing_hardware.md](missing_hardware.md)).

### The order of the start: what can depend on what

Each holder has a rank: the place of its start in the start tree. A holder depends on another only when the other has a lower rank:

1. the kernel;
2. the core of the root service;
3. the services of the start before the start policy: the entropy service, the TPM service, the block service of the data disk, the storage service, `unlock` with no window;
4. the delegated services of the root service;
5. the start policy;
6. the rows of the start list, in their order; a reader row of a wiring is before its writer row, as today.

The rules:

- **A holder needs only lower ranks to start again.** Its store, its context and the connections of its start come from lower ranks. So the restart of a holder never waits for one of its clients.
- **A holder never waits for a call to one of its clients.** A call from a lower rank to a higher one makes a cycle at the next restart: each waits for the other to start. The tool checks the role table for such a cycle at each build, as it checks the start list.
- **The storage service depends on the block service, and nothing else.** It is the store of every other holder, so it cannot be a client of one of them.
- **A dependency is a connection, never a name.** A holder reaches a lower rank only through a connection that the root service gave (property 23). A holder that looks up another by its name has no rank, and the check cannot see it.

### The prior art

- **Erlang/OTP supervisors** (Joe Armstrong, "Making reliable distributed systems in the presence of software errors", thesis, 2003; the `supervisor` behaviour of OTP). Taken: the isolated actor, a restart in place of a repair, one for one, one for all, a bound of restarts in a time, no restart after a normal exit. Refused: the virtual machine and its green processes, as modus has real processes; `rest_for_one`, as an order is not a dependency; the unbounded mailbox and the selective receive; the links as a kill signal; the exit reason as an open term.
- **systemd** (`Restart=on-failure`, `StartLimitBurst` and `StartLimitIntervalSec`, `BindsTo=`, and the file descriptor store, `FileDescriptorStoreMax=`). Taken: the bound of starts in an interval, and a service manager that keeps the descriptors of a service across its restart, which is the call ring that the root service keeps here. Refused: the unit files, their text and their dependency solver ([start_policy.md](start_policy.md), "The refused forms"), and the restart of a service whose clients find it again by a name on the bus.
- **Fuchsia component restart** (the component manager; a component with lazy startup starts again at the next request of one of its capabilities; `on_terminate: reboot` for a critical component). Taken: a service that starts again on demand, and capabilities that a parent routes, never a name that a client resolves. Refused: the end of each channel at the stop of its server, after which the client opens the capability again through its namespace: here the connection outlives its holder and the client opens nothing.
- **The reincarnation server of MINIX 3** (Herder, Bos, Gras, Homburg and Tanenbaum, "Failure resilience for device drivers", DSN 2007). Taken: the parent of the servers and drivers starts a driver again after its stop, a driver takes its state back from a store that its crash did not reach (the data store server there, the private store here), and the client of a driver (the file server) sends its requests in flight again. Refused: the heartbeat ping that declares a driver dead when it is late. A late holder on a loaded machine is not a dead one, and a test must not depend on the speed of the host.

## The refused forms

- **A virtual machine, green processes or a second runtime.** The BEAM puts many actors in one process of the host because a process of the host is heavy. A process of modus is the actor, with hardware isolation and a counted budget. A runtime above it adds a scheduler and a memory model that the kernel already has, and puts many actors in one fault domain again.
- **A supervision framework: behaviours, callbacks, a declared tree.** The tree is the start tree, the strategy is one for one or the restart group, the bound is two fields of a row. A framework is a second way to declare each of them.
- **New handles for a client after a restart.** A client with no root ring cannot receive them, and a client that can receive them needs a new grant for a role that it already holds.
- **A new connection that the client asks for with `connect`.** It needs a root ring in each client and makes each client a supervisor of its own connections. The root service already knows each connection of a role.
- **The end of the connection at the stop of the holder, as today.** Each client then writes its own logic of a reconnection, and a client of a context slot cannot reconnect at all.
- **Exactly once by the client alone.** A client cannot know whether a call in doubt ran: only the store of the holder knows it. The request serial puts the proof in the commit of the effect.
- **A request serial for each export.** An idempotent export needs no serial, and a serial costs the holder one write of 64 bytes in each commit.
- **A replay with no bound.** A call that stops its holder stops each new holder, and the restart bound then ends the role for every client because of one call. One replay costs one restart more, and the caller gets the status.
- **A heartbeat from the starter.** See the prior art, MINIX 3: a clock then decides what a test checks.
- **A switch of the code inside a running holder.** Two versions of a module in one address space, and the code that moves the state from one to the other, are the cost of hot code loading. The state is in the store, so a restart with the new module is the upgrade.
- **One for all as a field of the start list.** The rows that must restart together are the rows that share a context ring, which the role table already says. A field is a second statement of one fact, and the two can disagree.
- **A restart window as the only bound, with no whole-run default.** A clock then decides the restarts of every row, also of a row that does not want it.
- **The root service restarted by the kernel.** It holds every grant and the record of every grant. A new root service starts with none of them, and every handle of every process then names a grant that no one keeps. The split of the root service makes this part small; it does not make it restartable.

## The subtle points

- **A crash for a hostile input is a fault of the holder.** "Let it crash" covers the invariants of the holder: a table that disagrees with itself, a count that the code cannot reach. A call with a hostile argument gets an error record and changes nothing ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). A holder that stops on the input of one client gives that client a way to stop the role for all, and the restart bound turns it into a denial of service.
- **The new holder reads hostile counters.** The old holder wrote the counters of the command queue that it read. The new holder copies them once, checks them against the capacity that the kernel gives, and refuses a ring whose counters are not possible: that connection ends with `Ended`, and no other connection does.
- **A call that the old holder answered is not in doubt.** The library reads each completion that the ring holds before it replays, so a call that ran and was answered never runs again, with or without a serial.
- **A client that stops during the restart of its holder.** Its connection ends at its reap, as today. The new holder gets `Disconnect` in place of `Connect` for it, and removes its request serials at its next commit.
- **A client and its holder that stop together.** In a restart group, the starter starts the provider first. The root service gives the connections of the dependent to the new holder only after the dependent started again, so no call of the old dependent reaches the new holder.
- **The record outputs do not continue.** A stream is the records of one process: a new holder is a new writer. The writer of a stream reads `Writer_Stopped` at the stop of the holder, as today, and the asker wires the new holder again. A writer row of a start list keeps its count of 0 restarts ([module_outputs.md](module_outputs.md), "A writer row has no restart").
- **The holder serial is a process serial, not a count.** A client compares it for equality only. The kernel never gives one process serial to two processes, so no restart can make a client take an old holder for a new one.
- **The connection page is paid by the client.** It is one page for each connection. With the work budget of the connection ([work_accounting.md](work_accounting.md)), the page comes from it, so a client with many connections pays for its pages.
- **`unlock` and the TPM service.** A restart gives no second unseal: the TPM counts each try, and `unlock` keeps no secret in its store for a restart to read. These two keep their rules of today: `unlock` starts again only by its row, and the TPM service, past its stop, refuses each seal until the next start of the machine.

## The frequent tasks

- **See the restarts of a holder.** `restarts("storage")`: a row for each stop of the run, with the stop cause, the stop outcome, the time on the clock of the system, and the count left in the window.
- **Give a row a window.** A start row with `restarts = 5` and `restart_window = 60`: at most 5 restarts in 60 seconds.
- **See the calls that a client sent again.** `connections("console")`: a row for each connection, with its holder serial, its state, and its counts of calls replayed and of calls given `Holder_Stopped`.
- **Make a holder stop, to test its restart.** `stop("storage")` from a console that holds the grant `Stop`. The starter starts it again with the stop outcome `Stopped_On_Request`, as for each stop that a holder did not choose.

## State

Built, the first layer of pure contracts and rules: the contract package `supervision` (`src/library/modus/contract/supervision/`) with the closed explicit-value enums (`Restart_Strategy`, `Connection_State`, `Call_Replay_Rule`, `Escalation_Action`) and their transport borders, the fixed-layout `Connection_Page` with atomic seqlock reads and monotonic holder-generation reconnect transitions, the fixed-capacity `Request_Serial_Log` deduplication table for at-most-once execution, and the pure `Client_Call_Tracker` retry state machine bounded to one automatic retry per call; and the pure BEAM-style `Supervision_Tree` in `src/library/internal/root/start_policy_rules/` with restart strategies, optional sliding restart window (`window_milliseconds == 0` for whole-uptime counts with no clock read), cycle refusal on dependencies, and bounded escalation to parent or root, all covered by adversarial host tests. Built after it: the restart window of a start row (the version 3 of the start list, and the pure rule `start_list.restart_window_take`, which the default start policy calls with the clock only for a row with a window), and the stop of the default start policy with `Failed`, with one line that names the row, its count and its window, when a needed row is past its bound; and the rescue that the root service starts at that stop after `Machine_Usable` too. Built before it: the start tree with the start policy and its count of restarts for each row, the stop cause and the stop outcome, the end words of a stream, the private store with one commit for each change, and the start on demand of a service at its first connection. Left: wiring the connection page and the keep of the call ring and the call region into the root service; the flag `Again` and the connection serial of `Connect`; the calls in doubt and their replay in the system library; the attribute `idempotent` and the request serial in the module format, with the check of the tool; the request serials of the storage service in its store blocks; deriving the restart group from the role table; the restart window of the command `Start` of a start policy from the disk; the check of the ranks of the role table; and a test of each holder of a role that stops it in each call that changes state, starts it again, and checks the replay.
