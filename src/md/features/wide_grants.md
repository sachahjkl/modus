# Grants of wide authority, for agents first

An agent that drives the machine for the principal needs much authority at once: lines of the console, the screen, the keys and the pointer, the start and the stop of processes, the log, the stores. The powerbox ([powerbox.md](powerbox.md)) gives one object at a time and refuses such a request at its border. A wide grant is the other path: a set of wide scopes, each with its bounds, given to one agent on a screen of its own, after a proof of the principal, with a mark that shows while it holds, a record of each act, and one revocation that ends it all.

The first user is the roadmap entry "An agent drives a machine through `remote`": a bridge on the host that holds a client key ([remote_client_keys.md](remote_client_keys.md)).

## Purpose

- The principal gives an agent exactly the authority that a task needs, from one screen that says in plain words what the agent can see and do.
- The principal bounds the grant in time and in place, and keeps some acts asking at the moment they happen.
- Nobody at the machine can miss that an agent holds wide authority, and one press revokes it.
- The principal reads afterwards each act that the agent did under the grant.

## Constraints

- **A principal is the one source of new grants** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users"): a human, an agent and a remote caller are the same thing, a process tree with handles; the system tells them apart only by what they hold.
- **A broad grant is rare, visible and revocable** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", the cost of the processes that manage the system).
- **A viewer with input already acts as the principal at the machine** ([remote_display.md](remote_display.md), "The constraints"): through the key super it reaches the palette, so the console. A wide grant must say so and bound it, not hide it.
- **The trusted path is a role** ([powerbox.md](powerbox.md), "The trusted display"). Each screen and mark below is a record of that contract; a replacement compositor fills it.
- **No act without its record, and no writer of the system that waits on a reader** ([module_outputs.md](module_outputs.md); the loop of the trusted display waits for no process).

## The chosen form

### The holder of a wide grant

A wide grant is given to one agent, named by what proves it:

- **A client key of `remote`** today: the agent runs outside the machine and proves the key in the QUIC handshake. The wide grant is a state of the row of that key in the client table, beside its uses (`Calls`, `View`, `Input`), with its own serial.
- **The hash of a module**, later: an agent that runs on modus as a disk process.

One holder has one wide grant at most. A new grant replaces it whole.

### The wide scopes

A wide scope is a member of the enum `Wide_Scope` of the contract, with a boundary that one mechanism of the system enforces.

| Scope | What the agent can do | What enforces the boundary | Its place bound |
|---|---|---|---|
| `Console_Lines` | Run lines of Lex in an agent console: a console that the root service starts for the grant, in the session of the principal, which reaches only what the other kept scopes give | The role of the agent console: its start grants are the union of the kept scopes, never the role of the console of the principal | None: the other scopes bound what the lines reach |
| `Screen_View` | See the screen, as a viewer with `View` | The use `View` of the row, and the session in front ([remote_display.md](remote_display.md), "The authority") | None |
| `Input` | Send keys and the pointer, as a viewer with `Input`; needs `Screen_View` | The input face of the trusted display, which drops each record for a window outside the bound | The windows of chosen processes; or every window, which includes the palette and the window of each console |
| `Processes` | Start and stop the processes of the session | The root commands `Start` and `Stop` in the sender table of the agent console, for the processes of its own session | The names or nicknames chosen; or each one |
| `Log_Read` | Read the log of the session of the principal | A connection to the log service that acts for the principal and reads only | None |
| `Stores` | Read, or read and change, stores of the principal | Shares of the chosen stores, each read-only unless the principal kept `Change` for it; "every store" is a connection to the storage service that acts for the principal, read-only unless `Change` is kept | The stores chosen, with the rights of each |

No scope gives:

- a change of a grant: `allow`, `disallow`, `remote_allow`, a client key, `Apply` of a difference that adds a grant ("Acts that still ask");
- a command of the principals: a creation, a lock, a passphrase, the machine key, a start policy;
- `Replace`, the debug access, a right over the machine or a device;
- the answer to a grant dialog or to a wide grant screen.

