# The split of the root service

The root service is the one process that creates access from nothing. It is 14 780 lines in 39 files (`src/modules/system/root/`), and the planned work adds more to it: the roles of a plan, `Apply` and `Rollback`, the realisation of recipes, the powerbox, the choice of a language pack. A fault in any of these lines is a fault of the process that holds every grant, and a wait in any of them is a wait of the loop that serves every root ring. This file records how the root service keeps the root of authority in a small core and gives each other domain to a delegated service: a separate process that holds one attenuated class of authority. It is [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable", applied to the root service itself. The term Delegated service is in [`docs/glossary/access.md`](../../../docs/glossary/access.md).

## The constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": each handle comes from the root service, directly or through a chain, and a revocation ends a whole chain. A split must keep one root of each chain.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 12: a service acts only on the handles that its caller sends, never on its own authority for a caller.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM": the start is measured, and the root service starts before any service exists.
- [start_policy.md](../features/start_policy.md): the mechanism stays in the root service, the policy leaves it. This file applies the same rule to the other domains.
- **No new kernel operation.** Each delegated service uses handles that the kernel already has: a budget, a process handle with fewer rights, a memory object, a ring.
- **No compatibility.** A command of the root ring that moves to a delegated service leaves the root ring.

## What stays in the core

The core is what only the root of authority can do. Each part names why no delegated service can hold it.

- **The making of a process and its first handles.** The core loads the bytes of a module into a new address space, writes its context, gives its budget and its first handles. Whoever makes a process holds each handle of it at its first instruction; a second maker is a second root.
- **The tree of the origin of the handles.** The kernel records where each handle came from. Each delegated service gets its authority from the core, so a revocation by the core ends each handle that the service gave, whatever the depth. This is the membrane of [../features/roles_and_contracts.md](../features/roles_and_contracts.md), "Composition by interposition", with the core outside each one.
- **The roles, by the plan.** The core reads the default roles of the image and the roles of the plan, checks each holder against its contract, and gives the grants of each role. A delegated service that gave roles would give grants that the core does not see.
- **The start before any service.** The check of trust, the seed, the boot display, the pages that every process maps, the start of the first delegated services, the start of the start policy, its rescue and its measure. No service exists yet to do it.
- **The connections and the root ring.** A connection is two ends in two processes, and the core holds a process handle of each process. The root ring is the one door to the core: its border, its senders and its dispatch stay ([root_ring.md](root_ring.md)).
- **The replacement table.** The loader of the core reads it at each start, and a change of it puts code into each importer ([module_replacement.md](module_replacement.md)).
- **The debug access.** A debug grant is a process handle with Control over another process. The core is the one holder of such a handle for each process; a delegated service that gave debug access would hold the same authority, so no attenuation exists. Its policy is already a pure procedure.
- **The reap.** The core receives the stop of each process, ends its grants and its places, and tells each delegated service that needs it through a record output of the core: `stops`, one record for each stop, with the process slot, the process serial and the stop cause. No service waits for a broadcast.

## What is delegated, domain by domain

Each delegated service is a role of the set of [../features/roles_and_contracts.md](../features/roles_and_contracts.md), with a role contract and a conformance suite, so a principal can replace it as any other holder. Each gets one class of rights that it can make and give, and no other. The core checks each request of a delegated service at its border, as it checks the record of any process: a delegated service is not trusted more than its class.

| Domain | Files of today | Lines | Service | The attenuated grant | Role contract |
|---|---|---|---|---|---|
| The wiring of record outputs | `wirings.odin` | 1 577 | `wiring` | For each asker, a child budget of the reserve of its wirings, with `Spend` on that child only; for each process with a record stream, its wiring ring and a process handle with Give only; the module files read-only for the type check | `Wiring`: `Wire`, the wiring list of a `Start`, the record input `stops` |
| The disk processes | `disk_processes.odin`, `import_scan.odin`, `debug_store.odin`, `disk_process_page.odin`, `facts_disk_refusals.odin` | 2 041 | `disk_processes` | A connection that reads only to the store `module_files` of each principal; the command `Start_From_Bytes` of the core, which starts a process with the grants of the row of its nickname and never more; the write of the disk process page | `Disk_Processes`: `start_from_disk`, the import scan, the debug object of a disk process |
| The principals, their sessions, their disk grant tables and the client keys of `remote` | `principals.odin`, `persisted_grant_table.odin`, `remote_clients.odin`, `start_policy_choice.odin`, `facts_principals.odin`, `facts_disk_grants.odin` | 3 069 | `principals` | The stores of the disk grant tables and of the applied plans; the write of the client table; the command `Disk_Rows_Set` of the core, which takes rows of the disk grant classes only (`Store`, one row `Start_Policy`, the uses of a client key); the stop of the processes of a session of a named principal | `Principals`: the commands of the principals, of the disk grants and of the client keys, and later `Apply` and `Rollback` |
| The devices | `devices.odin`, `entropy.odin`, `tpm.odin`, `network.odin` | 1 142 | `devices` | The configuration space of the bus, the registers and the interrupts of each device, and the right to declare memory to the IOMMU, each given to one device service | `Devices`: the table of identities, the start of the device service of one device, the class ring of each |
| The settings page and the appearance in force | `text_settings.odin`, `appearance_edge.odin` | 217 | `settings` | The settings page with Write, which today `settings` and the core both write | `Settings`: the exports of `settings` |
| The fixed starters of the display, the input, the terminal, the palette and the test parts | parts of `main.odin` | 453 | none: they become role grants of the core | The framebuffer, the ports of the PS/2 controller, the input ring and the palette ring become grants of a role, which the generic start gives | The contracts of `Display`, `Input`, `Terminal`, `Console` |

The planned domains get a delegated service from their first line:

- **The realisation of recipes** goes to the holder of `Recipes`, with one grant: the command `Start_Sandboxed` of the core, which starts a builder with only the clones that it names with Read, an empty store "out", no network and a frozen date page ([../features/recipes.md](../features/recipes.md)). It refuses any other grant.
- **`Apply` and `Rollback`** split in two: the core computes the difference of the grants and of the roles, because it gives them, and writes the roles of the new plan; `principals` keeps the store `applied_plans` and the row "current plan". The core never reads a plan from a service it does not check: it reads the plan through its border, as today ([../features/declarations.md](../features/declarations.md)).
- **The powerbox** is a service of its own, `powerbox`, with one grant: a share of an object of a store of the principal of its caller, with Read or with Read and Write, given to the process that asked, after a pick on a trusted surface of the display. It reads no object.
- **The mapping of a language pack** stays a mapping of a resource of the image by its hash, which the core makes at the start of a process; the choice of the pack is a setting of `settings`.

The core keeps the rest: about 6 300 lines today (`main.odin` without the fixed starters, `start.odin`, `start_grant_sets.odin`, `root_ring.odin`, `start_policy.odin`, `budgets.odin`, `trust.odin`, `replacement.odin`, `fresh_bytes.odin`, the pages, the debug access, and their log facts). The fixed starters leave it as role grants, and the roles of the plan come in.

## The refused forms

- **One process with every grant, with the code split into libraries.** A library in the root service runs with every handle of the root service: a fault in it is a fault of the root. Only an address space bounds a fault.
- **A delegated service that gets the whole authority of its domain, such as `Spend` on each budget or Control on each process.** A fault in it is then a fault of the root under another name. Each grant is the narrowest that the domain needs, and the core refuses a request outside it.
- **The debug access as a delegated service.** It needs Control over each process, which no attenuation narrows.
- **A delegated service that decides a role or a grant of a process of the boot image.** It would be a second source of grants. The core alone reads the roles.
- **The core as a client of a service on its path.** Today the core waits for the storage service to load a disk process and to read the disk grant tables. A slow or hostile storage service then slows each command of the root ring. After the split, the core is the client of no service, but the TPM service for the measure of a start policy, with its bound of 30 s.
- **A broadcast of the stops to the delegated services.** A record output `stops` with one ring for each reader, as each record output ([../features/module_outputs.md](../features/module_outputs.md)).

## The risks

- **Each new border is a border of trust.** A delegated service is a process that a fault can take, so its role contract is narrow: few commands, each with a whole record and one border in the core that refuses a word that names no member and a request outside the class of the service. A host test and a fuzz target call each border, as for the root ring ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).
- **The confused deputy.** A delegated service acts only for the principal of its caller. The core writes the principal in the grant of each connection to a delegated service, as it does today for the storage service, and the service reads the principal there, never in a value of the request. A delegated service holds no grant of a principal for itself: `principals` writes the table of a principal only for a caller that acts for that principal.
- **The order of the start.** The core starts `devices` first, which starts the entropy service, the TPM service and the block devices; then the holder of `Storage`; then `principals`, which reads the table of principal 0 with `unlock` and gives the core its rows; then the core gives the roles of the plan and starts the start policy. `wiring` and `disk_processes` start on demand at their first request. A delegated service of the start that fails is started again by the core within a bound of three starts; past it, the machine starts as a machine with no such part, with one line: no data disk when `devices` fails, the default roles and the start policy of the image when `principals` fails ([../features/missing_hardware.md](../features/missing_hardware.md)).
- **The cost of one more hop.** A hop is added on four paths, each to measure before and after its step, never to assume: a `Start` with a wiring list (the core asks `wiring` before the first instruction of the child), which the measure of the start of a window shows; a `Start_From_Disk` (the core waits for `disk_processes` and no longer for the storage service); a `Wire`; the change of a disk grant. No hop is added to a call of a service or to a record of a record output, which the core never carries.
- **Two writers of one object.** `principals` holds the disk grant table, which also holds the client keys and the choice of a start policy: one service, so the table has one writer. Two services would need an order of their writes.
- **A domain that the core still needs.** The core must not wait for a delegated service in its loop. It sends a request, and the answer is a word of its one wait, as the wiring rings are today ([../features/module_outputs.md](../features/module_outputs.md), "The budget").

