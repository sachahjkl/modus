# Several principals on one machine: a critique of two studies

Two studies answer one question: how several named principals use one machine (layer 4 of [`docs/PROPERTIES.md`](../PROPERTIES.md), "21. Principals: who acts, without users").

- **The first study** is [`several_principals_study.md`](several_principals_study.md), with the proposed intent file [`src/md/features/several_principals.md`](../../src/md/features/several_principals.md). It compares three designs and recommends a seat with a display holder for each session, with one session at a time as its first layer.
- **The independent study** was written without a read of the first one, and it is not a file of the repository. It starts from the code: sixteen facts that break with a second named principal, one invariant, and twenty-two refused forms.

This critique attacks both, decides each disagreement, and gives one recommendation, one order of work and the decisions that remain. It changes no code.

## 1. The verdict

- The two studies agree on the end form: one seat that owns the screen, the input and the trusted path, and one display holder for each session. That form stands.
- The first study has the better prior art and the better comparison of designs. Its order of work is wrong: it builds several principals first and repairs the shared places after.
- The independent study has the better reading of the code and the better order. It adds more mechanism than the problem needs, and it hides one contradiction with property 23.
- The joint form takes the order of the independent study and the designs of the first study, and removes mechanism from both.
- Nine layers of work need no decision. Each one improves the system of one named principal. Eight decisions gate the rest.

## 2. Where the studies agree

These points have two independent sources. Take them as settled.

1. No kernel change. A frozen session is refused.
2. One compositor that tags each window with its principal is refused.
3. The seat owns the screen, the input devices, the key to the system, the prompt of `unlock` and each trusted surface. A session has its own display holder.
4. "The session in front" is a fact of its own. It is not "the principal that is unlocked".
5. The way back to a kept session is the passphrase.
6. The authority over the machine is a revocable grant of principal 0 to a named principal. The first named principal gets it. It reads no store of a named principal.
7. The machine passphrase is not the authority over the machine.
8. The creation of a principal runs on the seat with no session in front.
9. A holder of the authority removes a principal with no passphrase of that principal, and reads nothing.
10. The stores of a principal are encrypted before a second named principal ships.
11. The log is split by principal. The settings of a principal leave principal 0. The clipboard is not shared.
12. Each session has a budget. A session meets its own limit, never the limit of the machine.
13. A count of the TPM for each principal is later work, and it needs a study.
14. The prompt lists the names by default. A value of the plan of principal 0 hides the list.

## 3. Where the studies disagree

| # | Subject | The first study | The independent study | The decision of this critique |
|---|---|---|---|---|
| 1 | The order | N records at layer 3, encryption at layer 6, the seat at layer 8 | Encryption, the identifier, the log, the seat and the authority first; the second principal at step 10 | The independent study, with one change: no split of the compositor before the second principal (section 6.1) |
| 2 | The identity | The number, never used again | An identity key, a 64-bit identifier from its hash, a slot | Three names, but the identifier is random and has no link to a key (section 6.2) |
| 3 | The authority | One machine grant | Four machine grants, a machine console, a way back | One row form with two scopes; its use is a wide grant for principal 0 (section 6.3) |
| 4 | The creation | An invitation with a name and an end time, taken later at the prompt | An admission: the holder asks, and the seat changes at once | The admission. The invitation waits for a person who asks |
| 5 | Kept sessions | The normal form of the last design | A narrow, visible grant with a time bound; each seat device revoked | The independent study |
| 6 | A share on one machine | A row of the disk grant table of the giver | The signed grant only; a handover, then a live share | The signed grant only, as the last layer; the handover is refused as a first form (section 6.5) |
| 7 | The settings | A settings page for each session; the layout of the prompt is a setting of the machine | A session-scope `settings`; the layout of each principal in the public part of its file | The independent study |
| 8 | The removal | A list of five steps | A durable state machine, and a third payload of the pin | The independent study, with the state in the record of the principal |
| 9 | The services that keep data | A table keyed by principal in each service | One process for each principal, and a closed list of joint processes | The independent study, with a wider check (section 5.1) |
| 10 | The count of the TPM | An NV count that the system writes, with `TPM2_PolicyNV` | An NV index of the type "PIN fail" | Neither is proved. The first form is refused; the second needs its study (section 6.6) |
| 11 | A seal that an update keeps | Not named | A work before layer 4 | A gate of the second principal, not of the earlier layers |
| 12 | The machine audit | The switches as act records of each principal | A machine audit space that each admitted principal reads | The independent study |

