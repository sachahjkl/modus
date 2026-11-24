# Several principals on one machine: a study

This study prepares layer 4 of [`docs/PROPERTIES.md`](../PROPERTIES.md), "21. Principals: who acts, without users": several named principals on one machine. Property 21 states the layer as a direction, "disjoint handle trees, no kernel change", not as a design. A machine that one person only can use is a limit for real use. This study finds the questions that the design must answer, so that no early choice closes the way to several principals.

The study has four parts:

1. The facts of today that constrain the design (section 1).
2. The prior art: Unix and logind, Windows, macOS, ChromeOS, Android, Plan 9, and the capability systems (section 2).
3. The questions, one by one (section 3), and three coherent designs with their costs (section 4).
4. A recommendation (section 5), the order of the work in layers (section 6), the points where the goal meets a property (section 7), and the decisions that remain open (section 8).

The proposed design is in [`src/md/features/several_principals.md`](../../src/md/features/several_principals.md).

## 1. The facts of today

These facts come from the code and the intent files of the current tree. Each one is a place that layer 4 changes.

| Part | Today | What it means for several principals |
|---|---|---|
| The records of the root service | `principal_records` has `PRINCIPAL_CAPACITY` places, and the root service asserts that this is 2: principal 0 and one named principal (`src/modules/system/root/principals.odin`) | Each rule that reads "the named principal" reads place 1. `principal_create` is refused when place 1 holds a record |
| The session in front | `desktop_principal()` gives the first named principal that is unlocked, else principal 0 | With one unlocked principal at most, "the unlocked principal" and "the session in front" are one fact. With kept sessions they are two facts |
| The lock | `principal_lock` stops each process of the session; no process is frozen, because no kernel operation freezes a process | A switch that keeps a session can not use the lock as it is |
| `unlock` | One `unlock` runs at a time. It keeps one file of a named principal, the object `principal` in its store | Several files, and a choice of the principal at the prompt |
| A creation during a session | Impossible today: a creation needs place 1 free, so no session runs. The comment of `principal_create` says that more places need a design | A creation can meet the lock of another session |
| The delegated service `principals` | It holds a mirror of the records, the sessions and the session in front (`front_principal`), with `MAX_PRINCIPALS` = 8 (`src/library/internal/principals/principals_core`) | The mirror is already shaped for several principals; the core is not |
| The stores | A store of principal N has the suffix `.principal.N` (`principals.store_name_write`). The storage service lets a caller name the stores of its own principal only (`may_name_store`) | The separation of data holds for N principals. A removal must find each store by its suffix: no one root holds the tree of a principal |
| The grant of a connection | Bits 48 to 62 of the grant word name the principal: 15 bits | 32 767 numbers. A number that comes back after a removal meets old rows, old pins and old act records |
| The encryption of the stores | Not built: the data of each principal is on the disk in clear (`docs/PRINCIPALS.md`, "9. Not built") | A second principal with the same disk reads nothing through the storage service, but a reader of the disk reads all |
| The settings | One settings page for the machine, written by `settings`, mapped by each process; the settings are stores of principal 0 | The language, the appearance and the scale are choices of a principal. One page can not show two principals |
| The log | Not split by principal: a caller that acts for principal 1 reads the records of principal 0 too ([`src/md/features/log_reader_scope.md`](../../src/md/features/log_reader_scope.md)) | A caller that acts for principal 1 must not read the records of the processes of principal 2 |
| The clipboard | One slot in the compositor | A copy of one principal must not reach the paste of another |
| The compositor | One desktop; its exports check `acts_for_principal`, not which principal | Each window and each trusted surface must name its session |
| The client table | Each row names its principal. `remote_display` shows the screen only to a row of the session in front (the flag `not_in_front`) | The rule exists; layer 4 gives it a second session to pause |
| The collector, the plans, the wide grants | One audit space for each principal; plans for each principal; a wide grant names its principal and needs the passphrase of that principal | These parts are ready for several principals |
| The kernel | `PROCESS_SLOTS_OF_THE_MACHINE` is 64; budgets form a tree; the log records of each second are divided between budgets | Two kept sessions and the services share 64 slots |
| The TPM | One count of wrong authorization values for the whole TPM. The pin of the file of principal n is at the index `0x01806E00 + n`, n from 1 to 64 | A wrong passphrase of one principal counts against each other one. The pins limit the numbers |
| The desktop while locked | The processes of principal 0 run and can be started while a named principal is locked; a desktop that shows only `unlock` is not built | Anyone at the keyboard reaches the console of principal 0 |

## 2. The prior art