The agent console has no sender of these commands in the table of the root ring, so a line that asks for one is refused with `No_Grant` before it runs.

**Which scopes go with ordinary items.** None. Each wide scope reaches a set of objects that the principal cannot read as one row: the whole screen, each window, each store, each process. The border of the grant request refuses an item whose kind is a wide scope with `Reserved`. An ordinary item that reaches as far (a connection to `storage` that acts for the principal, a connection to `remote` or to the log of the session) is not a kind of the powerbox at all.

**Why `Input` on every window is said in full.** Input to the palette is input to the console of the principal. The screen says it in words: "with every window, it can type in a console and do what you can do". A bound to chosen windows removes the palette, the console and every other window from the reach of the agent.

### The screen of a wide grant

The screen of a wide grant is a record of the contract of the trusted display, `Show_Wide_Grant`, never the ordinary dialog.

**Who asks.** The agent, through `remote`: a typed record of the scopes and the bounds that it proposes, with no text, which `remote` passes to the root service for its key. Or the principal, from its console: `agent_allow(key, scopes)`. Both show the same screen; the principal changes what the agent proposed.

**What it states**, in plain words from the table of the display texts of the scopes, with no word of the agent:

- the agent: the hash prefix of its client key, and the head of the whole key; the hash of its module when the holder is a module; the principal for whom it will act;
- what the agent can see: "the screen", "the log of your session", "the stores: notes, mail";
- what it can do: "type and press in the windows of edit and notes", "start and stop edit", "change the store notes";
- what it can do without asking, and what still asks: each scope with its mode, "at any time" or "asks each time";
- for how long, and how to end it: "until 15:42", "until the lock", "until you revoke it or the machine stops", and "the mark in the bar ends it";
- what it never does: "it cannot grant, change your passphrase or apply a plan that grants".

**The tuning on the same screen.**

- Each scope has a tick, set for each scope that the agent proposed.
- The time bound: one hour (the default), this session (to the lock; for principal 0, until the machine stops), or until revoked. Each one ends at the latest when the machine stops: no wide grant is written on the disk.
- The place bounds: the picker of the powerbox gives the candidates (the stores of the principal, the processes of the session, the windows), and the principal picks. `Stores` and `Processes` start with no pick: "every store" and "every process" are explicit choices.
- The mode of each scope: "asks each time" or "at any time". It starts at "asks each time" for `Processes` and for each store with `Change`.

### The deliberate act: the proof of the principal

The act that gives a wide grant is the passphrase of the principal, typed in the window of `unlock`, with the keys of the machine only.

- After the tuning, the root service fixes the terms: it keeps the hash of the record of the screen, and starts `unlock` in a mode that proves the passphrase and opens no session, as the proof before a change of the passphrase does ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "A change of the passphrase"). For principal 0, the proof is the machine passphrase.
- The trusted display gives that window the keys of the input service only: the input face of the remote display never reaches it, as it never reaches a trusted surface. The root service marks the window so in the record `Client_Add` of `unlock`.
- The root service makes the grant only when `unlock` says that the passphrase opened the keys, for the terms whose hash the screen showed. A change of the terms after the proof is refused.
- **A principal with no passphrase gives no wide grant at the keyboard.** Principal 0 with no machine passphrase, or with only the machine key that the TPM releases with no typing, is refused with one line that says to set a machine passphrase.
- **A machine with no person**, such as a test machine, proves the principal with a signature in place of the passphrase: a signing key of the principal, kept on the host and never on the machine, signs the hash of the terms. The root service checks the signature with the public key of the principal before it makes the grant, as for the passphrase, and a change of the terms after the signature is refused. The signature reaches the root service through `remote`, never through the input of the remote display. The key on the host is the principal for this act: whoever holds it gives the grant.

**Why the passphrase.** A wide grant hands over the authority of the principal; the act must prove the principal, not only a person at the keyboard. A hold of a key or a typed word proves a press, and an agent that holds `Input` from an earlier grant, or a person who passes by the machine, can give it. The passphrase exists already, is typed in one window only, and is never a text of the console. The cost: a wrong passphrase counts in the TPM, as each wrong passphrase does ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The keys sealed by the TPM").

