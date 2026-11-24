# Several human principals on one machine: an independent study

Status: a design study. It is not an intent file. It changes no code and no file of the repository.

Read from local `master` (513764c51): `AGENTS.md`, `docs/PROPERTIES.md`, `docs/PRINCIPALS.md`, `src/md/features/tpm_sealed_principal_keys.md`, `wide_grants.md`, `several_machines.md`, `remote_display.md`, `powerbox.md`, `module_outputs.md`, `module_budget_request.md`, `log_reader_scope.md`, `clipboard.md`, `declarations.md`, and the code of `unlock`, `root/principals.odin`, `principals`, `collector`, `storage` (`may_name_store`), `modus:principals`.

Two limits of this study:

- `src/md/features/module_settings.md` is not on `master`. I read it from the branch `work/module_settings_study`.
- I did not read the branch `work/principals_study`, so that this study stays independent.

## 1. The verdict

Property 21 says that layer 4 is "disjoint handle trees, no kernel change". That sentence is true for the kernel. It is false for everything above the kernel. The system of today has six places where one process, one table or one counter serves every principal. Each of these places is a dead end for layer 4.

The recommendation has one invariant, one new concept and one decision about authority:

1. **The invariant.** No process holds the clear data of two named principals. A service is machine-scope and holds no clear data of a named principal, or it is session-scope and runs one time for each principal. A closed list names the exceptions.
2. **The concept: the seat.** A seat is one display with its input devices: the local screen, or one connection of `remote_display`. A session is in front on one seat at most. The seat replaces "the session in front" and `desktop_principal()`.
3. **The authority.** The system has no administrator who reads or resets. It has machine grants: admit a principal, remove a principal, set the budgets, apply the system plan. A named principal holds them. Each use needs the passphrase of that principal on the trusted path.

Three works come before the first line of layer 4. Without them, layer 4 gives a false promise:

- the encryption of the stores of a principal;
- a seal that an update of the system does not break (the signed policy of `docs/PRINCIPALS.md`, section 9);
- a durable identity of a principal that is not its number.

## 2. What the code assumes today

Each line is a fact that I read. Each one breaks with a second named principal.

| # | Fact | Where | What breaks |
|---|---|---|---|
| F1 | The number of a principal is its identity on the disk: the store name ends with `.principal.<n>`, the TPM pin index is `0x01806E00 + n`, the collector index holds the number | `principals.store_name_write`, `tpm2.pin_index_of`, `collector_segments.odin` | A number used again gives the new principal the stores, the pin and the audit of the old one |
| F2 | The stores of a principal are in clear on the disk | `docs/PRINCIPALS.md`, section 9 | The separation is a rule of `may_name_store` only. A reader of the disk, and a fault of the storage service, read each principal |
| F3 | `desktop_principal()` gives the first unlocked record. `principal_lock` locks "the session that runs" | `root/principals.odin` | Two unlocked records have no meaning. No state says which session holds the screen |
| F4 | The desktop stays while a named principal is locked. The console of the boot acts for principal 0 with no proof | `docs/PRINCIPALS.md`, sections 2 and 9 | Any person at the keyboard creates a principal, chooses a start policy, allows a client key for principal 0 and reads the whole log |
| F5 | A caller that acts for a principal reads the whole log | `log_reader_scope.md`, "The log scope" | The console of bob reads the records of the processes of alice, and each line "started notes, in the session of principal 1" |
| F6 | The TPM counts the wrong tries of each object in one count | `tpm_sealed_principal_keys.md`, "The count is one for all the systems" | Three wrong tries on the file of alice lock out bob and the machine passphrase |
| F7 | The seal names PCR 7 and PCR 11 | same file, "What the TPM seals" | An update makes each principal type its recovery key. A principal who is absent cannot seal again |
| F8 | A pin whose file is absent is ended only by a clear of the TPM | same file, "A removed file" | No principal can be removed on a machine with a TPM |
| F9 | One compositor holds each window, the clipboard, the palette ranking and the role store of the display | `compositor` | One address space holds the pixels and the history of each principal |
| F10 | `settings` and its store belong to principal 0. `plans` keeps one table for each principal in one process | `docs/PRINCIPALS.md`, section 2; `plans/main.odin` | The choices and the plans of a named principal are data of principal 0: readable while locked, and not removed with the principal |
| F11 | The layout of the keyboard is one setting of the machine, and the passphrase depends on the layout | `docs/PRINCIPALS.md`, "The passphrase" | Bob changes the layout. Alice then types wrong passphrases, and the TPM counts each one |
| F12 | One client key belongs to one principal. A key that another principal allowed is refused with `Exists` or becomes contested | `docs/PRINCIPALS.md`, "The client keys of remote" | Bob learns that another principal allowed a key. Bob allows the key of the device of alice first, and alice loses it |
| F13 | One budget pays all the disk processes: 4 processes, 16384 pages | `module_budget_request.md` | The disk processes of alice take each slot of bob |
| F14 | The kernel has 64 process slots and 256 thread slots | `log_reader_scope.md` | Two sessions that run at one time compete for slots. A refused start is a signal between them |
| F15 | The authority key of the wide grants is one key, which each collector receives | `wide_grants.md`, "The proof record is keyed" | The collector of bob can make a proof that the collector of alice accepts |
| F16 | The recovery key of a new principal shows in a window of `unlock`, and `Screen_View` gives the whole screen | `wide_grants.md` | A viewer or an agent of the session that asks for a creation reads the recovery key of the new principal |