Each system below answers some of the questions of section 3. For each one, the study names what it takes and what it refuses, by the rule of [`docs/PROPERTIES.md`](../PROPERTIES.md), "25. Take the gold, leave the debt".

### Unix, and logind with its seats

Unix makes the user the subject of each access check: a process carries a user identifier and groups, and the file system compares them with the owner and the mode of each file. `root` passes each check. `su`, `sudo` and the setuid bit change the identity of a process to gain access.

systemd-logind adds the concepts that a desktop needs above that model:

- A **session** is a login of one user on one seat, or a remote login. A user can have several sessions at once.
- A **seat** is a set of devices for one person: a screen, a keyboard, a pointer. A machine with two GPUs and two keyboards can have two seats.
- On a seat, one session is **active** at a time. A switch of the virtual terminal makes another session active. The other sessions keep running.
- logind gives the active session the access to the devices of the seat, and takes it back at a switch. The display server of a session that is not active loses the input devices and the master of the display.
- **Linger** keeps the services of a user running after the last session of that user ends.
- systemd-homed keeps the home of each user in an encrypted image, unlocked by the password of that user, and can lock it at suspend.

Taken:

- The separation of the **seat** (the screen and the input devices) from the **session** (what runs for a principal). This is the form of design C.
- One active session for each seat, with the device access that follows the active session.
- The encryption of the data of each principal under a key that only its secret opens, as homed does.

Refused:

- The user as the subject of access checks, groups, and `root` ([`docs/PROPERTIES.md`](../PROPERTIES.md), "16. Removed concepts").
- A change of identity to gain access. Property 21 says that no identity exists to change to.
- A session whose processes all have every right of the user. Here a process of a session holds only its handles.
- Linger as a flag of the user: work while locked is a narrow grant (property 21, "Cost").

### Windows: sessions, the secure desktop, fast user switching

- Each interactive logon is a **session** with its own window station, its own desktop composition process and its own subsystem process. The services run in session 0, which shows no window since Windows Vista (session 0 isolation).
- **Fast user switching** keeps the session of the first user running, and shows the logon screen for a second user. The sessions of the users that are not at the screen keep running.
- The **secure attention sequence**, Ctrl+Alt+Del, always goes to the logon process. The **secure desktop** shows the logon screen and the elevation prompts in a desktop that no process of the user can draw on or read.
- **Remote Desktop Services** gives a remote user a session of its own, apart from the session at the console.
- **Windows Hello** keeps a key of each user in the TPM, behind a PIN; the TPM limits the rate of guesses. BitLocker encrypts the whole volume with one key for all users. EFS encrypts files for each user, and is little used.
- The **administrator** is a member of a group. User Account Control gives such a user a token with fewer rights, and an elevation prompt gives the full token.

Taken:

- A display composition process for each session: a fault of the process of one session shows nothing of another.
- One key combination that always reaches the system, and a trusted surface where the passphrase is typed.
- A remote session of a principal while another principal uses the screen.

Refused:

- The administrator group and the elevation of a token: a grant, not an identity, carries authority here.
- One volume key for all users: the data of a principal must need the secret of that principal.

### macOS

- **Fast user switching** keeps the sessions of other users running behind the login window.
- **FileVault** encrypts the whole volume. Each user with the right to unlock the volume (a "secure token") can start the machine; the first user gets it, and gives it to others.
- The **administrator** is a user in the group `admin`, who can change the system after a password prompt.
- Each user has a **keychain**, opened with the password of that user.

Taken: the keychain as a store of secrets for each principal, opened at the unlock. The rule that a principal who can unlock the volume gives that right to another one explicitly.

Refused: the administrator as a group, and one volume key that each user can unlock.

### ChromeOS

- Each user has a **cryptohome**: data encrypted with a key that the password and the TPM give together. Without the password, the data of a user stays closed.
- The **owner** is the first user that signs in on a machine that no organisation manages. The key of the owner signs the device policy: who can sign in, whether a guest can use the machine. Only the owner changes these settings.
- **Guest mode** gives an ephemeral session: its data is erased at its end.
- **Multiple sign-in** puts several users in one session; the windows of each user stay apart, and a window can move to the desktop of another user.
- **Powerwash** erases the whole machine.

Taken:

- The device policy as a record that a key signs, and that the system checks. Here the disk grant table of principal 0, which the machine key signs, already has that form.
- The data of each principal under a key that the passphrase and the TPM give together. Here the keys of a named principal already have that form; the stores do not.
- An ephemeral principal as a later option.

Refused:

- The owner as the first user, fixed for ever: here the authority over the machine is a grant that principal 0 gives and takes back.
- Several principals in one session: the session is the tree of one principal (property 21, "Rule").

