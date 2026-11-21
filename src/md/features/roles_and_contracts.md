# Roles and their contracts

A role is a place in the system that one process fills for the others: the display, the console, the storage, a device class. This file records how a role becomes a typed contract, how the root service gives it, how a client reaches its holder, and why the system has no bus. The rule is [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable". The terms Role, Role contract, Role holder, Conformance suite and Interposed holder are in [`docs/glossary/access.md`](../../../docs/glossary/access.md) and [`docs/glossary/code.md`](../../../docs/glossary/code.md).

## The problem

Today the root service gives each role to a module by its name: it starts `compositor`, `input`, `terminal`, `storage` and `network` by name, and the clients speak the private protocol of the module of today. The display protocol is a support package that 62 modules compile in, the compositor among them. Each client of the storage service maps the module file of that service at a fixed address to read its descriptions. The tool waits for lines that only our compositor writes. So no principal and no third party can put another module in the place of a role, or a module between a role and its clients, and a fault of one module is a fault of the whole desktop.

## The constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", and "20. No ambient access: the other holes to close": a process reaches a holder only through a handle that it was given. No name opens anything.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "6. One communication mechanism between processes": a role adds no channel. A call is a call ring, an event is a record output.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module", and [../api/module_replacement.md](../api/module_replacement.md): the check of a contract is the check of a replacement, which compares descriptions.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": an identity is a hash.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM": the display, the input and the console are the trusted path, and a choice of principal 0 that changes the start is measured.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": one mechanism for every role, and no copy tool.
- [../api/root_ring.md](../api/root_ring.md): trust already comes from the start grant set and never from the name.

## The chosen form

### A role contract is a description with a hash

A role contract is a file of the module format with no code: the exports of the role, its record types, its record outputs and its record inputs, as a module describes its own. The hash of the file is the identity of the contract. The contract has a number of version, which only orders the versions for a reader; the hash decides each check.

The set of the roles is a closed list: the enum `Role` of a contract package: `Display`, `Input`, `Console`, `Assistive`, `Speech`, `Terminal`, `Start_Policy`, `Storage`, `Network`, `Block_Device`, `Network_Device`, `Sound_Device`, `Entropy_Device`, `Tpm`, `Remote_Display`, `Plans`, `Projects`, `Recipes`. `Assistive` and `Speech` are the roles of [accessibility.md](accessibility.md). A word of a record becomes a role at one border, which refuses a word that names no member ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)). A new role is a new member, with its contract, in a commit that changes this file. Each delegated service of [../api/root_service_split.md](../api/root_service_split.md) becomes a member in the commit that builds it.

A module declares the contracts that it fills: a table of its module file lists the hash of each role contract that it fills. A module that fills two roles lists two hashes. The table is a statement of the author; the check below proves the types of it, and the conformance suite proves the behaviour.

### A service that is not a role

Not each service is a role. A role is a place that a principal or a third party can fill with another module, so it costs a contract with a version and a conformance suite. A service that one module serves, such as `manual`, `debugger` or `log`, is not a role until a second module must fill its place.

**The name is local, and the plan gives the hash.** A process reaches such a service as a declared dependency: its start grant set lists each service that it connects to under a local name, such as `manual`. The plan binds each local name to a module hash, and the signed image gives the default binding, as it gives the default roles. So the code says `manual`, and what it reaches is the module whose hash the plan fixes ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). A change of that hash is a change of the plan, which the principal sees in its difference.

**The name opens nothing by itself.** The root service makes a connection only to a local name that the start grant set of the caller lists. Any other name gives `No_Grant`, before the root service says whether a process of that name runs. A local name is a name of one start grant set and of one plan, never a global name. The tool checks each declared dependency against the bindings of the image at each build, as it checks the start grant sets today ([../api/root_ring.md](../api/root_ring.md)).

A client of such a service depends on the module that the plan binds: no conformance suite proves another module in its place, and no interposed holder stands in front of it. When a second module must fill its place, the service becomes a role, with its contract, its member of `Role` and its conformance suite, and each client then reaches it by the role.

### The check when the root service gives a role

The root service gives a role only to a module whose table lists the hash of the contract, and whose descriptions pass the check of a replacement against the contract: each export of the contract with the same description, each record type of the contract with the same layout, each record output and record input of the contract with the same record type. A module can have more exports than the contract. The check refuses with the difference of the replacement check (`Difference.Parameter_Detail` and the others), and one line that names the module, the role and the contract hash.

The check runs when the root service reads the plan, before any start: a plan that gives a role to a module that fails the check is refused whole, and its difference shows the refusal ([declarations.md](declarations.md), "Apply, the difference and the rollback").