Refused: **a hold of a key for some seconds**: it proves no principal, and a stuck key gives it; **typing a word that the screen shows**: an agent with `Screen_View` reads it, and only the rule of the local keys stops it; **a second device**: the system has no pairing of a device yet; **a wide grant with no proof on a machine with no person**: the agent then gives itself the authority of the principal.

**A wide grant ends at each restart, for now.** The grant is never on the disk, so each run needs a fresh proof, and a stolen agent key gets no grant after a restart. An agent that works each night from a schedule needs a grant that a restart keeps, which needs a key that the TPM releases with no person. That form is reopened when a scheduled agent exists.

### Acts that still ask

- **The mode "asks each time".** Each act of that scope waits for the answer of the principal: a grant dialog of the powerbox whose asker is the agent console, with one row, "stop edit" or "open notes to change it". The same merge, arm time and bounds hold, so a burst of acts gives one screen.
- **Acts that always ask, whatever the grant.** While a wide grant holds in a session, each `Apply` whose difference adds a grant, from any console of that session, needs the proof of the principal on the screen of the difference ([powerbox.md](powerbox.md), "The relation to the other paths"). The root service cannot know which line an agent typed into which window, so the rule holds for each asker of the session while the grant holds.
- **The grants of a process that the agent started.** Such a process asks through its own window; its dialog names the agent console as the process that started it. The agent cannot answer it.

### The mark

While a wide grant holds, the trusted display shows a mark of wide authority on the place that no process covers: the word "agent", the hash prefix of the key, and the time left. The contract fixes it ([powerbox.md](powerbox.md), "The trusted display"): the holder draws it from the record `Mark` of the root service, whatever any other process says. One press on the mark shows what the grant holds (the scopes, the bounds, the time left, the count of acts so far), with the button revoke; one press there ends the grant at once. Input from the remote display never presses it.

The mark of a viewer ([remote_display.md](remote_display.md), "The authority") stays: it says that a screen is seen. The mark of wide authority says that an agent acts.

### The record of each act

Each act under the grant is an act record, written before the act runs, on a record output of the party that does the act ([module_outputs.md](module_outputs.md)):

| Writer | Act records |
|---|---|
| The root service | The grant, its terms, each start and stop, each share and connection made, each answer of "asks each time", the revocation and the end |
| The agent console | Each line, whole, and the kind of its result |
| `remote` | Each call outside the agent console |
| The trusted display | Each change of the window that receives the input of the agent, with the count of the keys and of the presses since the last change; the open and the close of the view |

The reader of each act record output is the collector ([module_outputs.md](module_outputs.md), the roadmap entry "The collector and the audit"), wired by the root service at the grant, into a space of the principal that the agent cannot read or erase. The collector is the first reader of the act records, and it is built before the first layer of this file: no wide grant exists before its act records have a reader.

**No act without its record.** A writer that finds the ring full does not wait and does not drop the record: it refuses the act. The agent console answers its line `Busy`; the root service refuses the command `Busy`; the trusted display drops the input of the agent, and counts it. The principal reads the acts with the console, as each record output: `acts(key)`.

Refused: **log facts as the record**: the log is lossy by design, and a wide grant must lose no act; **the act record after the act**: an act that ran with its record lost leaves no trace.

### The revocation

A press on revoke, `agent_disallow(key)`, the end of the time bound, the lock of the session, or the stop of the machine ends the grant. The root service, in one pass:

1. gives the row of the key a new wide grant serial and clears its wide grant, so `remote` and `remote_display` end each connection of the key with the code `Revoked`, as for a revoked client key ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The client keys of remote");
2. revokes with `Handle_Revoke` each handle that came from the grant: the shares, the connections, the log connection;
3. stops the agent console;
4. writes the act record of the end, with its cause, and ends the wirings of the act records with their end record;
5. tells the trusted display, which removes the mark.