### Android: users, profiles, and the throttle in secure hardware

- Each **user** has its own data for each application. The identifier of a process is the number of the user and the number of the application together.
- **File-based encryption** gives each user a storage that the credential of the user opens (credential encrypted) and a storage that opens at the start (device encrypted). An application chooses where it keeps data that it needs before the unlock.
- **Gatekeeper** and **Weaver** check the credential in secure hardware, with a throttle for each user: a wrong credential of one user does not lock another one out.
- The users that are not at the screen can keep running, up to a limit of running users; the system stops the others.
- A **work profile** is a second user that shows its applications in the session of the first one, with a badge on each window.
- The first user, the **owner**, adds and removes users. Later versions give the right to other users with an **admin** flag. A secondary user can not erase the machine.
- A **guest** user is erased at its end.

Taken:

- A throttle of guesses for each principal, so that one principal can not lock another one out.
- A store that opens at the start, apart from the stores that the passphrase opens: the place of work that runs while a principal is locked.
- A bound on the count of kept sessions, and a stop of the oldest one past it.
- The badge of a profile, as the mark of the session of each surface.

Refused:

- The admin flag on a user as an identity: here it is a revocable grant.
- A work profile as several principals in one session.

### Plan 9

- Each process has its own **namespace**: the tree of names that it sees, built from what its parent mounted. Two processes of one user can see two different trees.
- A **terminal** belongs to the user that started it (the host owner). Several users share a CPU server, each in a session that `cpu` or `drawterm` opens from a terminal.
- **factotum** holds the keys of a user and proves them for the processes of that user, which never see a key.

Taken:

- The namespace as the whole view of a session: here the handles of the session.
- A remote session as the normal form of a second principal on a shared machine.
- An agent that holds the keys and proves them, which here is `unlock` with the TPM.

Refused: the user names that the file server checks, and a host owner who holds the whole terminal.

### The capability systems: KeyKOS, EROS, seL4, Genode, Fuchsia, Qubes

- **KeyKOS and EROS** have no users in the kernel. A login gives a person a "user agent" that holds the capabilities of that person, in a persistent system. EROS had a trusted window system that labels each window with its source.
- **seL4** has no concept above capabilities. A system on seL4 builds users, if it needs them, as a tree of capabilities.
- **Genode** is a tree of components; each parent decides the policy of its children. Its GUI server, nitpicker, labels each view with the name of its session, and has an "X-ray" mode that shows the labels on the trusted path, so a window can not pose as another.
- **Fuchsia** routes each capability through a tree of component realms. A session manager runs one session component, which a product chooses.
- **Qubes** runs each domain in its own machine. The trusted GUI domain draws a border of a colour that each domain gets, on each window. A copy between two domains is an explicit act: Ctrl+Shift+C, then Ctrl+Shift+V in the other domain.

Taken:

- A session as a subtree of handles, with no change of the kernel. This is the rule of property 21 itself.
- A label of the session on each surface, drawn on the trusted path, which no process can copy.
- A copy between two principals as an explicit act on the trusted path, never a common clipboard.
- A display holder for each session, below a holder of the screen: the form of nitpicker and of the nested compositor of property 23.

Refused: the persistence of KeyKOS, where a process never stops: a lock here stops the processes, and their state is in their stores (property 9).

### The lessons

1. Each system that keeps the sessions of other principals running gives each session its own display composition (Windows), or isolates it in a stronger way (Qubes). X11 shows the risk of one shared display server: each client of an X server reads the keys and the pixels of each other client.
2. Each system that ships for several people separates the seat from the session.
3. The authority over the machine is a group (Unix, Windows, macOS), a first user (ChromeOS, Android), or nothing (Plan 9 terminals, the capability systems). The capability systems have no answer for a shared desktop; ChromeOS gives the closest form: a key that signs a policy.
4. The throttle of guesses must be per principal (Android). A shared count lets one principal lock another one out.
5. Encryption for each principal is what makes the data separation hold against the disk. Whole-volume encryption separates nothing between principals.

## 3. The questions

### 3.1 What a principal owns

A principal owns every object that the system keeps for it. The design must name each one, so that a removal finds each one and so that no part keeps state of a principal in a shared place.

