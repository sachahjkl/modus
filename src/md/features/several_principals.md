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

A session is `Absent`, `Creating`, `Locked`, `In_Front`, `Behind` or `Removing`. A seat is `Chooser`, `Unlock_Window`, `Admission` or `Session`. Each is a closed enum, and one procedure changes it: it takes the state and an event, and gives the next state or a refusal (`modus:principals`, `session_states.odin`). The root service and the delegated service `principals` use the same procedures: one state machine for one concept. A member exists in the code only from the layer that builds it: today `Behind` and `Admission` have no member, and `Removing` is built.

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

- **First form, one open session.** The root service stops the display holder at each lock (marking the stop as root-asked so reap does not treat it as screen absence) and starts a new one: one process for the chooser, one process for each session. No palette ranking, glyph cache, notification or clipboard of one principal stays in a process that the next one uses. The kernel enforces it.
- **Second form, sessions behind.** The seat holder and the display holder of a session split. The cost of the hop of each frame is measured against the thresholds of property 18 before the layer starts.
- **No surface of `unlock` in any capture.** The root service sets both `CLIENT_LOCAL_INPUT_ONLY` and `CLIENT_EXCLUDE_FROM_CAPTURE` on the `Client_Add` control record of every process that holds `.Principals` (every mode of `unlock`). During capture, the compositor clips every non-minimized excluded window against each dirty rectangle and overwrites the intersection with solid dark mask pixels before sending `Capture_Frame` to `remote_display` or any `Screen_View` reader (`internal:compositor/capture_filter`). Remote pointer and keyboard input never reach an `unlock` surface.

### The authority over the machine

- **The row.** A machine grant is a row of the disk grant table of principal 0, tagged with the machine key. It names a principal identifier and a set of machine scopes.
- **Two scopes, because two levels of trust exist.** `Principals`: admit a principal, remove a principal, set the budgets. Its holder destroys and denies only. `System`: the plan of principal 0, the start policy, the holders of the trusted path, the device grants, the machine passphrase, the update. Its holder is trusted as the hardware is.
- **The use is a wide grant for principal 0.** The proof is the passphrase of the holder in the proof mode of `unlock`. The time bound, the mark and the act records are those of a wide grant.
- **The first holder.** A machine with no named principal runs as today. The creation of the first named principal gives it both scopes.
- **The last row of `System` is never removed.** The recovery key of the machine key gives both scopes to a named principal that exists, on the chooser, with an act record.
- **The machine audit space.** Each use of a machine grant is an act record that each admitted principal reads. The act that ends a full space is exempt from the refusal of a full space.
- **The guide states the trust in plain words.** A named principal trusts the holder of `System` with its passphrase. No seal changes this.

### The services that keep data

- A service that keeps data of a named principal runs one time for each principal, with a store of that principal: `settings`, `plans`, `projects`, `recipes`, `collector`, `monitor`, `module_files`, `debugger`, `inspect`, `manual`, the display holder, the console, and user windows. When a caller connects to a session-scope service, the root service matches an instance of the caller's principal (or the client-row principal for `remote`) and starts one on demand in that principal's session with that principal's encrypted store. A lock stops every session-scope service of that principal.
- **The list of joint processes** names each machine-scope process that serves more than one named principal (`JOINT_PROCESS_NAMES` in `src/modules/system/root/start_grant_sets.odin`): `storage`, `log`, `scheduler`, `principals`, `powerbox`, `disk_processes`, `compositor`, `input`, `sound`, `network`, `unlock`, `tpm`, `remote`, `remote_display`, and `date` (read-only machine clock with no per-principal data).
- **The check.** Each row of `START_GRANT_SET_TABLE` declares `scope: Service_Scope` (`.Machine` or `.Session`). `modustool rule-checks` and `modustool check` run `joint_processes_check`: it refuses any row without an explicit scope and refuses any `.Machine`-scope service reachable by a named principal unless `JOINT_PROCESS_NAMES` lists it. The root service also enforces this rule at connection open.

### The rest