## 4. The faults of the first study

1. **The order builds the leak, then repairs it.** Layer 3 gives N records with stores in clear, one compositor that outlives each lock and `plans` with one process for all. Layer 6 and layer 8 then write the same parts again.
2. **"Ready for several principals" is false for three parts.** `plans` keeps the data of a named principal in a store of principal 0: in clear while that principal is locked. Each collector receives the one authority key of the wide grants. One client key belongs to one principal, so a second principal learns that a key is allowed.
3. **The number and the pin contradict each other.** The pin index is `0x01806E00 + n`, with n from 1 to 64. A number that is never used again ends at 64 principals for the life of a TPM. "The pin index is by place" needs a map from a place to a number, and the study gives none.
4. **The removal ignores a refusal that is built.** `principal_create` is refused while a pin names a file that the disk no longer holds, and only a clear of the TPM ends it ([`tpm_sealed_principal_keys.md`](../../src/md/features/tpm_sealed_principal_keys.md), "A removed file"). "Erase its pin index" is not a design.
5. **The removal has no state.** A stop of the machine between two steps leaves a principal with no file and with stores. No rule says what the next start does.
6. **The count for each principal fails the intent file of the TPM.** A count that the system writes is a count that a process of the system resets. The intent file refuses that form for `TPM2_DictionaryAttackLockReset`, for the same reason.
7. **A session behind keeps its devices.** The study revokes the keys and the pointer only. The microphone, the camera and the audio output stay open, so the session of one principal records the next one.
8. **The layout of the prompt is a setting of the machine.** A principal with another layout types wrong passphrases, and the TPM counts each one.
9. **The machine grant has no way back.** The loss of the passphrase and of the recovery key of its one holder leaves a machine that nobody changes.
10. **The machine grant is oversold.** "It gives no right to read the data of another principal" is true for access only. Its holder chooses the holders of the trusted path, and a hostile holder records each passphrase.
11. **The invitation proves nothing.** A name and an end time let any person at the keyboard become that name. The record adds a state and removes no risk.
12. **The local share is a second mechanism.** A row of a disk grant table beside the signed grant contradicts the Objective, rule 1, and property 22.
13. **Layer 2 has no authority yet.** The console of principal 0 closes at layer 2, and the machine grant comes at layer 4. Between them, the machine passphrase is the authority, which the study itself refuses.

## 5. The faults of the independent study

1. **The closed list of joint processes is not closed.** The log service holds the records of each principal, and the list does not name it. The process `scheduler`, the delegated service `principals`, the powerbox, the disk process service and the audio service are absent too. The proposed check reads the grant `Store` only, so it never finds a joint process that keeps its data in memory.
2. **The session display "replaceable by the plan of its principal" contradicts property 23.** The property gives a role of the trusted path to a holder of the signed image or to a choice of principal 0: "No other principal chooses it." The study lists nine contradictions, and not this one.
3. **Four machine grants are two levels of trust.** The holder of `System_Plan` chooses the trusted path, so it reaches everything. The three others destroy and deny only. No difference of trust separates `Admit_Principal`, `Remove_Principal` and `Machine_Budgets`.
4. **"A machine grant in use" is a wide grant with another name.** The study gives it a state machine "as a wide grant". Two state machines for one concept contradict property 22.
5. **A 64-bit identifier can be forged.** A search of 2^64 keys finds an identity key with the identifier of another principal. The identifier then decides the owner of a store and the name in an act record.
6. **The identifier forces a decision that it does not need.** An identifier from the hash of the identity key needs the identity key at the creation. That contradicts [`several_machines.md`](../../src/md/features/several_machines.md), which keeps the root key on no machine. Step 3 then waits for a decision of layer 5.
7. **The handover is a third mechanism.** A copy sealed to the unlock key of the receiver uses neither the record nor the check of the signed grant. The study refuses a second mechanism in R14, then adds one in step 11.
8. **The state of a removal is in an audit space.** An audit space is a record of acts. A state that the next start must read belongs in the record of the principal.
9. **A full machine audit space closes itself.** It refuses each use of a machine grant, and only a use of a machine grant ends it.
10. **The split of the compositor comes before the second principal.** It is the largest work of the list. A fresh display process for each session gives the same separation in the first step (section 6.1).
11. **A remote seat and the passphrase contradict each other.** The way back to the front needs the passphrase, and the input of a viewer never reaches `unlock`. So a remote seat either attaches with the client key alone, or never attaches to a session behind. The study does not choose.
12. **The count for each principal has a cost that the study does not state.** A count with a limit and no recovery time lets a person at the keyboard force another principal to its recovery key, at will. People then keep the recovery key beside the machine.
13. **Three works "before the first line" block cheap repairs.** The log scope, the capture of `unlock` and the authority key for each principal need no encryption. They are independent layers.