| Object | Where it is today | With several principals |
|---|---|---|
| The file of its keys | The object `principal` in the store of `unlock` (a store of principal 0) | One object for each principal, named by the number of the principal |
| Its recovery copy with no TPM | The object `principal_recovery` in the same store | One for each principal |
| Its pin | An index of the TPM, by its number | An index for each principal, within the free NV memory of the TPM |
| Its stores | Each store with the suffix `.principal.N` | The same, under one root of the principal (section 3.9) |
| Its disk grant table | The object `grant_table` of `module_files.principal.N` | No change |
| Its client keys | Rows of the client table, and of its disk grant table | No change |
| Its plans | The applied plans of `plans`, for each principal | No change |
| Its audit space | A space of the collector for the principal | No change |
| Its settings | Stores of principal 0, one settings page | A settings store of the principal, and a settings page for its session (section 3.6) |
| Its budgets | None: the processes of a session take from the budget of the root service | A budget of the session (section 3.7) |
| Its wide grants | A state of a row of the client table, not on the disk | No change |
| Its log records | In the one log, read by any caller that acts for a principal | Readable only by a caller that acts for that principal, or by principal 0 for the processes of principal 0 |

### 3.2 The creation of a principal

Who can create a principal, and where?

- Today the console of principal 0 creates the one named principal, and `unlock` shows its passphrase prompt and its recovery key.
- With several principals, a principal A can be in its session when a person B arrives. If A creates B in a window of the session of A, the recovery key of B shows on the screen of A, and A can read it. A creation must run outside each session: on the trusted surface of the seat, with no session in front.
- A creation also uses machine resources: a place of the records, an index of the TPM, a budget of the disk. It is an act on the machine, so the authority over the machine decides it (section 3.10).

The form that answers both points: **an invitation, then a creation at the prompt**. A principal with the authority over the machine writes an invitation: a name and an end time, in a record of principal 0. The prompt of `unlock` then offers "create the principal <name>" while the invitation holds. The person B creates the principal there, types the passphrase two times and writes down the recovery key, with no session in front. The creation of the first named principal on a machine that has none needs no invitation, as today.

### 3.3 The TPM and the sealed keys of each principal

- The keys of each principal are sealed by the TPM with its passphrase, as today, in one file each. The form `PRINCIPT` does not change.
- **The count is shared.** The TPM 2.0 has one count of wrong authorization values for the whole TPM. Three wrong passphrases (on the test TPM) for principal A lock the TPM for each principal and for the machine passphrase. A hostile principal can lock another one out of its session, at will. The recovery key opens the keys during a lockout, so it is a denial and not a loss.
- A throttle for each principal needs a part that the TPM gives for each object. One way: an NV index of the TPM for each principal that holds a count of its tries, and a policy of the sealed object that needs that count below a limit (`TPM2_PolicyNV`). Only this system writes the index, by a policy on PCR 7 and PCR 11. The cost: one more NV index for each principal, the write of the index at each try, and a count with no time to forgive it, so the limit must give a way back (the recovery key). The refused form "a count of the tries in the file" does not apply: the index is in the TPM, and a copy of the disk does not reset it.
- **The pins.** Each principal needs its pin index, and each NV index uses the NV memory of the TPM, which is small. The free NV memory bounds the count of principals that the TPM pins. A principal past that bound has no pin: the refusal must say so at its creation, never in silence.
- **What a principal learns of the others.** A shared count tells principal B that someone typed wrong passphrases. That is a covert channel of a few bits a day; it is small beside the denial.

### 3.4 The unlock and the lock

- **The prompt.** `unlock` shows the names of the principals, and the person chooses one. A list of names on the screen of a machine tells each person at it who uses the machine. Android, macOS and Windows show the list; an option types the name. The list is the frequent form.
- **The lock.** Today the lock stops the processes of the session. With kept sessions, two acts exist: a **switch**, which puts another session in front and keeps the first one, and a **lock**, which ends a session and erases its key. A switch to the prompt must not leave the session in front open to the next person: the prompt is in front, and the session that was in front is kept but shows nothing and receives no key.
- **The unlock of a kept session** needs the passphrase again. A switch back with no passphrase gives the session to whoever stands at the machine.
- **The keys in memory.** When the stores are encrypted, a kept session holds the key of its stores in the storage service. A machine with two kept sessions holds two keys. A lock erases the key of its session.
- **A window of `unlock` for a session** (a change of the passphrase, a seal of the machine key) belongs to that session: a lock or a switch of that session ends it, as the lock ends it today. The rule "no window of `unlock` outlives a lock" becomes "no window of `unlock` that a session asked for shows while another session, or the prompt, is in front".

### 3.5 The switch: kept sessions, or one at a time

Two forms exist:

