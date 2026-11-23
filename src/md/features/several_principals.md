# Several principals on one machine

Status: Decided. The first layers are built: see "State".

More than one named principal uses one machine, each with its own session, its own stores and its own keys, and none reads the data of another. This file records the form of layer 4 of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users", where the property gives a direction only: "disjoint handle trees, no kernel change". The prior art and the three designs that were compared are in [`docs/research/several_principals_study.md`](../../../docs/research/several_principals_study.md). The independent study and the critique that decided between the two are [`docs/research/several_principals_independent.md`](../../../docs/research/several_principals_independent.md) and [`docs/research/several_principals_critique.md`](../../../docs/research/several_principals_critique.md).

## Purpose

- Several people use one machine, and a person who is not in front can not read, see or change the data of another.
- A principal puts its session aside and comes back to it with its work as it left it.
- A principal works from another machine while another principal uses the screen.
- The authority over the machine is a grant that can be given and taken back, never an identity.
- A removed principal leaves no data that another principal or a reader of the disk can open.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": the kernel knows no principal; a session is the tree of processes that started from the root handles of one principal; removal drops the whole tree.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": line 5 (the clipboard), line 7 (input to the window in front only), line 8 (the trusted surfaces and one key to the system), line 16 (a limit for each resource), line 17 (side channels are reduced, not solved), line 18 (no root).
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable": a role has one holder in each of its scopes, and a session is a scope. A holder of a role of the trusted path is a holder of the signed image or a choice of principal 0.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": the authority over the machine and a share between principals use the grant records that exist, not a second mechanism.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface": no kernel operation is added. The kernel freezes no process.
- The TPM has one count of wrong authorization values for all its objects ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "Subtle points").

## The decisions

These eight choices close the open questions of the two studies. Each other part of this file follows from a property or from an intent file.

1. **The authority** is one machine grant with two scopes, `Principals` and `System`, used as a wide grant for principal 0. The recovery key of the machine key is the way back. The console of the boot closes on a machine with a named principal, and the proof of principal 0 by the machine passphrase leaves [wide_grants.md](wide_grants.md).
2. **Property 20, line 18,** reads: the principal of a session is the only source of the grants of that session; a holder of a machine grant is the only source of a grant of the machine. Property 21, layer 4, gains: each service that keeps data has a scope, and the stores are encrypted.
3. **A removal with no consent.** A holder of `Principals` removes any principal, reads nothing, and the act is in the machine audit space.
4. **One open session first.** A session behind is a later, plan-only grant with a time bound. Until then, a switch stops the programs of the principal that leaves.
5. **The identity key.** `unlock` makes the root key at the creation and keeps it sealed under the unlock key until the first join; the join takes it offline and erases it.
6. **The count of the TPM** stays one for all until the study of the form "PIN fail" ends; that form is taken only if the TPM alone resets its count.
7. **The display holder of a session** is chosen by principal 0 only, as property 23 says, until the seat draws each trusted surface.
8. **The gate of the second principal.** `principals.PRINCIPAL_CAPACITY` stays 2 until the layers 1 to 11 of "The layers" are built.

## The chosen form

**The invariant.** No process holds the clear data of two named principals, at one time or one after the other, unless the list of joint processes names it.

### The states

A session is `Absent`, `Creating`, `Locked`, `In_Front`, `Behind` or `Removing`. A seat is `Chooser`, `Unlock_Window`, `Admission` or `Session`. Each is a closed enum, and one procedure changes it: it takes the state and an event, and gives the next state or a refusal (`modus:principals`, `session_states.odin`). The root service and the delegated service `principals` use the same procedures: one state machine for one concept. A member exists in the code only from the layer that builds it: today `Behind`, `Removing` and `Admission` have no member.

**The session in front** is a fact of the seat of its own: the session whose surface the screen shows and to which the input goes. It is not "the principal that is unlocked". With one open session, the two agree; with sessions behind, they do not. The root service keeps the seat beside the records of the principals, and `desktop_principal` reads the seat, never the set of unlocked records.

- `Session`, with the principal in front: the desktop starts each process in that session. With no named principal, principal 0 is in front.
- `Chooser`: no session is in front and no window of `unlock` shows. A new record of a named principal takes the seat from principal 0.
- `Unlock_Window`: a window of `unlock` that no session asked for shows: the unlock or the creation.

The state that the root ring gives (`root_ring.Principal_State`) is a word of the contract. It is computed from the session state at one place, so the two never drift.

### The identity: three names

| Name | What it is | Where it lives |
|---|---|---|
| The principal identifier | 256 random bits that `unlock` draws at the creation. It never changes and it comes from no key | On the disk: the file of the principal, the owner field of each store, the payload of the pin, the collector index |
| The slot | A small number of this run of the machine: the index of the tables of the root service, and bits 48 to 62 of the grant of a connection | In memory, and in the index of the pin |
| The identity key | The public key that a signed grant names | Decided with the shares (decision 5) |