## 6. The joint recommendation

**The invariant.** No process holds the clear data of two named principals, at one time or one after the other, unless the list of joint processes names it. The tool checks the list (section 6.4).

**The states.** A session is `Absent`, `Creating`, `Locked`, `In_Front`, `Behind` or `Removing`. A seat is `Chooser`, `Unlock_Window`, `Admission` or `Session`. Each is a closed enum with one place that changes it. `Behind` has no member of the code before the layer that builds it.

### 6.1 The display: a fresh process first, the seat second

- **First form, one open session.** The root service stops the display holder at each lock and starts a new one: one process for the chooser, one process for each session. No palette ranking, glyph cache, notification or clipboard of one principal stays in a process that the next one uses. The kernel enforces it. The cost is one start of the display holder at each switch: a measure to take.
- **Second form, sessions behind.** The seat holder and the display holder of a session split, as both studies propose. The cost of the hop of each frame is measured against the thresholds of property 18 before the layer starts.
- The display holder of a session is a holder of the signed image, or a choice of principal 0. A choice by its own principal needs a change of property 23 (decision 7).

### 6.2 The identity: three names

| Name | What it is | Where it lives |
|---|---|---|
| The principal identifier | 256 random bits that `unlock` draws at the creation. It never changes and it comes from no key | On the disk: the owner field of each store, the file of the principal, the payload of the pin, the collector index |
| The slot | A small number of this run: the index of the tables of the root service, and bits 48 to 62 of the grant of a connection | In memory, and in the index of the pin |
| The identity key | The public key that a signed grant names | Decided with the shares (decision 5) |

- No slot is written in a store name, in a store or in a signed record. `principals.store_name_principal` goes.
- A slot that a removal frees is not used again before the next start. An old connection then never names a new principal.
- The pin of a slot names the identifier. A file with another identifier is refused.
- A name is a label of the chooser, never a key of a table.

### 6.3 The authority: one grant form, two scopes, one way to use it

- **The row.** A machine grant is a row of the disk grant table of principal 0, tagged with the machine key. It names a principal identifier and a set of machine scopes.
- **Two scopes, because two levels of trust exist.** `Principals`: admit a principal, remove a principal, set the budgets. Its holder destroys and denies only. `System`: the plan of principal 0, the start policy, the holders of the trusted path, the device grants, the machine passphrase, the update. Its holder is trusted as the hardware is.
- **The use is a wide grant for principal 0.** The proof is the passphrase of the holder in the proof mode of `unlock`. The time bound, the mark and the act records are those of a wide grant. The proof of principal 0 by the machine passphrase goes ([`wide_grants.md`](../../src/md/features/wide_grants.md)).
- **The first holder.** A machine with no named principal runs as today. The creation of the first named principal gives it both scopes. From then on, no console acts for principal 0 with no proof.
- **The last row of `System` is never removed.** The recovery key of the machine key gives both scopes to a named principal that exists, on the chooser, with an act record.
- **The machine audit space.** Each use of a machine grant is an act record that each admitted principal reads. It is the least that a principal is owed by the holder of `System`. The act that ends a full space is exempt from the refusal of a full space.
- **The guide states the trust in plain words.** A named principal trusts the holder of `System` with its passphrase. No seal changes this.