- **One session at a time.** A switch is a lock of the session in front, then an unlock of the other principal. Its processes stop; their state is in their stores (property 9), so the documents are whole, but each program starts again: its window places, its scroll positions, a build in progress, a download, an agent at work are lost or must start again. The background work of a principal that is not in front does not exist.
- **Kept sessions (fast switch).** The sessions keep running. A switch changes the session in front: the screen shows its windows, and the input goes to it. The other sessions run, with no screen and no input. The cost is in the isolation: two principals run at once, so each shared part (the compositor, the scheduler, the storage service, the caches of the processor) is a channel between them (section 3.11), and each part must keep state for each session.

The kernel freezes no process, and neither form needs it. A freeze is a third form: the sessions are kept, but only the session in front runs. It needs a kernel operation that stops each thread of a budget, which property 1 counts. It removes the channels of a running background session but keeps its memory. The study does not take it: the scheduler can give a background session a small share with no new operation.

### 3.6 The screen and the input

- **One screen, one seat.** The machine has one screen and one set of input devices. The seat is the part that owns them, draws the trusted path, and decides which session is in front.
- **The trusted path for each principal.** The passphrase prompt, the grant dialog, the screen of a wide grant and the mark of an agent are trusted surfaces. Each must name the principal that it is for. A trusted surface of principal A must never show while B is in front, and a process of B must never draw a surface that looks like the prompt of A. The seat draws the name of the session in front, and a colour or a picture that the principal chose at its creation, in a place that no process covers (the form of Qubes and nitpicker).
- **The key to the system.** One key combination always reaches the seat ([`docs/PROPERTIES.md`](../PROPERTIES.md), "20. No ambient access: the other holes to close", line 8). It shows the switch and the lock.
- **The input.** The keys and the pointer go to the session in front only. A session that is not in front receives no input record, and no record tells it that a key was pressed.
- **The clipboard.** Each session has its own slot. A switch never moves the content to another session. A copy between two principals is a share (section 3.7), never a paste.
- **The settings page.** The language, the appearance, the scale, the keyboard layout and the time zone are choices of a principal. The settings page that each process maps becomes a page of the session; the machine keeps a page of principal 0 for the services. The keyboard layout of the prompt is a setting of the machine, because the prompt runs before any session.
- **The remote sessions.** `remote_display` today shows the screen only to a key of the session in front. With kept sessions, a principal B can work from another machine while A is at the screen, only if the session of B draws its windows into a screen of its own (a screen of memory). With one compositor for all sessions, that compositor must keep a second screen of memory for B; with one display holder for each session, the holder of B draws into its own screen, and `remote_display` reads that screen.

### 3.7 The budgets and the shares between principals

- **A budget for each session.** The root service gives each session a child budget: memory pages, process slots, log records of each second, threads. Each process of the session takes from it. The kernel already divides a budget among children ([`docs/PROPERTIES.md`](../PROPERTIES.md), "20. No ambient access: the other holes to close", line 16), so this needs no kernel change.
- **The disk.** The storage service gives each store a limit of blocks today. A principal needs one limit for all its stores, which the storage service sums by the principal of each store.
- **The processor.** The process `scheduler` gives a weight to each process. With kept sessions, it gives each session a share, and the session in front a larger one, so a background build of B does not slow the screen of A.
- **The process slots.** The kernel has 64 process slots for the machine. The services and two sessions use most of them. The constant is a capacity of the kernel, not a design: it grows with a reserve of address space for the table, by property 13.
- **A share of an object between two principals of one machine.** Principal A gives principal B a store, or one object, with Read or with Read and Write. On one machine the root service is the party that both trust, so the grant is a row of the disk grant table of A that names the public key of B: tagged with the key of A, revocable at once, and recorded. A signed grant ([`src/md/features/several_machines.md`](../../src/md/features/several_machines.md), "Sharing between two principals") is the form that crosses machines. Both forms name the receiver by its public key, so a share from one machine and a share from another look the same to the receiver.

### 3.8 The audit and the wide grants

- The collector has one audit space for each principal, and the wide grants already need the passphrase of their principal. Neither changes.
- **The mark of an agent.** A wide grant of A with the scopes `Processes` or `Stores` keeps acting while B is in front: the session of A runs. The rule "nobody at the machine can miss that an agent holds wide authority" then holds only if the seat shows, to B, that an agent acts for another principal. The seat can show a count of agents that act in other sessions, with no detail: the detail is a fact of A. The scopes `Screen_View` and `Input` pause while A is not in front, as `remote_display` pauses a viewer today.
- **The act records of the seat.** The seat writes the switches, the locks and the unlocks as act records in the space of each principal that they touch. A principal reads when its session was put in front and when it was locked.

### 3.9 The removal of a principal and its data

Property 21 says: "the root handle is dropped and the whole tree goes with it". Today no such root exists: the stores of a principal are the stores whose name has its suffix, and the rest is in the store of `unlock`, in the TPM, in the client table, in the collector and in `plans`.