- No slot is written in a store name, in a store or in a signed record.
- A slot that a removal frees is not used again before the next start. An old connection then never names a new principal.
- The pin of a slot names the identifier. A file with another identifier is refused.
- A name is a label of the chooser, never a key of a table.
- **The file.** The identifier is in the file of the principal, in both forms, under the additional data of each seal: a file whose identifier changed does not open (`OFFSET_IDENTIFIER`). `unlock` gives it to the root service after the record (`Principal_Identifier`), and the root service starts no session of a record with no identifier, and refuses a second identifier for a record.
- **An older format.** The file of a release before the identifier has the format 1. It is refused with a sentence that says what to do: "create the principal again". Before 1.0 a format changes with no migration.

Why random and not the hash of a key: a hash of the identity key needs that key at the creation, which [several_machines.md](several_machines.md) keeps on no machine, and an identifier of 64 bits from a hash can be forged by a search of keys. 256 random bits need no key, and no search finds them.

### The log by principal

A caller that acts for a named principal reads the records of the processes of that session only. The design is in [log_reader_scope.md](log_reader_scope.md), "The scope of a principal".

### The authority key of the wide grants, for each principal

The root service draws one authority key at its start, and gives each collector the key of its principal only: the keyed BLAKE3 hash of the key of the run over the slot of that principal. A collector of one principal then makes no proof that the collector of another principal accepts. The proof serial is one sequence for each principal. The design is in [wide_grants.md](wide_grants.md), "The deliberate act: the proof of the principal".

### The seat, and a display for each session

The machine has one **seat**: the holder of the screen, of the input devices, of the key to the system, of the prompt of `unlock`, of the switch, of the marks and of the trusted surfaces.

- **First form, one open session.** The root service stops the display holder at each lock and starts a new one: one process for the chooser, one process for each session. No palette ranking, glyph cache, notification or clipboard of one principal stays in a process that the next one uses. The kernel enforces it.
- **Second form, sessions behind.** The seat holder and the display holder of a session split. The cost of the hop of each frame is measured against the thresholds of property 18 before the layer starts.
- A surface of `unlock` is in no capture: not in `Screen_View`, not in the copy that `remote_display` reads.

### The authority over the machine

- **The row.** A machine grant is a row of the disk grant table of principal 0, tagged with the machine key. It names a principal identifier and a set of machine scopes.
- **Two scopes, because two levels of trust exist.** `Principals`: admit a principal, remove a principal, set the budgets. Its holder destroys and denies only. `System`: the plan of principal 0, the start policy, the holders of the trusted path, the device grants, the machine passphrase, the update. Its holder is trusted as the hardware is.
- **The use is a wide grant for principal 0.** The proof is the passphrase of the holder in the proof mode of `unlock`. The time bound, the mark and the act records are those of a wide grant.
- **The first holder.** A machine with no named principal runs as today. The creation of the first named principal gives it both scopes.
- **The last row of `System` is never removed.** The recovery key of the machine key gives both scopes to a named principal that exists, on the chooser, with an act record.
- **The machine audit space.** Each use of a machine grant is an act record that each admitted principal reads. The act that ends a full space is exempt from the refusal of a full space.
- **The guide states the trust in plain words.** A named principal trusts the holder of `System` with its passphrase. No seal changes this.

### The services that keep data

- A service that keeps data of a named principal runs one time for each principal, with a store of that principal: `settings`, `plans`, `projects`, `recipes`, the collector, the display holder, the console, the clipboard.
- **The list of joint processes** names each process that serves more than one named principal: the kernel, the core of the root service, the storage service, the log service, `scheduler`, `principals`, the powerbox, the disk process service, the seat, the input service, the audio service, the network service, `unlock`, the TPM service, `remote` and `remote_display`.
- **The check.** Each row of `start_grant_sets` states its scope. `modustool check` refuses a machine-scope row that serves a connection of a named principal and is not in the list.

### The rest

- **The creation is an admission.** A holder of `Principals` asks. The seat goes to `Admission`, and the session of the holder leaves the seat. The new person types the passphrase two times.
- **The unlock hints.** The file of a principal has a public part under the additional data of the seal: the layout in which its passphrase was typed, its language, its assistive needs.
- **The removal is a state machine.** The state `Removing` is written in the record of the principal before the first destructive step. A start that finds it goes on. The pin gains the payload "free, generation g", which only the removal writes.
- **The stores of a principal are encrypted** under keys that come from its unlock key. The lock erases them in the storage service. The design is [store_encryption.md](store_encryption.md).
- **The budgets are reserved:** pages, process slots, thread slots, log records and blocks, for each session.
- **The client table is keyed by the pair of the principal and the key.**
- **A share is the signed grant, and nothing else**, as the last layer.