### 6.4 The services that keep data

- A service that keeps data of a named principal runs one time for each principal, with a store of that principal: `settings`, `plans`, `projects`, `recipes`, the collector, the display holder, the console, the clipboard.
- **The list of joint processes** names each process that serves more than one named principal: the kernel, the core of the root service, the storage service, the log service, `scheduler`, `principals`, the powerbox, the disk process service, the seat, the input service, the audio service, the network service, `unlock`, the TPM service, `remote` and `remote_display`.
- **The check.** Each row of `start_grant_sets` states its scope. `modustool check` refuses a machine-scope row that serves a connection of a named principal and is not in the list. The test is the connection, not the grant `Store`.
- Each joint process gets the independent review of `AGENTS.md`, and a test with two principals for each of its exports.

### 6.5 The rest

- **The creation is an admission.** A holder of `Principals` asks. The seat goes to `Admission`, and the session of the holder leaves the seat. The new person types the passphrase two times. A file with no admission record is shown to a holder and never opened.
- **The unlock hints.** The file of a principal has a public part under the additional data of the seal: the layout in which its passphrase was typed, its language, its assistive needs. The seat applies them when the principal is chosen. The hint changes only with the passphrase.
- **A surface of `unlock` is in no capture**: not in `Screen_View`, not in the copy that `remote_display` reads.
- **The removal is a state machine.** The state `Removing` is written in the record of the principal before the first destructive step. A start that finds it goes on. The pin gains the payload "free, generation g", which only the removal writes.
- **The log.** A caller that acts for a named principal reads the records of the processes of that session only. A line of the root service about a session is a record of that session.
- **The budgets are reserved.** Pages, process slots, thread slots, log records and blocks. The sum of the block budgets is never above the disk. No block is shared by content between two principals.
- **The client table is keyed by the pair of the principal and the key.** The states `Contested` and `Exists` go.
- **A session behind is a narrow grant**: a plan-only value of its principal, with a time bound, a mark on the seat, and each seat device revoked. A remote seat attaches to an open session with its client key alone, and the guide says so.
- **A share is the signed grant, and nothing else.** No local table and no handover. It is the last layer, and it waits for decision 5.

### 6.6 The count of the TPM

- Keep the shared count now. The guide states the denial, and the recovery key is the way out.
- Refuse a count that the system writes, in `unlock` or in an NV index: a process of the system then resets it.
- The form "PIN fail" needs a study on libtpms and on one hardware TPM: the commands, the NV space, the reset. It also needs decision 6, because it changes a wait for all into a recovery key for one.

## 7. The order of the work

Each layer adds one capability to a system that works. A layer of group A needs no decision: it follows from a property or from an intent file as it is, and it improves the system of one named principal.

### Group A: work that can start now

1. **The states as enums.** The session and the session in front in the root service, apart from the set of unlocked principals. No behaviour changes.
2. **The log scope by principal**, and the lines of a session as records of that session.
3. **A surface of `unlock` in no capture**, and the unlock hints in the file of the principal.
4. **The authority key of the wide grants for each principal.** The roadmap entry of that key is built in this form at once.
5. **The principal identifier.** The owner field of a store, the file, the payload of the pin, the collector index. No slot on the disk.
6. **The stores of a named principal encrypted** under its unlock key. The lock erases the key in the storage service.
7. **A seal that an update keeps**: the signed policy with the version floor ([`docs/PRINCIPALS.md`](../PRINCIPALS.md), "9. Not built").
8. **Session-scope services, and a fresh display holder for each session.** `settings`, `plans` and the role stores of a session move to stores of the principal. The list of joint processes and its check come here.
9. **The budget of a session, the client table keyed by the pair, and the removal by the principal itself** with the free pin. The test: create, remove, create.