### A process gets a connection, never finds one

A client of a role reaches the holder in one of two ways:

- **In its context, at its start.** Its start grant set names the roles that it needs: a window for each process with a surface, a terminal, a private store. The root service puts a connection to the holder of each in a context slot, as it does today for the window ring and the store.
- **With `connect(role.display)`, while it runs.** The argument is a member of `Role`, never a text. The root service refuses it with `No_Grant` when the start grant set of the caller does not hold the right to connect to that role, before it says whether a holder exists.

The root service makes the rings and the region of the connection, gives one end to each side, and then leaves the data path. It never forwards a record. The connection carries the hash of the contract that the client was built against, so the holder serves each client in the form of its version.

### The plan says who holds each role

The plan holds a table of the roles: `plan { roles = { display = catalog.compositor, storage = catalog.storage } }`. Each value is a module, by its hash, or a chain of an interposed holder and the holder below it. `plans.apply` shows the change of a holder in its difference, as it shows a grant; the principal accepts it with a key.

- **The default roles of the signed image.** The boot image holds a resource `default_roles`: one row for each role, with the name of a module of the image. The system description signs and measures it, as the start list. The root service gives these roles before any plan exists, and the tool refuses an image whose table names a module that fails the check of its contract.
- **The plan of principal 0** can name another holder for a role. The root service reads it at step 4 of its start, as the choice of a start policy ([start_policy.md](start_policy.md)), and gives the roles before the start policy runs. A change of a holder takes effect at the next start of the machine, never while the clients run.
- **A role in the trusted path** (`Display`, `Input`, `Console`, `Assistive`) takes a module of the disk only from the plan of principal 0, and the root service measures the hash of each such holder into PCR 12 before it runs, as it measures a start policy. These roles see the keys, draw the trusted surfaces or read each window, so no other principal chooses their holder, also not for its own session: a named principal chooses only among the holders that the image or principal 0 gives.
- **The rescue start policy uses the default roles of the image only.** A holder from the disk that fails cannot lock the principal out: the key R gives the rescue, its roles and its console.

Nothing looks a role up by a name at run time. The name of a role in a plan is a member of `Role`, which the evaluation process checks.

### Composition by interposition

A client holds a connection to the holder of a contract, and nothing else. So a process that fills the same contract can stand between the client and the holder: a filter, an auditor, a nested compositor, the remote display. This is the membrane of the capability systems (Mark S. Miller, "Robust Composition", 2006): a layer that forwards each call and each record, and can refuse one, change one or keep a copy.

- **By the plan.** `display = over(catalog.recorder, catalog.compositor)` gives the role to `recorder` for each client, and gives `recorder` a connection to `compositor` as a client. The root service checks both modules against the contract.
- **By a starter.** A process that fills a contract can be the holder for the processes that it starts: its `Start` names a role and itself, and the root service connects that child to it. The starter already controls its children, so it gains no authority. This is the routing of a capability by its parent in Fuchsia.
- **The handles that cross.** A contract that passes a handle (the memory of a surface, the content of a copy) passes it through the interposed holder, which gives it on. The handle then comes from the interposed holder, so a revocation of that holder ends each handle that crossed it: the membrane is revocable whole.

### Events without a bus

A role contract declares its record outputs: the windows that open and close for the display, the stops of the processes for the start policy, the changes of a setting. A process that needs one receives a wiring from the root service, by its start grant set or by the plan, as each record output is wired ([module_outputs.md](module_outputs.md)). Each subscriber has its own typed ring with no loss. A revocation ends one subscriber. No record goes to a process that has no wiring, and no process sees the records of another subscriber.

### Conformance

Each role contract has a conformance suite: a set of machine cases and host cases that a holder must pass, written against the contract and never against one holder. The suite of the display starts a client that opens a window, presents two pictures, takes a key, copies a text and closes, and checks the facts of the contract only. The tool runs the suite of each role against each module that a default role table or a plan of the tests names, so the claim "this role is replaceable" is a test that fails.

The tests of one holder stay: a test of the bar of our compositor waits for the facts of our compositor. A test of another part (the notes, `unlock`, the settings) waits for the facts of the contract.

### Trust comes from the role

A right of a process comes from its start grant set, which names the roles that it holds and the grants that each needs: the holder of `Display` gets the framebuffer and the input ring, the holder of `Console` gets the grant `Palette`. No rule reads the name of a module. The root service already applies this to the senders of the root ring ([../api/root_ring.md](../api/root_ring.md)); this design applies it to the roles.