## 3. The constraints that stay when everything else is removed

1. **The kernel knows no principal** (property 21). Each answer is a handle, a budget or a key.
2. **A lost key is lost data.** No party resets a passphrase. So no party can be given that power later, by any name.
3. **The holder of the hardware always holds two powers:** to destroy and to deny. No design removes them. The design must give that party nothing more.
4. **The holder of the trusted path sees each key and each pixel** (property 23, "Cost"). A principal who types a passphrase on a machine trusts whoever chose the display and the input of that machine. No seal changes this.
5. **Handles do not solve side channels** (property 20, line 17). Two sessions that run at one time on one processor have a channel between them.
6. **One mechanism for one concept** (Objective, rule 1). A share between two principals of one machine and a share between two machines must be one record.
7. **A cost of the properties:** "Work that runs while the principal is locked needs a key that stays available. This must be a narrow and visible grant."

Constraints 3 and 4 give the honest threat model. Say it in the guide, in these words:

- A named principal trusts the signer of the system and the holder of the machine grants as much as it trusts the hardware.
- A named principal trusts no other named principal, and no process of the system outside the closed list of section 4.1.
- Two sessions that run at one time are separated for access. They are not separated against measured side channels. A principal who needs that separation uses another machine.

## 4. The recommendation

### 4.1 The invariant: one scope for each process that holds data

Property 23 already gives a role one holder for each scope: the machine, a session, a client, a device. Use that rule for each service that keeps data, role or not.

- **Session-scope.** One process for each principal, started in the session of that principal, with a store of that principal. `settings`, `plans`, `projects`, `recipes`, the collector, the display holder of the session, the console, the assistive holders, the clipboard.
- **Machine-scope.** One process for the machine, of principal 0. It holds no clear data of a named principal past the call that carries it.

**The closed list of joint processes.** These processes meet the data of more than one principal, and no form removes them: the kernel, the core of the root service, the storage service (it holds the store key of each open session), the seat (it holds the pixels and the keys of the session in front, one at a time), the input service, the network service, `unlock` and the TPM service (one principal at a time), `remote` and `remote_display`. Each one gets the independent review of `AGENTS.md`. The tool keeps the list: a row of `start_grant_sets` states its scope, and `modustool check` refuses a machine-scope row with the grant `Store` that is not in the list.

Why this form: a filter by principal inside one process must be right in each export, for ever. A process for each principal is right by construction, and the kernel enforces it. The collector already has this form ("One collector for each principal").

The cost: memory and process slots for each open session. Section 4.8 bounds it.

### 4.2 The identity: a key, an identifier, a slot

Three names for three concepts. Today one number does the three jobs.

| Name | What it is | Where it lives |
|---|---|---|
| The identity key | The public key that names the principal in a grant, on each machine | In signed records |
| The principal identifier | 64 bits of the hash of the identity key. The storage service checks at a creation that no store of the disk holds it | On the disk: the owner field of each store, the collector index, the file of the principal |
| The slot | A small number of this run: the index of the tables of the root service, bits 48 to 62 of the grant of a connection | In memory only, and in the index of the TPM pin |

Rules:

- No slot is written in a store name, in a store or in a signed record. The store keeps its owner as a field of its record in the storage service, beside its name. `principals.store_name_principal`, which reads the owner from the text of a name, goes.
- The payload of the TPM pin gains the principal identifier. A slot whose pin names another identifier is refused.
- The name of a principal is a label for the chooser. It is never a key of anything. Two principals can ask for the same name; the creation refuses the second one on this machine only.