Layers 2, 3 and 4 are independent of each other and of layer 6. Layers 5, 6 and 9 depend on each other in that order.

### Group B: work that waits for a decision

10. **The machine grants, the chooser alone on the seat with no session, and the machine audit space.** One layer: the console of principal 0 closes only when a grant opens it. Waits for decisions 1 and 2.
11. **The removal by a holder of `Principals`.** Waits for decision 3.
12. **A second named principal, one open session.** The capacity grows only here. Waits for layers 1 to 11 and for decision 8.
13. **The seat holder and the display holder of a session; sessions behind; the remote seat.** After a measure of the slots of one session and of the hop of a frame. Waits for decision 4.
14. **The signed grant between two principals of one machine.** Waits for decision 5.
15. **The count of the TPM for each principal.** Waits for its study and for decision 6.

The work of a locked principal (a scheduled job, a sync) is later work. It shares one design with the scheduled agent of [`wide_grants.md`](../../src/md/features/wide_grants.md).

## 8. The decisions to make

Only these need a decision. Each other choice of section 6 follows from a property or is a design that an intent file records.

1. **The form of the authority.**
   - Recommended: one machine grant with the scopes `Principals` and `System`, used as a wide grant for principal 0, with the recovery key of the machine key as the way back.
   - Consequence: the console of the boot closes on a machine with a named principal. A person who holds the recovery key of the machine holds the machine. The proof of principal 0 by the machine passphrase leaves `wide_grants.md`.
2. **The wording of property 20, line 18.** "The principal, present at the machine, is the only source of new grants" has no single meaning with several principals.
   - Recommended: the principal of a session is the only source of the grants of that session; a holder of a machine grant is the only source of a grant of the machine.
   - Consequence: the property names the machine grant. Property 21, layer 4, gains: each service that keeps data has a scope, and the stores are encrypted.
3. **A removal with no consent.**
   - Recommended: a holder of `Principals` removes any principal, reads nothing, and the act is in the machine audit space.
   - Consequence: one principal destroys the data of another. Without it, a lost passphrase holds a part of the disk for ever.
4. **Sessions behind.**
   - Recommended: build one open session first; a session behind is a later, plan-only grant with a time bound.
   - Consequence: until layer 13, a switch stops the programs of the principal that leaves, and no principal works from another machine while another one is at the screen. The side channels between two running sessions do not exist until then.
5. **The moment of the identity key.** A signed grant names the root key of its receiver, and a principal of one machine has none.
   - Recommended: `unlock` makes the root key at the creation and keeps it sealed under the unlock key until the first join; the join takes it offline and erases it.
   - Consequence: [`several_machines.md`](../../src/md/features/several_machines.md) changes its refused form "the root key kept on a machine" to a principal of more than one machine. Before the join, a recovery typed on a hostile system gives the identity. The other way is a second paper secret at each creation.
6. **The denial through the count of the TPM.**
   - Recommended: keep the shared count until the study of the form "PIN fail" ends; then take that form only if the TPM alone resets its count.
   - Consequence: today a person at the keyboard makes each principal wait. With the form "PIN fail", that person sends one principal to its recovery key and touches no other.
7. **Who chooses the display holder of a session.**
   - Recommended: principal 0 only, as property 23 says, until the seat draws each trusted surface; then decide again.
   - Consequence: no change of property 23 now. A principal does not replace its own display.
8. **The gate of the second principal.**
   - Recommended: the capacity stays 2 until layers 1 to 11 are built.
   - Consequence: several principals arrive later, on a system with no shared place. The other way ships a separation that a reader of the disk breaks.

## 9. Not verified

- The TPM 2.0 rules of an NV index of the type "PIN fail" (its attributes, who resets its count) and the NV space of a hardware TPM. Neither study checked them, and this critique did not.
- That the kernel freezes no process with `Thread_Control`. The first study states it; this critique did not read the operation.
- The process slots, the memory and the start time that one session costs. No study measured them.
- The state that the network service keeps across a switch. No study read it.
- The feasibility of a search of 2^64 keys is an estimate, not a measure.
