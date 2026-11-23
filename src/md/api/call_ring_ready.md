# The ready completion of a call ring

A caller lends a handle to a call host or to a service through the call ring: the kernel gives the copy to the one other process that maps the ring with the consent to receive handles (`Receive_Handles`, [../features/module_outputs.md](../features/module_outputs.md)). This file records when a caller can send its first call: after the serving side says, in the ring itself, that it maps the ring with that consent.

## The purpose

The root service completes `Connect` when it has made the connection and named it on the service ring of the service. It does not wait for the service. A service that starts on demand is still in its start at that moment: it has not read its service ring, and it does not map the call ring. A first call that lends a handle then fails: no other process maps the ring with consent, and the kernel refuses the give with `Bad_Handle`. The console showed it as "an argument names no handle of the console" on the first `recipes.build_c` of the loop of a program ([../features/program_loop.md](../features/program_loop.md)). A first call with no handle did not fail, because it waits in the ring until the service reads it: the fault showed only for a lend.

## The constraints

- The kernel interface is counted ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). The consent of `Handle_Give` stays as it is.
- The core of the root service must not wait for a delegated service in its loop ([root_service_split.md](root_service_split.md)); a service that never reads its service ring must not hold the root ring of any caller.
- One rule for each caller. A rule that each command or each caller applies by hand leaves the fault in each caller that forgets it.
- A word that the other side writes is hostile input: the caller reads it at one border, which refuses a record that is not the ready completion.
- A wait ends when the serving process stops: that is the failure. A time in the wait only ends a hang ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"), and never asserts the speed of a start.

## The chosen form

**The ready completion.** The serving side of a call ring sends one completion before any other: the tag 0, the kind `isolated.Status.Ok`, the values zero. It sends it after it maps the ring with `Receive_Handles` and maps the call region. A call host sends it after it loads its module; a call host that does not load sends `Load_Failed` with the tag 0 in its place, as before. A service sends it in `system.connection_add`, the one place where each service accepts a connection that the root service names.

**The caller waits for it, at the one place that opens a connection.** `system.connection_ready_wait` reads the first completion of the ring. It is a wait for an answer from another process (`system.answer_wait_of`): it ends when the serving process stops, and at the hang bound of an answer, `system.ANSWER_BOUND_MILLISECONDS`, which is the hang bound of a process (60 s). One step of it, `system.connection_ready_step`, reads the ring and the state once and is pure, so a host test gives it a late ready completion and a stop. `system.call_host_start` and `system.service_connection` call it before they give the connection to their caller; the console and `remote`, which send `Connect` with their own root ring, call it after they map the ring. A connection that does not become ready is ended, and the caller sees a refusal of the connection, not of a call.

**The border.** `isolated.ready_of_first_completion` turns the first completion into `Ready`, `Load_Failed` or `Refused`. A completion with a tag other than 0 is `Refused`: no call was sent, so no completion of a call can come first. A tag 0 with another kind, or with values that are not zero, is `Refused` too. It is pure: `odin test` of `modus:contract/isolated` gives it each record that it must refuse.

**What changed.** Before this form, only a call host sent a first completion; a connection of a service was ready to the caller when `Connect` completed.

## The refused forms

- **A call with no handle before the first lend, in each command that lends.** It works, because the service answers only when it reads the ring. But it costs one call for each command, and each other caller that lends to a service started on demand keeps the fault.
- **The root service completes `Connect` only when the service accepted.** The contract of `Connect` would hold the whole rule. But the root service would keep a table of the connections that wait, and a service that never reads its service ring would hold the root ring of its callers, and the core would wait for a service in its loop.
- **The kernel waits in `Handle_Give` until a process maps the ring with consent.** A kernel operation would block on the start of a process, and the kernel has no bound to choose for it.
- **The kernel refuses with a status of its own for "no receiver yet".** The caller would still need a thing to wait on, and the kernel interface grows by one status for a fact that the ring can carry.
- **A word in the head of the ring that the serving side sets.** Each ring would carry a word for one use of the ring; the completion queue already is the place where the serving side speaks, and a call host already speaks there first.

## Subtle points

- The wait does not trust the service. A service that sends the ready completion and does not map the ring with consent gets the refusal of the kernel at the first lend, as before; it hurts only its own callers.
- **Each connection gets the ready completion; the procedures that open a connection wait for it.** The root service also makes connections to the storage service at the start of a process (its private store) and for its own readers, which it gives to other services. Those callers lend no handle to the storage service, and each caller skips a completion whose tag is not the tag of its call, as before. Call tags start at 1, so a call never has the tag of the ready completion.
- When the caller gives up a connection that did not become ready, it sends `Disconnect` and waits for its answer: else the root service keeps the connection and refuses the next `Connect` of the caller, and a late answer with a reused tag would be read as the answer of that next `Connect`.
- A connection that the storage service makes for a share (`system.connection_make`) is mapped with consent before the storage service gives its ring to the caller: it is ready by its order, and its client reads no ready completion.
- **The bound is the hang bound, not the time of a start.** A service that starts on demand opens its store before it serves, and on a loaded host the machine waits most of its time for a processor: a start can take many seconds, and a bound tuned to a fast host (the 5 s of the start of a call host, before this form) would end a correct connection. The stop of the serving process is the real failure, and the wait sees it at once; the bound ends only a process that runs and never answers.
- **The answer of the root service to `Connect` has the same bound.** The root service can start the service before it answers, so a bound tuned to a start ends a correct connection on a loaded host too. A caller holds no handle of the root service, and a stop of the root service is the end of the machine: the one end of that wait is the hang bound of an answer. `system.root_answer_wait` waits for it in `service_connection` and for the answer of its `Disconnect`; its one step, `system.root_answer_step`, skips the answers of requests that the caller gave up and is pure, and the console reads its root ring with it. The console (`Connect`, `Disconnect`, `Connect_History`) and `remote` (`CONNECT_LIMIT`) give the same bound.
- **The completion before the state.** The wait reads the state of the process, then the ring. A call host that sends `Load_Failed` and stops is read with its completion, not as a stop with no answer.
- A service that the bound ends keeps running; the caller ends only its connection.

## State

Built: the ready completion in `system.connection_add` and in the call host, `isolated.ready_of_first_completion` with its host tests, `system.connection_ready_wait` in `call_host_start`, `service_connection`, the console and `remote`. The machine of the loop of a program lends a handle in the first call of `recipes` and of `module_files`, two services started on demand.