**The identity key from the first day.** `several_machines.md` gives a principal a root key at its first join of a second machine. A grant made before that join then names a key that is not the identity. Recommendation: `unlock` makes the root key at the creation, signs the first machine list of one row, and keeps the secret root key sealed under the unlock key of the principal. The principal takes it offline when it joins a second machine, and the machine then erases it. Before that, the root key is as safe as the keys of the one machine, which is the whole principal anyway.

This contradicts `several_machines.md` ("on no machine of modus"). The owner decides. The other form is two paper secrets at each creation; the form to refuse is one paper secret that gives both the recovery key and the root key, because a recovery is typed on a system whose measure changed.

### 4.3 The authority: no administrator, machine grants

Three forms look right and fail. They are in section 5 (R1, R2, R3). The form that holds:

- **The machine grants** are four rows of the disk grant table of principal 0: `Admit_Principal`, `Remove_Principal`, `Machine_Budgets`, `System_Plan` (the system plan includes the choice of a start policy and of the holders of the trusted path). Each row names the identity key of a named principal.
- **The use of a machine grant** is a machine console: a console that acts for principal 0, which the root service starts in the session of the holder after the proof of its passphrase in `unlock`, as a wide grant is given. It has a time bound of one hour. The seat shows a mark while it holds. Each act is an act record of the machine audit space (section 4.13).
- **The first holder.** While the machine has no named principal, it runs as layer 2 does today: the console of the boot acts for principal 0. The creation of the first named principal gives it the four rows. From then on, no console acts for principal 0 without a proof, and the seat with no session in front shows the chooser only.
- **A holder gives a row to another principal**, and removes its own. The last row of `Admit_Principal` cannot be removed.
- **The way back.** The recovery key of the machine key gives the four rows to a named principal that exists. So the loss of each holder is not the loss of the machine.
- **What no machine grant gives:** the read of a store of a named principal, a reset of a passphrase, a session of another principal, an answer to the dialog of another principal.

Property 21, defect 4, already says it: "the principal that holds the handle to the system description can change the system. This is one handle. It can be delegated."

**Push back on property 20, line 18.** "The principal, present at the machine, is the only source of new grants." With several principals, "the principal" has no single meaning. The property needs: the principal of a session is the only source of the grants of that session; the holder of a machine grant is the only source of a grant of the machine.

### 4.4 The seat, and the states of a session

Today one state, `Unlocked`, means three facts: the keys are open, the processes run, the session holds the screen. Split them.

| State of a session | Keys | Processes | Seat |
|---|---|---|---|
| `Locked` | Erased | Stopped | None |
| `In_Front` | Held by storage | Run | One seat |
| `Behind` | Held by storage | Run, with the limits below | None |

The state of a seat is a second enum: `Chooser`, `Unlock_Window`, `Session(slot)`, `Admission` (section 4.9).

**Two steps, in this order.**

- **Step A: one open session for the machine.** A switch is a lock: the processes of the session stop, as today. `Behind` does not exist. This step has no channel between two running sessions, and the lowest cost.
- **Step B: sessions behind.** The session keeps its processes and its keys while another session is in front. It is the "narrow and visible grant" of property 21: a plan-only value of the principal (it lowers a protection), with a time bound after which the session locks.

**The rules of `Behind`.**

- The root service revokes each handle of a seat device: the screen, the keys, the pointer, the microphone, the camera, the audio output, a removable disk that the principal picked. Without this rule the session of alice records bob through the microphone.
- A grant dialog of a session behind waits. It shows only when its session is in front.
- The way back to `In_Front` is the passphrase, proved by the TPM in the proof mode of `unlock`. A compare with a kept value is the defect 3 of property 21.
- `lock()` stays the strong act: keys erased, processes stopped.

### 4.5 The trusted display and the input

Split the role of the display in two scopes, as property 23 allows ("a nested compositor").

- **The seat holder** (machine-scope, of the signed image or chosen by the system plan, measured into PCR 12). It owns the scanout, the route of the input, the key that always reaches the system, the chooser, the windows of `unlock`, each grant dialog, each mark. It keeps no window content of a session that is not in front.
- **The display holder of a session** (session-scope, replaceable by the plan of its principal). It owns the windows, the bar, the palette and its ranking, the clipboard, the notifications, the switcher, the role store of the display. It dies at the lock of its session.

Rules:

- A surface of `unlock` is in no capture: not in the copy of the screen that `remote_display` reads, not in `Screen_View`. This closes F16.
- **The unlock hints.** The file of a principal gains a public part, covered by the additional data of the seal: the layout of the keyboard at the last passphrase, the language, and the assistive needs (speech, magnifier). The seat applies them when the principal is chosen, and shows the layout by its name. This closes F11. The cost is stated: any person at the keyboard reads the hints.
- The seat has an assistive holder of the signed image for its own surfaces. A principal who does not see must be able to unlock.
- The chooser lists the names by default. A plan-only value of the system plan makes it ask for the name.

### 4.6 The stores, their keys and their quotas

- **Encryption first.** The storage service encrypts each store of a named principal under a key derived from its unlock key. `unlock` gives the key at the unlock; the lock erases it. Then "without the key, the documents cannot be read" (property 21) is true, a number used again gives no clear data, and a removal is the erase of one key.
- **The owner is a field.** See 4.2.
- **A block budget for each principal.** The system plan gives each principal a count of blocks at its admission. The principal divides it among its stores with its own plan (`store_blocks`). The sum of the budgets is never above the disk: no overcommit. A principal sees the free blocks of its own budget and no count of the disk.
- **No sharing of blocks across principals.** Each principal pays each block of its stores. A block shared by content between two principals is an oracle: one learns that the other holds a file.
- **The caches are session-scope.** A realisation, an object by hash, a font or a language pack that one principal fetched is not given to another principal from a common cache. The exception is the signed boot image, which each principal reads.
- **The versions and the retention.** The retention rule stays a value of the system plan. A principal can only keep less, inside its own budget.

### 4.7 Settings, plans and role stores

`module_settings.md` (branch) already gives the precedence: locked by the system plan, chosen by the principal, plan default, contract default. It needs one addition for several principals.

- **A role store has a scope.** The store of a session-scope role is a store of the principal. The store of a machine-scope role is a store of principal 0.
- **A setter of a named principal never writes a machine-scope value.** The values of the seat (its scale before a session, its layout before a choice, its language) change only through the system plan. Else each such value is a channel from one principal to the next.
- **The settings page of the machine** carries the values of the seat only. The presentation record of each window carries the values of the session.
- `plans` runs one time for each principal. The instance of principal 0 gives the roles and the plan values to the core, as today.

### 4.8 The budgets

One budget object of the kernel for each principal, made by the root service at the first unlock, as it makes the one budget of the disk processes today.

- It holds pages, process slots, thread slots, processor share and log records. Each process of the session is paid from it.
- The amounts are plan-only values of the system plan (`Machine_Budgets`).
- The slots are reserved, not shared. With 64 process slots, the system plan can admit only as many open sessions as the slots allow. Step A needs the budget of one session. Step B needs a measure of the slots that one session uses before any promise.
- The budget of the disk processes becomes a part of the budget of each principal (F13).
- The client table of `remote` keeps a fixed count of rows for each slot, as its `#assert` already demands.

### 4.9 The creation

1. A holder of `Admit_Principal` asks in its machine console: `principal_create("bob")`, with the budgets of bob.
2. The seat goes to the state `Admission`. The session of the holder leaves the seat (it locks in step A, it goes behind in step B). No session is in front, so no viewer and no agent sees the seat.
3. Bob types the passphrase two times. `unlock` makes the keys, the recovery key, the root key and the principal identifier, and shows the recovery key. The file is written after Enter, as today.
4. The root service takes the record, writes the act record of the admission, and starts the session of bob.

The lock rule of today still holds: nothing is written before Enter, so a stop loses nothing. The `#assert(PRINCIPAL_CAPACITY == 2)` names the case that must be designed: a stop between the write of the file and the record. With the principal identifier in the file and in the pin, the next start of `unlock` finds the file and gives the record; the admission is complete only when the machine audit space holds its record, and a file with no admission record is shown to a holder of `Admit_Principal`, never opened.

The object `principal` of the store of `unlock` becomes one object for each principal identifier.

### 4.10 The TPM

- **One count for each principal.** The shared count of the TPM makes a co-user a means of denial (F6). The direction: an NV index of the type "PIN fail" for each principal, whose own count and limit the TPM keeps, and a sealed object whose policy names that index. A wrong try then spends the count of one principal. The reset of that count must need the recovery key of that principal, never a command that a process of the system can send alone. **Not verified:** I did not check the exact commands against the TPM 2.0 library specification, nor the NV space of a hardware TPM for 64 pins of 120 bytes and 64 PIN indexes. This needs a study of its own before a decision.
- **If that form does not hold,** state the denial in the guide, and keep Ctrl+R: the recovery key opens the keys during a lockout. Do not add a count in `unlock`: a restart resets it, as the intent file says.
- **A seal that an update keeps.** The signed policy of the publisher with the version floor (`docs/PRINCIPALS.md`, section 9) comes before layer 4. Else each update asks each principal for a recovery key, the absent ones cannot seal again, and people keep the recovery key beside the machine.
- **PCR 12 in the seal gives nothing against the holder of `System_Plan`.** A hostile seat holder records the passphrase; the holder then starts the signed system and types it. Do not add it and do not claim it. What a principal gets is a fact: the machine audit space shows each change of a holder of the trusted path, and the chooser shows a mark when the seat holder is not the one of the signed image. A hostile holder can hide that mark; the remote attestation of layer 5 is the check that it cannot hide.
- **The removal of a pin.** See 4.14.