## What a client can depend on

| A client can depend on | A client never depends on |
|---|---|
| The member of `Role` | The name of the module that holds it |
| The hash of the contract and its version | A support package or a private part of one holder, beyond the client side of the contract |
| The exports, the records and the record outputs of the contract | A fact, a line or a pixel that only one holder writes (a bar, a menu, a log line) |
| The refusals that the contract names | A fixed address where one holder maps its file |

The audit of the code against this table is in `ROADMAP.md`, one entry for each role. The display is the first, because it has the most clients and the trusted path.

## The roles of today

| Role | Holder of today | Scope of the holder | Faces |
|---|---|---|---|
| `Display` | `compositor` | The machine | The window ring, the capture face, the control ring, the palette ring; record outputs to design |
| `Input` | `input` | The machine | The input ring to the display holder |
| `Console` | `console` | The session | The palette provider; the line of Lex |
| `Assistive` | none yet | The machine, several holders at once | The assistive face of the display ([accessibility.md](accessibility.md)) |
| `Speech` | none yet | The machine | The record input of utterances and a timed stream ([accessibility.md](accessibility.md), "5. Speech") |
| `Terminal` | `terminal` | One client | The terminal ring and its text region |
| `Start_Policy` | `start_policy` | The machine | The root ring commands `Start`, `Stop`, `Machine_Usable`, `Wire` |
| `Storage` | `storage` | The machine | The exports of the storage service |
| `Network` | `network` | The machine | The control ring and the endpoint rings |
| `Block_Device`, `Network_Device`, `Sound_Device`, `Entropy_Device`, `Tpm` | `block`, `frame`, `sound`, `entropy`, `tpm` | One device | The class ring of each |
| `Remote_Display` | `remote_display` | The machine | Its protocol over QUIC; a client of the capture face |
| `Plans`, `Projects`, `Recipes` | none yet | The machine | The exports of [declarations.md](declarations.md) |

**One holder per scope.** A scope is the machine, a session, one client or one device, and a role has one holder in each of its scopes. The scope of a terminal is one client, so each process with a terminal has its own holder; the scope of a device class is one device. So "one holder" never means "one process for the machine": a role whose scope is a session has one holder in each session.

**The one exception is `Assistive`.** A principal with low vision uses a magnifier and a screen reader together, so the role takes several holders at once in one scope. Each holder has its own ring of the assistive face and its own wiring of each record output, and the display serves each one apart ([accessibility.md](accessibility.md), "2. The assistive role"). No other role takes several holders: two holders of the display or of the storage in one scope are two sources of one truth.

## The refused forms

- **A bus, in the manner of D-Bus.** D-Bus gives every process a global namespace of text names, lets a process find each service by its name, routes every call through a broker that sees the traffic, and broadcasts signals to each listener. Each of these is a hole of property 20: a global name, ambient discovery, a deputy that sees all, and an event that reaches a process that nobody wired. What modus takes from D-Bus: the idea that a service is reached by what it does and not by where it runs. What it refuses: the names, the discovery, the broker and the broadcast.
- **A registry of services by text name.** It is a global name that each process can ask for: the discovery that property 2 forbids, and a text that the root service parses. The role name is a member of an enum, and the process role is the right.
- **Broadcast signals.** A broadcast reaches each process that listens, with no grant, and drops a record for a slow listener or holds the writer for all. A record output gives each subscriber its own ring, with no loss.
- **A contract named by a text, such as an interface name with a version in text.** Two contracts with one name and two meanings meet at run time. The hash of the description is the identity, and the check compares descriptions.
- **The check of the name of a module before a role is given.** A module name is a statement of its author; the descriptions and the conformance suite are facts.
- **A role given while its clients run.** The clients hold handles of the old holder. The next start gives one holder and one state, as for the start policy.
- **A forwarder that adds nothing.** An interposed holder with no function adds a hop and is refused, as the `tee` module is refused by property 22.
- **Each service a role.** Each role costs a contract with a version and a conformance suite. A service that one module serves gets nothing from it until a second module must fill its place. It is reached by a local name of the start grant set, which the plan binds to a module hash ("A service that is not a role").
- **A service that is not a role, reached by its name with no declared dependency.** Such a name is a global name that any process can ask for, against property 20, line 11.
- **The local name resolved to a module by its name at run time.** A name then chooses the code, against property 11. The plan binds each local name to a hash, so the hash chooses the code.
- **A holder of a role of the trusted path chosen by a named principal, for its own session.** The holder sees the keys of the unlock, draws the trusted surfaces, or reads each window. A choice that principal 0 does not make and the TPM does not measure opens the trusted path to any module of the disk.
- **One process for each role on the machine.** A terminal, a console and a device class have one holder for each client, session or device. The rule is one holder per scope.
- **Several holders of any role.** Two holders of one role in one scope are two sources of one truth: two displays of one screen, two stores of one disk. Only `Assistive` takes several, because each holder only reads the trees and acts through declared actions.