The removal must:

1. stop each process of the principal, as a lock;
2. erase its file and its recovery copy, with the versions of both ([`src/md/features/version_erase.md`](../../src/md/features/version_erase.md));
3. erase its pin index and its count index in the TPM;
4. remove each of its stores, its disk grant table, its rows of the client table, its plans and its audit space;
5. keep its number from use for ever, so that no old row, act record or pin names a new principal.

With encrypted stores, step 4 becomes fast and sure: the erase of the keys of the principal makes each block of its stores unreadable at once, on the disk and on each copy of the disk. The blocks are freed later. Without encryption, a removal is a promise of the storage service only, under the limits of the erase of versions.

**Who removes.** The principal itself, with the proof of its passphrase: the form of a change of the passphrase. A principal that lost its passphrase and its recovery key can not prove itself: its data are lost to it, and only the authority over the machine frees its disk. The authority over the machine can remove a principal with no passphrase of that principal: it destroys and reads nothing. That act is a decision (section 8).

**The number.** The grant word has 15 bits for the principal, so the numbers do not run out in the life of a machine if each creation takes a new one. The root service keeps the next number in a record of principal 0. The index of a pin is by place, not by number: the TPM holds few indices.

### 3.10 An administrator, or none

The properties forbid an administrator as an identity: "No root" ([`docs/PROPERTIES.md`](../PROPERTIES.md), "20. No ambient access: the other holes to close", line 18), and "here the principal that holds the handle to the system description can change the system. This is one handle. It can be delegated" (property 21, the defect 4). Property 22 asks for one general mechanism.

The acts that change the machine and not one principal are: the start policy, the holders of the roles of the trusted path, the plan of principal 0, the device grants, the machine passphrase and the seal of the machine key, an invitation, the removal of another principal, the update of the system. Today each is a command of a console that acts for principal 0, and that console is open to anyone at the keyboard.

Three forms:

1. **No authority over the machine for a named principal.** Only principal 0 changes the machine, through its own console, which needs the machine passphrase when one is set. Each person who knows the machine passphrase is the administrator. Simple, but the machine passphrase becomes a shared secret, which the properties avoid.
2. **The machine grant: a revocable grant of principal 0 to a named principal.** A row of the disk grant table of principal 0, tagged with the machine key, names the public signing key of a named principal. A console that the session of that principal starts can then ask the seat for a console that acts for principal 0, after the proof of the passphrase of the principal. The grant is a recorded, visible, revocable handle: the form of property 21. The first named principal of a machine gets it at its creation, so a new machine has a principal that can change it. It gives no right to read the data of another principal: principal 0 sees no store of a named principal.
3. **A machine with no authority at all.** The configuration of the machine is fixed by the signed system and the plan; no principal changes it on the machine. This is the form of a managed machine, and it is the case of a plan that a key outside the machine signs.

Form 2 is the nearest form that keeps property 21 and property 22: one grant, of the kind that the disk grant table already holds. It makes the console of principal 0 unreachable with no proof, which closes the hole of the desktop while locked.

### 3.11 The covert channels between principals

Property 20, line 17, says that side channels are not solved by handles, and lists reductions. With kept sessions, two principals run at once. With one session at a time, the channels between principals pass only through the state that stays across a switch.

| Channel | One session at a time | Kept sessions | Reduction |
|---|---|---|---|
| The caches and the branch predictors of the processor | None while the other session is stopped | Present | The scheduler keeps two sessions off the cores that share a cache, as property 20 proposes; a precise clock is a grant |
| The process slots, the memory, the log records | The count of free slots tells how much the machine runs | A session sees the use of another through a refusal | A budget for each session: a session meets its own limit first, never the limit of the machine |
| The free blocks of the disk | The count of free blocks changes with the writes of another principal | The same, live | A limit for each principal; the count of free blocks of the machine is not an export to a session |
| The names of the stores | `stores()` lists the stores of the caller only | The same | None needed |
| The log | Not split today: a leak, not a channel | The same | The split of the log by principal (section 3.1) |
| The clipboard | One slot | One slot | One slot for each session |
| The TPM count | A principal sees the count of another | The same | A count index for each principal (section 3.3) |
| The timing of the storage service and of the compositor | Small | A session sees the load of another by the time of its calls | Accepted: a measure, not a guarantee |
| The list of names at the prompt | Each person sees who uses the machine | The same | A setting of the machine that hides the list |

## 4. Three designs

Each design keeps the data model of section 3.1, the creation by invitation, the removal, the budgets for each session, the split of the log, and the encryption of the stores. They differ in the switch and the display.