**What the agent sees.** Its QUIC connection ends with the application code `Revoked`. A new handshake of its key holds only the uses of its row outside the wide grant, `Calls` if the principal gave it with `remote_allow`; a call of the agent console is refused with the error record `No_Grant`, unit `Wide_Grant`, and the cause: revoked, time bound, lock.

## Security

- **An agent that asks for wider authority step by step.** A wide grant is replaced whole, never extended: each new screen shows the whole set, marks what is new, and needs the proof again. After a refused screen the key gets no screen for 10 minutes on the clock of the system, and after 3 refused screens in one run, none until the machine starts again. The ordinary requests of the processes that the agent starts each show a dialog that names the agent console, and the agent cannot answer them.
- **An agent that drives the very dialog that grants it.** The input face of the remote display never reaches a trusted surface: no dialog, no screen of a wide grant, no mark, no window of `unlock` in its proof mode. The proof needs the passphrase from the keys of the machine. An agent with `Screen_View` sees the screen and can act on nothing that it sees there.
- **A prompt-injected agent that acts against the principal.** The system cannot read the intent of an agent. It bounds what a turned agent can do: the scopes that the principal kept, the places picked, "asks each time" on the acts that destroy or change, no change of a grant, a time bound of one hour by default, the mark that shows the count of the acts, and the act records that tell the principal after what happened.
- **An agent key stolen from the host.** The thief holds the key and acts with each use of its row, the wide grant too, while the grant holds. It ends with the time bound, at the lock, at the stop of the machine, and at a revocation; it is never on the disk, so a stolen key gets no wide grant after a restart without a new proof. A second connection of the key while one holds the grant suspends the grant: both connections end with `Revoked`, and the mark says "suspended: two connections of one key" until the principal revokes it or gives it again with the proof. The act records show each act of the thief.

## The prior art

- **macOS 27.3**, beta 2 of 16 November 2026 ([the announcement](https://developer.apple.com/news/?id=oqng0zjk); [the support article](https://support.apple.com/en-us/149699)). Device Control and Data Access splits into System & App Protection Override and Accessibility. The person chooses the apps or the folders that an app reaches in place of the whole Mac, each app with "Ask First" or "At Any Time". A screen lists in words what the app will be able to do, a confirmation for each line ("Control Your Mac, Apps, and Settings", "Monitor Everything You Do"), then asks for the password. An indicator in the menu bar shows while an app controls another app. Taken: the place bounds by picked objects, the mode "asks each time", the list in plain words, the password at the end, the indicator. Refused: a confirmation for each line, which trains the reader to press with no reading; a grant that lasts for ever; the grants of before kept as they were by an update.
- **Accessibility, Screen Recording and Automation of macOS.** Accessibility gives the control of each app at once, and Screen Recording each window: taken as the honest statement that `Input` on every window and `Screen_View` reach everything, refused as switches with no bound. Automation is one switch for each pair of apps, which the system asks for at the first use and then never again: the pair is the form of the place bound of `Input` by window, taken; the question with no end time is refused.
- **OAuth 2.0 scopes** ([powerbox.md](powerbox.md), "The prior art"): a scope with a name and a boundary, and an answer that says which scopes were given.

## The order of the work

1. **The scopes `Screen_View` and `Input` with the mark and the screen.** The wide grant on the row of a client key, the screen of the contract, the proof in `unlock`, the time bounds, the place bound of `Input` by window, the mark with its revoke, the suspension at a second connection, and the act records of the trusted display and of the root service. It needs the first layer of the powerbox and the collector as the reader of the act records.
2. **`Console_Lines`, `Processes` and `Log_Read`**: the agent console with its role from the kept scopes, the act records of the console, and the rule that an `Apply` that adds a grant needs the proof while a grant holds.
3. **`Stores`**, with the picker of the powerbox and the shares.
4. **"Asks each time"**, through the grant dialog of the powerbox.
5. **A wide grant to the hash of a module**, for an agent that runs on modus.

Why this order: the roadmap entry of the agent needs the screen and the input first; the scopes that reach the console and the stores add authority, so they come after the mark, the proof and the act records that bound them.

## State

Designed, not built.