What modus takes from the other prior art:

- **Wayland interfaces.** Taken: a typed protocol with a version that a compositor fills, and a client that names the version that it needs. Refused: the global registry of a Wayland display, where a client lists each global object and binds the ones that it wants. In modus, the root service gives the connection.
- **Fuchsia FIDL and its capability routing.** Taken: a protocol described in a language, named by its type, and routed to a child by its parent through a declaration of the component. Refused: a second language of description beside the module format, and the names of the paths of the namespace of a component. The module format is the one description.
- **xdg-desktop-portal.** Taken: a role (a file picker, a screen capture) that the desktop fills with its own implementation, so a process asks for the act and not for the module. Refused: the portal as a service of D-Bus, and the choice of the implementation by a text configuration file.
- **The membranes of the capability systems.** Taken: an interposed holder as a membrane, which wraps each handle that crosses it, so its revocation ends all of them. Refused: nothing; the form fits the handles of property 2 as they are.

## The subtle points

- **The versions of a contract.** A new version of a contract is a new hash. A client is built against one hash and asks for it in its connection. A holder that fills two versions lists both hashes in its table and passes the check against each; it reads the hash of each connection and serves that client in that form. A plan that gives a role to a holder that no longer fills the version of a client shows that client in its difference, before the principal accepts it. The root service refuses the connection of such a client with an error record that names both hashes.
- **A role with no holder.** A plan can leave a role empty, and a machine with no screen has no display holder. A context slot of a role with no holder is the handle 0, which the client reads as "no holder", as a process on a machine with no screen does today. `connect(role.display)` gives `Absent` with an error record that names the role. The start policy says whether the machine is usable without the role.
- **The start before any plan.** The root service gives the default roles of the signed image first, then the roles of the plan of principal 0 at step 4. The roles that the start needs before step 4 (the block device, the storage, the TPM, the entropy device) come from the image only: the plan is read through them, so it cannot choose them.
- **A holder that stops.** The kernel ends the handles of each connection, and each client reads the end at its next record, as at a revocation. The root service does not connect the clients to another holder in silence. A client that got the role in its context keeps the right to `connect` to that role again, so it opens a new window when the start policy starts the holder again. The new holder has no state of the old one: the contract says what a client sends again.
- **A nested holder.** A nested compositor holds `Display` for the processes that it starts and is a client of the holder of the machine. Its children see a holder like any other. Its own window is one window of the machine holder, so its clients reach no key and no pixel outside it.
- **The cost of an interposed holder.** Each call and each record crosses one more ring and one more process. The cost is measured on the three measures of the desktop ([desktop_to_browser.md](desktop_to_browser.md), "The three measures on the path of the system") with an auditor of the display and with none, and on a call of the storage service through an auditor. No number is assumed before the measure.
- **A face that is a ring.** The window ring, the terminal ring and the class rings carry handles in their records. A description of the module format cannot carry a handle in a record today: the record outputs refuse a Handle field ([module_outputs.md](module_outputs.md)). The contract of such a role needs a ring face in the module format: a command record type and an event record type, each a record description, with a field kind for a handle that the record gives and its rights. The display needs it first.
- **The palette provider is a role.** The compositor takes its provider from the start grant `Palette`, which is right, and then brings to the front the window of the module `console`, which is not. The provider is the holder of `Console`, and the window to raise is the window of that holder.

## The frequent tasks

| Task | Expression |
|---|---|
| See which module holds each role | `roles()` |
| Give a role to another module | `plans.apply(system with { roles = { display = catalog.other_compositor } })` |
| Put an auditor in front of the storage | `plans.apply(system with { roles = { storage = over(catalog.storage_audit, catalog.storage) } })` |
| Run the conformance suite of a role against a module | `modustool test conformance display other_compositor` |
| Reach the holder of a role from a process | `connect(role.storage)` |

## State

Designed, not built. Nothing of this file is in the code: the root service gives each role to a module by its name, and the clients depend on the holder of today. The steps, starting with the display, are in `ROADMAP.md`. The split of the root service by the same rule is [../api/root_service_split.md](../api/root_service_split.md).