### Design A: one session at a time

**The form.** The root service keeps N records. One named principal at most has a session. A switch is a lock, then an unlock at the prompt. The seat is the compositor of today, with a prompt that shows the list of principals. While no session is in front, the screen shows only the prompt.

**What changes.** The places of the records, `unlock` with N files and a choice, the invitation, the removal, the settings page of the session, the split of the log, the clipboard emptied at each lock, the budget of the session.

**What it costs.** Little in code: the shape of today with a list in place of one place. No new channel between principals while one runs. The switch costs the state of each running program and each background task of the principal that leaves. A remote session of B while A is at the screen does not exist. An agent of A stops at each switch.

**Dead ends.** None, if each table is keyed by principal and the session in front is a fact of its own from the start, apart from "the principal that is unlocked".

### Design B: kept sessions in one compositor

**The form.** The sessions keep running. The one compositor holds the windows of each session, tags each surface with its session, shows the windows of the session in front only, gives the input to that session, and keeps a clipboard slot, a focus, a set of notifications and a screen of memory for each session.

**What changes.** All of design A, plus: each table of the compositor keyed by session, a switch that keeps sessions, a screen of memory for each session that a remote viewer reads, a budget and a share for each session.

**What it costs.** The compositor holds the pixels and the input of each principal. A fault in it, or a defect in one of its tables, shows the windows of one principal to another: one bug is a breach between principals. Each feature of the compositor (the palette, the window switcher, the notifications, the bar, the magnifier) must be checked for each session. The memory of the compositor grows with the count of sessions.

**Dead ends.** It is a dead end for isolation: to reach a display process for each session later, the per-session tables of the compositor are written again in another form.

### Design C: kept sessions, one display holder for each session, under the seat

**The form.** Two parts share the work of the compositor of today:

- **The seat holder**, one for the machine: it owns the screen, the input devices, the key to the system, the prompt of `unlock`, the switch, the trusted surfaces of the machine, and the marks. It draws the surface of the session in front, whole, and its own surfaces above it.
- **A display holder for each session**: the compositor of today, nested, a holder of the role of the display in the scope of a session ([`docs/PROPERTIES.md`](../PROPERTIES.md), "23. A role is a contract; its implementation is replaceable": "A scope is the machine, a session, one client or one device"). It holds the windows, the focus, the clipboard, the palette and the bar of its session. It draws into a surface that the seat shows, or into a screen of memory that `remote_display` reads for a principal who is away.

**What changes.** All of design A, plus: the split of the compositor into the seat and the session display; a contract between them (a surface, the input of the session in front, the size of the screen, the trusted requests); the trusted surfaces of a session (the grant dialog of the powerbox, the screen of a wide grant) drawn by the seat and labelled with the principal.

**What it costs.** One more process for each session, with its glyph caches and its memory: a cost to measure before the step, not to assume. One hop more for each frame, from the session display to the seat: a frame of the session is a surface for the seat, so the seat copies its damage, and the cost of that copy is to measure against the thresholds of property 18. The work of the split.

**Dead ends.** None found. Design A is its first layer. A fault of the display of a session shows nothing of another session. A remote session of a principal is a session whose display draws into a screen of memory. The seat is small, so it is the part that the trusted path depends on.

### The comparison

| Criterion | A: one at a time | B: one compositor | C: a display for each session |
|---|---|---|---|
| A switch keeps the work of a principal | No | Yes | Yes |
| A remote session while another principal is at the screen | No | Yes, in the compositor | Yes, by its own display |
| A fault of the display shows one principal to another | The compositor holds one session at a time | Yes | No: the seat holds no window of a session |
| The trusted path depends on | The compositor | The compositor | The seat only |
| Channels between running principals | Only through state kept across a switch | Each shared part | Each shared part, less the compositor |
| Kernel change | None | None | None |
| Work beyond A | None | Large, and spent | Large, and kept |
| Memory for each kept session | None | Tables in the compositor | One display process: to measure |

## 5. The recommendation

Take **design C as the form**, and **design A as its first layer**.

- Design A gives several principals soon, with no new channel between them, and every part of it stays in design C: the records, the invitation, the removal, the settings of a session, the split of the log, the budgets, the encryption.
- Design C gives what a production desktop needs: a switch that keeps the work, a remote session for each principal, and a trusted path that depends on a small seat. It uses mechanisms that the properties already name: the scope "session" of a role, and the nested compositor as an interposed holder.
- Design B is refused. It spends the work of a per-session compositor on a form whose isolation is one bug deep, and the step to C writes that work again.

Two parts are needed before a second named principal is a production feature, whatever the design:

1. **The encryption of the stores of each principal**, with the unlock key. Without it, the separation holds against the processes of the machine and not against the disk.
2. **The machine grant and a prompt-only screen with no session in front.** Without them, anyone at the keyboard holds principal 0 through its console.

## 6. The order of the work, in layers

Each layer is a system that works, and adds one capability (`AGENTS.md`, "Work").

1. **The session in front as a fact of its own.** The root service names the session in front in one variable, apart from the set of unlocked principals, and each rule that reads "the named principal" reads the session in front or the principal of the caller. One principal still; no behaviour changes. The removal of `#assert(PRINCIPAL_CAPACITY == 2)` follows.
2. **A prompt with no session in front.** While no named session is in front, the screen shows the prompt of `unlock` only; the console of principal 0 needs the machine passphrase, or the machine grant of layer 4. A machine with no named principal keeps the console of principal 0 as today.
3. **N records, and one session at a time (design A).** `unlock` keeps one file for each principal and shows the list. The number of a principal is never used again. The settings page of the session, the split of the log by principal, and the clipboard emptied at a lock come in the same layer, because each one is a leak with two principals.
4. **The machine grant, and the invitation.** A row of the disk grant table of principal 0 names a principal with the authority over the machine. The first named principal gets it. An invitation lets a person create a principal at the prompt.
5. **The removal of a principal**, by itself with its passphrase, and by the machine grant if that decision is taken (section 8).
6. **The encryption of the stores of a principal** under keys from its unlock key; the lock erases them in the storage service. The removal then erases the keys.
7. **The budget of each session**: memory, process slots, log records, a limit of blocks for all the stores of the principal. The process slots of the kernel grow past 64 before layer 8.
8. **The seat and a display for each session (design C).** The split of the compositor; the switch that keeps a session; the input and the clipboard for each session; the label of the session on the trusted path.
9. **The remote session of a principal who is not in front**, through a display that draws into a screen of memory.
10. **A share between two principals of one machine**, as a row of the disk grant table of the giver that names the public key of the receiver.
11. **A count of tries for each principal in the TPM**, if that decision is taken (section 8).

The work while a principal is locked (property 21, "Cost") is later work: it needs a key that stays available while the passphrase is not typed, and a narrow grant for it.

## 7. Where the goal meets the properties

- **Property 21, "no kernel change".** It holds in each design. The process slots and the TPM indices are capacities, not designs. A freeze of a session needs a kernel operation, and the study does not take it.
- **Property 21, the defect 6: "the root handle is dropped and the whole tree goes with it".** The stores of a principal are found by the suffix of their names, not by one root. Layer 5 and layer 6 give the nearest form: one key for each principal, whose erase makes its whole tree unreadable.
- **Property 20, line 18: "No root."** The machine grant is not a root: it reaches the machine and not the data of a principal, and principal 0 gives it, records it and takes it back. An administrator as an identity stays refused.
- **Property 21, the rule that a principal owns its settings.** Today the settings are stores of principal 0 and one page of the machine; the definition of a principal ("documents, grant records, settings") already says that they belong to the principal. Layer 3 brings the code to the definition.
- **The log.** The log is not split by principal today ([`src/md/features/log_reader_scope.md`](../../src/md/features/log_reader_scope.md), "State"). That is a defect of layer 4, not a choice: layer 3 fixes it.
- **The desktop while locked.** The console of principal 0 open to anyone at the keyboard contradicts property 20, line 18, as soon as a second person can sit at the machine. Layer 2 fixes it.

## 8. The decisions to make

1. **The form of the switch.** Design C with design A as its first layer (recommended), or design A only, which keeps one session at a time for good.
2. **The authority over the machine.** The machine grant, given to the first named principal at its creation (recommended); or the machine passphrase only, shared by each person who changes the machine; or no authority on the machine.
3. **Who creates a principal.** An invitation by a principal with the machine grant, then a creation at the prompt (recommended); or anyone at the prompt, with no invitation.
4. **The removal of another principal.** The machine grant can remove a principal without its passphrase, and destroys its data unread (recommended, because a lost passphrase and a lost recovery key otherwise hold the disk for ever); or only a principal removes itself.
5. **The count of tries.** Accept the count of the TPM, shared by each principal, with the recovery key as the way out of a lockout (the first layers); or add an NV index for each principal, so that a principal can not lock another one out (recommended later, layer 11).
6. **The encryption of the stores before a second principal ships.** A second named principal waits for layer 6 (recommended); or it ships before, with the data of each principal in clear on the disk.
7. **The list of names at the prompt.** Shown (recommended, the frequent form); or typed, which hides who uses the machine.