## The order of the split

Each step moves one domain, leaves a system that works, and is one roadmap entry. The first steps give the most resilience for the least work. The split starts with the wiring: it is the largest hostile input of the core, in one domain with few ties to the others, so it proves the form of a delegated service at the least risk.

1. **The record output `stops` and the command `Start_From_Bytes` of the core.** The two faces that the delegated services need, with their host tests. The wiring service is their first user: `stops` tells it of the end of each writer and each reader. Nothing moves yet.
2. **The wiring service.** The largest hostile input that any process reaches (a list page, lent handles), in one file with its own contract. A fault in a wiring list then stops `wiring`, not the root.
3. **The disk processes service.** The core no longer reads a module file from the disk, nor waits for the storage service at a load; it checks the hash of the bytes itself.
4. **The principals service.** The keys of the principals, the disk grant tables and the client keys leave the core, and the core is the client of no storage service.
5. **The devices service.** The configuration space and the device grants leave the core; the order of the start changes, so it comes after the steps that do not.
6. **The settings page to `settings`.** One writer of the appearance in force; small, and at any time.

The fixed starters of the display, the input and the terminal become role grants in the steps of the display in `ROADMAP.md`. Those steps change the core and move no domain, so they do not wait for this order, and this order does not wait for them.

## State

Built:

- The contract package `src/library/contract/wiring_service/` (`Command`, `Response`, `Process_Stop_Notice`, `Attenuated_Grant_Kind`, and shared-region request/response records with strict borders and host tests).
- The pure wiring state machine `src/library/private/wiring/wiring_core/` (record-type equality, generic stream resolution, duplicate and cycle detection, capacity bounds, unwire/revocation, and stop cleanup with host tests).
- The delegated `wiring` service (`src/modules/system/wiring/`, 948 lines), registered with `{.System_Part}` in `start_grant_sets.odin` and holding only its attenuated grants (core ring, `stops` ring, read-only boot image, shared transfer region, per-asker `Spend`-only child wiring budgets, and per-process `Give`-only process tokens plus wiring rings).
- The root service core bridge (`src/modules/system/root/wirings.odin` reduced from 1 577 to 952 lines; `src/modules/system/root/` reduced from 14 780 to 14 031 lines, net -749 lines): starts `wiring` on demand, emits `Process_Stop_Notice` records on `stops` at reap and release, supplies attenuated grants, and drives wiring requests asynchronously from `root_loop_pass`.

Left: the `Start_From_Bytes` face and the remaining domains (`disk_processes`, `principals`, `devices`, `settings`).