### 4.11 Remote sessions

- A connection of `remote_display` is a seat. Its seat holder is a second instance with a screen of memory. A session is on one seat at most; a session that goes to another seat leaves the first one.
- A remote seat attaches to an open session only. It opens no locked session: the input of a viewer never reaches a window of `unlock`, and that rule stays. A remote unlock needs a key that the TPM releases to a signature of the client; it is a later design, and a `Maybe` entry.
- A remote seat has no chooser: a client key names one principal, so a viewer never lists the principals of a machine.
- **The client table is keyed by the pair of the principal and the key.** The handshake names the principal identifier. Two principals can allow one key, and neither learns it. The state `Contested` and the refusal `Exists` go (F12).
- `Calls` of a principal hold while its session is open, in front or behind. They hold nothing while it is locked, as today.

### 4.12 Shares between two principals

One record for one concept: the signed grant of `several_machines.md`, "Sharing between two principals", with this machine as the serving machine. No local table "store X for principal 2".

The problem that the local case adds: the store of the giver is encrypted under a key that the lock erases. Two forms, in this order:

1. **The handover.** The giver sends a copy of an object, sealed to the public unlock key of the receiver, into a place that the budget of the giver pays until the receiver takes it. The receiver takes it with an act in its own session (a picker row). It works in step A, where two sessions are never open together. It needs no live key.
2. **The live share.** The grant carries the key of the shared subtree, wrapped to the public unlock key of the receiver. The storage service serves it while the session of the receiver is open. The giver pays the blocks; the grant bounds what a receiver with `Write` can add. A revocation ends the service at once and changes the subtree key for each later write. The receiver keeps what it already read: say so on the screen of the share.

A share is a channel that both sides chose. It is the one accepted channel between two principals.

### 4.13 The audit, the log and the wide grants

- **The log scope by principal.** "The whole log" becomes "the log of the principal": the records of the processes of the session of the caller. The root service gives the log service the principal of each process slot and serial. A named principal reads no record of the kernel, of principal 0 or of another principal. The machine console reads the records of principal 0. This closes F5, and it is what `wide_grants.md` already promises for `Log_Read`.
- **The lines of the root service about a session** (a start, a lock, an unlock) are records of that session. They are not records of principal 0.
- **One collector for each principal**, as built. Its store is a store of its principal, encrypted. An act that the root service does for a principal whose session is locked waits in the root service, in a bounded queue, for the next unlock; a full queue refuses the act (no act without its record).
- **The machine audit space** is an audit space of the collector of principal 0. It holds each use of a machine grant: an admission, a removal, a change of a budget, each apply of the system plan, each change of a holder of the trusted path, each change of a row of the machine grants. Each admitted principal reads it. It holds no time of a lock or an unlock of a principal. An audit space is append-only and has a bound: the system plan gives it its blocks, and a full machine audit space refuses each use of a machine grant until a holder ends it with its end record.
- **The authority key of the wide grants is derived for each principal** (keyed hash of the key of the run over the principal identifier). A collector receives its own key only. The proof serial is one sequence for each principal. This closes F15.
- **A wide grant belongs to one session.** "Until the lock" ends it at the lock. `Screen_View` and `Input` hold only while the session is in front on a seat. The mark shows on the seat of that session only.
- **The proof for principal 0 changes.** `wide_grants.md` proves principal 0 with the machine passphrase. With machine grants, an agent that acts for the machine is given by a holder of the machine grant, with the passphrase of that holder. The machine passphrase stays the secret of the boot only (R2).

### 4.14 The removal

Property 21 says: "the root handle is dropped and the whole tree goes with it". It is true only if one key holds the tree. With 4.6 it does.

**Who.** The principal, with the proof of its passphrase. Or a holder of `Remove_Principal`, with no consent of the principal: a person who left, or who lost both secrets. This is the power to destroy, which the holder of the hardware has anyway (constraint 3).

**The steps**, as one state machine whose state is durable before the first destructive step:

1. Write the state `Removing` with the principal identifier in the machine audit space and in the pin of the slot. From here no unlock of this principal starts, on this start or on the next.
2. Lock the session. Revoke each client key row, each share that the principal gave and each handle of them.
3. Erase the file of the principal and its versions (`Versions_Erase`). The stores are now unreadable.
4. The storage service ends each store whose owner field is the identifier, and gives the blocks back to the budget of the machine.
5. Write the pin of the slot as free, with a generation above the last one. Write the act record of the end.

A start of the machine that finds `Removing` goes on at the first step that is not done.

**The pin.** Today a pin whose file is absent refuses each creation, and only a clear of the TPM ends it (F8). The removal needs a third payload beside "pinned" and "announced": "free, generation g". Only the system writes it, under the policy of the index, so a writer of the disk who removes the file still gets the refusal of today.

**What a removal does not reach.** A copy that a receiver of a handover took. A signed grant that left the machine: it ends with its life, or the principal signs a revocation list before the removal. The act records about the principal in the machine audit space, which name its identifier and stay.

### 4.15 Covert channels between principals

The realistic attacker is not a person. It is a process with no network in the session of alice that sends her data to a process with a network in the session of bob.

| Channel | Step A (one open session) | Step B (sessions behind) | Answer |
|---|---|---|---|
| Free blocks of the disk | Open | Open | Closed by 4.6: a budget for each principal, no overcommit |
| Blocks shared by content | Open | Open | Closed by 4.6 |
| A common cache (realisations, objects, fonts, DNS, HTTP) | Open | Open | Closed by 4.6 and 4.1: session-scope caches. The network service is a joint process: its caches must be keyed by the principal or dropped at each switch |
| A machine-scope setting | Open | Open | Closed by 4.7 |
| The whole log, the lines of a session | Open | Open | Closed by 4.13 |
| The clipboard, the palette ranking, the notifications | Open if the compositor stays | Open | Closed by 4.5: they die with the display holder of the session |
| The client table (`Exists`, `Contested`, `Full`) | Open | Open | Closed by 4.11 and 4.8 |
| The count of the TPM | Open | Open | Closed only by a count for each principal (4.10). Else stated |
| The process serial, the numbers of handles, the numbers of objects | Open: a number that grows across sessions counts the work of the other | Open | Reduce: a process reads no serial of a slot that it does not hold. To check, per interface, with the test of property 20 |
| Process slots, thread slots, pages | None: one session | Open if shared | Closed by reserved budgets (4.8) |
| The time of a call of a joint process (storage, network, seat) | None | Open | Not closed. The work accounting bounds the rate |
| The processor: caches, frequency, the load | None | Open | Not closed (property 20, line 17). The scheduler can keep two sessions off one core at one time |
| The network: one address, the ports | None | Open | Not closed |
| A seat device that stays open | None | Open | Closed by 4.4: revoked at the switch |

So step A closes each channel but the residue that a disk and a counter keep. Step B opens the timing channels, and the guide must say it. Each open channel gets a measure, not a claim: a pair of test modules that sends bits through it and prints the rate (`AGENTS.md`: "A claim of speed has a measured number").

## 5. The refused forms: they look right and fail later