## The layers

Each layer adds one capability to a system that works.

1. The states as enums. The session and the session in front, apart from the set of unlocked principals.
2. The log scope by principal, and the lines of a session as records of that session.
3. A surface of `unlock` in no capture, and the unlock hints in the file of the principal.
4. The authority key of the wide grants for each principal.
5. The principal identifier: the file, the owner field of a store, the payload of the pin, the collector index.
6. The stores of a named principal encrypted under its unlock key.
7. A seal that an update keeps.
8. Session-scope services, a fresh display holder for each session, the list of joint processes and its check.
9. The budget of a session, the client table keyed by the pair, and the removal by the principal itself with the free pin.
10. The machine grants, the chooser alone on the seat with no session, and the machine audit space.
11. The removal by a holder of `Principals`.
12. A second named principal, one open session. The capacity grows only here.
13. The seat holder and the display holder of a session; sessions behind; the remote seat.
14. The signed grant between two principals of one machine.
15. The count of the TPM for each principal, after its study.

Why this order: each layer of 1 to 9 improves the system of one named principal, and needs no decision. The second principal comes after each shared place is closed, so no release ships a separation that a reader of the disk breaks.

## Refused forms

- **One compositor that holds the windows of each session.** One defect in one of its tables shows the windows or the keys of one principal to another, and the trusted path depends on all of it.
- **An administrator as an identity, a group, or the first principal fixed for ever.** Property 20, line 18, refuses a root.
- **The machine passphrase as the authority over the machine.** Each person who changes the machine then shares one secret.
- **Four machine grants.** `System` reaches everything through the trusted path; the three others destroy and deny only. Two levels of trust give two scopes.
- **A machine grant with a state machine of its own.** It is a wide grant for principal 0: two state machines for one concept contradict property 22.
- **The number of a principal as its identity on the disk.** A number used again gives the new principal the stores, the pin and the audit of the old one, and a number never used again ends at the indices that the TPM holds.
- **An identifier of 64 bits from the hash of the identity key.** A search of keys forges it, and it needs the identity key at the creation.
- **One authority key of the wide grants for each collector.** The collector of one principal then makes a proof that the collector of another principal accepts.
- **An invitation with a name and an end time.** It proves nothing: any person at the keyboard becomes that name.
- **A local share by a row of the disk grant table of the giver, or a handover sealed to the receiver.** Each is a second mechanism beside the signed grant.
- **A creation in a window of the session of another principal.** The recovery key of the new principal shows on the screen of the creator.
- **A frozen session.** It needs a kernel operation that stops each thread of a budget.
- **A switch back to a kept session with no passphrase.** It gives the session to whoever stands at the machine.
- **One clipboard for the machine.** A copy of one principal reaches the paste of another.
- **A count of the TPM that the system writes**, in `unlock` or in an NV index: a process of the system then resets it.
- **Whole-volume encryption with one key for each principal.** It separates nothing between principals.
- **A split of the compositor before the second principal.** A fresh display process for each session gives the same separation with one open session.

## Subtle points

- **The shared count of the TPM.** A wrong passphrase of one principal counts against each other one: a principal can lock the others out of their sessions until the recovery time of the TPM, or until each types its recovery key.
- **The NV memory of the TPM.** Each pin uses it. A principal past what the TPM holds has no pin, and its creation says so.
- **The list of names at the prompt** tells each person at the machine who uses it. A value of the plan of principal 0 hides it.
- **The keys of kept sessions.** With encrypted stores, the storage service holds the keys of each unlocked principal at once. A lock is what erases them, not a switch.
- **The channels between running sessions** are reduced, not closed: a budget for each session, a share of the processor, a precise clock as a grant.
- **A remote seat attaches to an open session with its client key alone**, as the way back to the front needs the passphrase and the input of a viewer never reaches `unlock`.

## State

Decided. Built: the session states and the seat in the root service (layer 1); the log scope by principal (layer 2: `records`, `value_runs`, `fact_records`, `log.follow`, the window, the lines of the root service about a session and a number of each record in the scope of its principal); the authority key of the wide grants for each principal (layer 4); the principal identifier in the file, drawn by `unlock` and given to the root service (the first part of layer 5). Left of layer 5: the owner field of a store, the payload of the pin and the collector index by the identifier. Layer 6 is designed ([store_encryption.md](store_encryption.md)), with its keys, nonces and tags built. Not built: the layers 3 and 7 to 15, and the rest of 5 and 6. One named principal: `principals.PRINCIPAL_CAPACITY` is 2.