- **The creation is an admission.** A holder of `Principals` asks. The seat goes to `Admission`, and the session of the holder leaves the seat. The new person types the passphrase two times.
- **The unlock hints.** Both `PRINCIPL` and `PRINCIPT` use format 3 (formats 1 and 2 are refused as older formats). A 24-byte public `Unlock_Hints` block (`keyboard_layout`, `assistive_flags`, `language_length`, `language`) sits right after the salt. Both seal AAD ranges cover `Unlock_Hints`, so any tampering fails seal opening. The recovery seal AAD stops before the salt, so updating hints with only the passphrase keeps the recovery seal valid. Hints change only after passphrase proof. `unlock` applies the saved `keyboard_layout` hint directly through `modus:keyboard_layout` whenever it differs from the machine's active settings page layout.
- **The removal is a durable state machine.** A principal removes itself from its own unlocked session (`Principal_Remove` -> `Unlock_Mode.Remove_Principal`), after typing its passphrase to prove itself. Before the first destructive step, `unlock` writes a durable `Removing` record (`principal_removing`) to its store and transitions the session state to `Removing`. The machine steps cleanly through `Marked -> Keys_Erased -> File_Deleted -> Stores_Marked -> Pin_Freed -> Complete`. Erasing the versions of the principal file and recovery file cryptographically destroys the principal's key material so all encrypted stores of the principal are permanently unreadable. At `Stores_Marked`, `unlock` sends `Root_Command.Principal_Stores_Reclaim` with the removed principal's slot and 256-bit identifier to the root service, which sends `Principal_Locked` and `Principal_Reclaim` to the storage service. The storage service verifies that no live unlocked slot holds that identifier, durably rewrites every matching `OWNED_CELL_MARK` store cell to `RECLAIMING_CELL_MARK` (zeroing the name tag and scrubbing `owner`, `salt`, `key_check`, `name_sealed`, `store_generation`, and `mac` in its store block), and acknowledges completion before `unlock` advances to `Stores_Marked`. From then on, the storage service reclaims every block of every `RECLAIMING_CELL_MARK` store incrementally and keylessly in bounded copy-on-write commits (`internal:storage/store_reclaim`), finishing by freeing the store block and zeroing the store cell so repeated creation and removal never leaks disk blocks or store table cells. A crash or power loss before `Stores_Marked` resumes from `principal_removing` on the next boot; a crash or power loss after `Stores_Marked` resumes automatically from `RECLAIMING_CELL_MARK` cells on disk at the next mount. Once `Stores_Marked` completes, `unlock` writes the format-4 TPM pin payload `"free, generation g"` (`Principal_Pin_State.Free`, zero identifier and zero digests, generation incremented), failing closed if pins are not writable or if an active pin names another principal. A freed slot is never reused in the same run; after reboot, a new creation advances from `Free(g)` to `Active(B, g' > g)`.
- **The stores of a principal are encrypted** under keys that come from its unlock key. The lock erases them in the storage service. The design is [store_encryption.md](store_encryption.md).
- **The budgets are reserved:** pages, process slots, thread slots, processor time, log records, and storage blocks are reserved per session (`internal:root/session_budgets`), keeping a machine reserve scaled to the machine's capacity so even a 1-CPU host opens a bounded session budget and a named session hits its own limit before machine limits. At unlock, the root service creates a kernel child budget and storage block ledger for the session; every process started in that session pays from that child budget, and every session storage connection charges and releases the session block ledger; at lock, the root service closes them.
- **The client table is keyed by `(principal_identifier, public_key)`.** Two principals can allow the same public key independently with no `Exists` refusal and no `Contested` state ([remote_client_keys.md](remote_client_keys.md)). Unscoped `.Calls` lookups refuse ambiguous keys held by more than one unlocked principal, and `Wide_Grant_Agent_Ask` carries the connection's bound row number so the root service verifies the exact row and principal.
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

Decided. Built: the session states and the seat, one state machine for the root service and the delegated service `principals` (layer 1); the log scope by principal, with `log.follow`, the window, the lines of the root service about a session and a number of each record in the scope of its principal (layer 2); `unlock` surface exclusion from `Screen_View` and `remote_display` captures plus authenticated `Unlock_Hints` in format 3 principal files (layer 3); the authority key of the wide grants for each principal (layer 4); the principal identifier in the file, given to the root service, in the payload of the pin, in the index of the collector, and as the owner of each store of a named principal in the format `STORAGE7` (layer 5); the encryption of the stores of a named principal in the storage engine, with vector XChaCha20 (`simd128`), split clear/encrypted metadata nodes authenticated by 128-bit SIV MACs, encrypted data blocks, store rollback protection, keyless open and count repair, and per-principal cache and buffer erasure at lock (layer 6, [store_encryption.md](store_encryption.md)); the update-surviving TPM seal (`PolicyAuthorize` + `PolicyNV` version floor + persisted storage primary key + `Owner_Protect` in `modus:tpm2`, `modus:contract/tpm_service`, and `tpm`, layer 7); explicit `Service_Scope` on `START_GRANT_SET_TABLE`, per-principal session-scope service routing, fresh display holder at lock, and the `joint_processes_check` AST check (layer 8); reserved per-session kernel budgets, `(principal_identifier, public_key)` client table keying without `Contested` or `Exists`, and durable `Removing` self-removal with format-4 free TPM pin payloads (layer 9); machine grants (`Principals` and `System` scopes in format-5 principal 0 disk grant table tagged under the machine key, first-principal bootstrap, last-`System` protection, recovery restore), `Seat_State.Admission` with no session on the chooser, and the machine audit space (`root.machine_acts` readable by every admitted principal with full-space exemption for `Machine_Wide_Grant_Ended`, layer 10); grant-authorized removal of a named principal by a holder of `Principals` (`Principal_Remove_By_Grant`, `Unlock_Mode.Remove_Principal_By_Grant`, proving only the actor's passphrase and reading no target secret, reusing the durable `Removing` state machine, layer 11); multiple named principals on one machine with one open session (`principals.PRINCIPAL_CAPACITY` raised to 8 across root, `principals`, `unlock` multi-slot chooser/creation/removal, `storage`, and `session_budgets`, layer 12); local cross-principal signed grants reusing `machine_mesh.Signed_Grant` and `signed_grant_check` directly (layer 14). Not built: layer 13 (two open sessions on one machine) and layer 15 (separate TPM lockout counts), both deferred behind their stated conditions.