| # | Form | Why it looks right | Where it fails |
|---|---|---|---|
| R1 | **No authority at all: each principal is equal** | "No root" (property 20, line 18) | Any person at the keyboard creates principals until the table and the pins are full. Nobody removes the data of a person who left. The disk fills with stores that no key opens |
| R2 | **The machine passphrase opens a session of principal 0, the administrator** | It exists, and principal 0 already owns the system | It is the secret of the boot: each person who must start the machine holds it. Two holders share one secret, an act names no person, and the removal of one holder changes the secret of all. Principal 0 becomes a person, which `docs/PRINCIPALS.md` refuses |
| R3 | **The first principal is the owner for ever** | The usual form of a desktop system | The loss of one passphrase and one recovery key is the loss of the machine. It needs a transfer and a way back, which is 4.3 |
| R4 | **An authority that resets a passphrase or reads a store "in an emergency"** | Each support desk asks for it | It is a second key of each principal. Property 21, "Cost", refuses it. A principal who wants it can make a recovery contact itself; see section 9 |
| R5 | **Raise `PRINCIPAL_CAPACITY` and keep the rest** | The tables are already indexed by the number; the stores are already disjoint by name | F1 to F16. In order of harm: clear stores, the whole log, the console of principal 0 with no proof, the shared compositor |
| R6 | **One compositor that tags each window with its principal and hides the others** | No new process, no hop | Each feature needs its filter: the clipboard, the notifications, the switcher, the palette ranking, the capture, the semantic tree, the magnifier, a drop. One missing filter is a leak, and each new feature adds one. The role store mixes the principals |
| R7 | **Machine-scope `settings`, `plans`, `recipes` with a table for each principal** | It is the code of `plans` today | The data of a named principal is then in a store of principal 0: in clear while locked, kept after a removal, and one fault of an index gives one principal the row of another |
| R8 | **The number as the identity, never used again** | No reuse, no confusion | 64 pins for the life of a TPM. A disk moved to another machine carries numbers that mean other principals there. A signed grant cannot name a number |
| R9 | **The number used again after a removal, with clear stores** | The table has a free place | A store that the removal missed, or that a writer of the disk put back, opens for the new principal |
| R10 | **A switch that keeps the session and checks the passphrase with a compare** | Fast, and the keys are already open | It is the password compare that property 21 removes. A fault of the compare gives the session; a fault of an unseal gives nothing |
| R11 | **A session behind that keeps its devices** | Music and calls go on | The session of alice hears and sees bob |
| R12 | **PCR 12 in the seal of a named principal, to protect it from the holder of the system plan** | The seal then names the trusted path | The hostile holder records the passphrase and types it on the signed system. The only effect is a recovery key at each change of a holder |
| R13 | **A count of the tries in `unlock` for each principal, to protect the shared count of the TPM** | It stops a co-user who mistypes on purpose | A restart resets it. The intent file refuses it already. It also hides the true fault, the shared count |
| R14 | **A local share table, by the number of the receiver** | Short, and no signature is needed on one machine | A second mechanism beside the signed grant. It breaks when one of the two joins a second machine, and it cannot serve a giver who is locked |
| R15 | **A common folder, or a group of principals** | People ask for it | Property 8 and property 21, defect 5. A share to each receiver gives the same result with one mechanism |
| R16 | **A live share served by the key of the giver that the storage service keeps after its lock** | The share works while the giver is away | It is a key that stays, wide and not visible: the whole store key, for one subtree. The wrapped subtree key of 4.12 is the narrow form |
| R17 | **A remote unlock: the passphrase typed by a viewer** | A principal away from the machine wants its session | The input of a viewer never reaches a trusted surface. One exception for `unlock` gives each stolen client key a place to try passphrases, and each try spends the count of the TPM |
| R18 | **One authority key for the wide grants of each principal** | One key, one start value | The field `principal` is under the tag, but each collector can make the tag |
| R19 | **A principal reads the acts of the machine only if it holds a machine grant** | The audit of the machine is the business of its owner | A named principal trusts the holder of the system plan with its passphrase. The least that it is owed is the list of what that holder changed |
| R20 | **Overcommit of the block budgets** | A disk is rarely full | The refusal of a write then depends on the stores of another principal: a denial and a channel |
| R21 | **A machine-scope cache of realisations by the hash of the recipe** | One build serves each principal | Bob writes a false realisation under the hash that alice will ask for. The roadmap entry "A local realisation signed with the key of the principal" is the form that holds: alice takes a realisation only under a key that she trusts |
| R22 | **One paper secret that gives the recovery key and the root key** | One paper to keep | A recovery is typed on a system whose measure changed. That system then holds the identity of the principal on each machine |

## 6. What contradicts a property or an intent file

The rule "Push back" of `AGENTS.md` asks for these to be said first. The owner decides each one; the property or the intent file changes before the code.

1. **Property 21, layer 4**: "disjoint handle trees, no kernel change". Keep "no kernel change". Add: each service that keeps data has a scope, and the stores are encrypted, before the layer is claimed.
2. **Property 20, line 18**: "The principal, present at the machine, is the only source of new grants". See 4.3.
3. **`docs/PRINCIPALS.md`, section 2**: "The stores of the system (the settings, the line history of the console) are stores of principal 0". The settings of the seat stay there; the choices of a named principal leave.
4. **`docs/PRINCIPALS.md`, section 9**: "one session at a time on the desktop, or one desktop for each session". This study says: both, in the order A then B, with the seat.
5. **`several_machines.md`**: the root key "on no machine of modus". See 4.2.
6. **`tpm_sealed_principal_keys.md`**: "Only a clear of the TPM ends it", and the count shared with each principal. See 4.14 and 4.10.
7. **`wide_grants.md`**: the proof of principal 0 by the machine passphrase, and the one authority key. See 4.13.
8. **`log_reader_scope.md`**: "The whole log: the caller acts for the principal". See 4.13.
9. **`remote_display.md` and `docs/PRINCIPALS.md`**: "One key belongs to one principal". See 4.11.

## 7. The implicit state machines to make explicit

Each one is a closed enum with one place that changes it.

- The session of a principal: `Absent`, `Creating`, `Locked`, `In_Front`, `Behind`, `Removing`.
- The seat: `Chooser`, `Unlock_Window`, `Admission`, `Session`.
- The pin of a slot: `Free`, `Pinned`, `Announced`, `Removing`.
- A machine grant in use: `None`, `Proof_Asked`, `Holds`, `Ended`, as a wide grant.
- A share: `Offered`, `Taken`, `Revoked`, `Ended`.
- The one `unlock` of the root service (`Unlock_Stage`) gains the principal that it runs for. One `unlock` at a time stays right: it is the one queue of the TPM.

## 8. The order of the work

Each step adds one capability to a system that works.

1. **The stores of a named principal encrypted** under its unlock key (layer 3, not built).
2. **The seal that an update keeps** (the signed policy, with the version floor).
3. **The principal identifier**: the owner field of a store, the file of the principal, the pin payload, the collector index. No slot on the disk. Still one named principal.
4. **The log scope by principal**, and the lines of a session as records of that session.
5. **The seat**: the seat holder and the display holder of a session, with one named principal. The chooser replaces the desktop of principal 0 while a named principal is locked. The surfaces of `unlock` leave each capture.
6. **Session-scope `settings`, `plans` and role stores**, and the unlock hints.
7. **The machine grants and the machine console**, and the machine audit space. Still one named principal: it holds the four rows.
8. **The budget of a principal** (pages, slots, blocks), and the client table keyed by the pair.
9. **The removal**, with the free pin. Tested with one principal: create, remove, create.
10. **A second named principal: step A.** The capacity grows only here.
11. **The handover.**
12. **The count of the TPM for each principal**, if its study holds.
13. **Step B: sessions behind**, after a measure of the slots and of the channels. Then the live share and the remote seat for a session behind.

Steps 1 to 9 each improve the system of one principal. The second principal arrives at step 10, on a system where it finds no shared place.

## 9. The tests that try to break it

The single test that breaks a wrong design on the first day: **two principals, and for each export of each service of the image, bob asks for a byte, a count or a refusal that depends on alice.** In detail:

- Bob opens, lists, sizes and names each store of alice: each one is refused with `No_Grant`, and no list or count changes when alice writes.
- Bob reads the log while alice starts and stops processes: no record, and no gap in his own numbers.
- Bob allows the client key that alice allowed: accepted, and neither state changes.
- Bob fills his block budget: a write of alice still holds.
- Bob starts processes to his slot limit: a start of alice still holds.
- The tool reads the image of the disk on the host after a lock of alice: none of the bytes of her note is there in clear.
- A slot used again: remove alice, create carol in the same slot, put the stores of alice back on the disk from a copy: carol opens none.
- The power is cut at each step of a removal: the next start ends the removal, and no passphrase of alice opens a session.
- The session of the holder of a machine grant has a viewer with `Screen_View` during an admission: the viewer receives no frame of the window of `unlock`.
- Bob sets another layout, locks; alice types her passphrase with the keys of her layout: it opens, with no failure counted.
- The collector of bob receives a proof record made with the key of the collector of bob for a grant of alice: the collector of alice refuses it.
- The last case of each: the two principals each write a note, lock, unlock, and find their own note.

## 10. Open questions

1. **The count of the TPM for each principal.** The commands, the reset by the recovery key, the NV space of a hardware TPM. A study of its own.
2. **A recovery contact.** A principal seals a second recovery copy to the public key of another principal, by its own act, visible and recorded. The pin of the file bounds an old copy. It is a `Maybe` entry; it waits for a person who asks.
3. **A remote unlock** by a key of the client that the TPM takes in a signed policy. It is a "key that stays available"; it waits for the remote seat.
4. **The work of a locked principal** (a scheduled job, a sync): a key sealed to the TPM alone, for one store and one module hash. `wide_grants.md` already leaves it open for the scheduled agent. One design must serve both.
5. **The network service as a joint process**: which of its states (the resolver cache, the connections, the address) a switch must drop. Not read in this study.
6. **The slots that one session costs**, measured, before step B is promised.
7. **The machine with no TPM.** The count of the tries does not exist there; the form `PRINCIPL` falls to a copy of the disk and Argon2id. Whether such a machine admits a second named principal is a plan-only value of the system plan, as the join of `several_machines.md` is.
