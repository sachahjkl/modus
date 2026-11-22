# The powerbox: grants that a running process asks for

A process starts with the handles of its start grant set and nothing more ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default"). Some needs are known only at run time: a network endpoint to a host that the principal typed, a store that the principal wants to open, a service that a document needs. The powerbox is the path by which a running process asks for such a grant. The principal sees the request on a trusted path, keeps or refuses each item, and picks the object when the object is a choice. The root service then gives reduced, revocable handles.

The grants of wide authority for an agent use the same parts with a screen and a proof of their own: [wide_grants.md](wide_grants.md).

## Purpose

- A process asks, in one typed record, for each object that it needs, with the rights and an optional reason for each.
- The principal sees one screen for many requests of one process, never a stream of dialogs.
- The principal keeps or refuses each item, and picks the object of an item that names no object. The process never sees the candidates.
- Each grant is a handle that the root service makes with the rights that the principal kept, records, shows and revokes.
- A process that asks again and again gets at most one screen at a time, and then no screen.
- The trusted path is a role and a contract, not a module: a replacement compositor that holds the role fills the same contract.

## Constraints

- **No text between processes** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes"). A request is a record. No word that the process writes is shown to the principal as prose.
- **No ambient access** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). Row 8: a process cannot draw a false system dialog. Row 12: a service does not combine its own access with a name from the caller. Row 13: each grant is recorded, visible and revocable. The cost line: too many questions train the principal to accept all of them.
- **The root service is the one source of grants.** No other process makes a handle that it does not already hold.
- **A new right for a process is the last answer** ([../README.md](../README.md), "The subtle points"). The trusted display already owns each key and each pixel; the root service already makes each grant. The powerbox gives each of them a new face, and no new authority.
- **The loop of the trusted display waits for no process** and does no work in proportion to a table that another process wrote ([palette.md](palette.md), "The constraints").
- **A disk process has no root ring** ([../api/root_ring.md](../api/root_ring.md), "Subtle points"). The processes that need the powerbox most are the processes that must never send a root command.

## The chosen form

Four parties:

1. **The asker**: a process with a window, which writes a grant request on its grant request ring.
2. **The root service**: it reads the request at one border, decides what can be asked, merges the requests of one process into one pending dialog, gives that dialog to the trusted display, checks the answer, makes the handles, and records each requested grant.
3. **The trusted display**: the one process that holds the role of the same name. Today it is the compositor. It draws the grant dialog and the picker, owns the focus while they show, and gives back the answer with the deliberate act that it saw.
4. **The source of the candidates** of a picker: the service that holds the objects (the storage service for a store). The root service asks it for the list on its own connection, and passes the names to the trusted display as data.

### The grant request

A grant request is a record of items. An item asks for one object with its rights.

| Field of an item | Form |
|---|---|
| Kind | `Grant_Item_Kind`, an enum of the contract |
| Object | The fields of the kind: an address and a port, the name of a service, or nothing when the principal picks the object |
| Rights | A set of the rights of the kind, carried as one word whose unknown bits the border refuses |
| Reason | Optional: `Grant_Reason`, an enum of the contract; the word 0 is no reason |
| Former grant | Optional: the number of a requested grant that the process holds, when the item asks for more rights on the same object |

A request holds 1 to 16 items. The process writes its items in its grant request region, one page that its budget pays and that the root service maps read-only. The ring record holds the serial of the request and the count of the items. The root service copies the items, then checks the copy ([../README.md](../README.md), "The subtle points", the count and the offset from another party).

**The kinds at first.**

| Kind | Object | Rights | What the root service makes |
|---|---|---|---|
| `Endpoint` | An IPv4 address, a port, and the transport (`Udp` or `Tcp`) | `Connect`, `Listen` | An endpoint of the network service with that grant word ([`docs/NETWORK.md`](../../../docs/NETWORK.md), "The grant of a segment endpoint"), through its control ring |
| `Store` | None: the principal picks it | `Read`, `Change` | A share of the root tree of the picked store, read-only unless `Change` was kept ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "4.3 Read only, and revocation") |
| `Service` | The name of a service of the table of requestable services | `Call` | A connection to the service that does not act for the principal: the caller sees its own data only |

**The kinds that come later**, each when its object exists: `Object` (one object of a store, from the document service, [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "U6. Document service"), `Endpoint_By_Name` (a host name that the network service resolves as a part of the grant, property 20, row 3), and device classes (`Sound_Output`, `Sound_Capture`, `Camera`), each a queue of a class service with a visible mark while it is in use (property 20, row 9).

**The reasons at first.** `Open` (to open what the principal chooses), `Save` (to keep what it makes), `Fetch` (to fetch data), `Send` (to send data), `Serve` (to answer other machines), `Use` (to use a service). One table of the contract gives the reasons that each kind takes; `Serve` with a store is refused. The trusted display shows the display text of the reason in the language of the principal ([enum_parameters.md](enum_parameters.md), "The display text of a member"), and the table of the texts of the interface in the language of the principal when that design lands. A reason is a claim of the process: the dialog says "it says: to fetch data", never "to fetch data".

**How a kind is added.** A kind is a member of `Grant_Item_Kind`, the fields of its object, its set of rights, its reasons, its check at the border, its maker in the root service, its display text, its candidate source if the principal picks the object, and its host tests and its case of the contract test. Each `switch` on the kind is whole, so the compiler names each place that a new member needs. Before 1.0 the contract changes in place, with no version beside it.

**The ring: a grant request ring, not the root ring.** Each process that the root service starts with a window gets one more handle in its context: the grant request ring, with its region. Its records are `Ask` and `Withdraw`; its completion is the answer. The root ring is refused for this: its border, its sender table and its commands reach the whole machine, and a disk process must never hold one. A ring of one purpose has one border with two kinds of record, which a fuzz target covers whole. A process with no window gets no grant request ring: the principal cannot relate a request to anything that it sees, and a process with no window takes its grants from its start grant set or from `allow`. A process of a terminal asks through the window of its terminal.

**The border refuses** a request with no item, with more than 16, an item kind that names no member, an object field that the kind does not take (a port 0, an address of the reserved table, a name of a service that the table does not hold, a name that is not an identifier), a rights word with an unknown bit or with no bit, a reason word that names no member or that the kind does not take, a former grant that the process does not hold or that is of another kind, and a request whose kind is a scope of wide authority. Each refusal is one error record with the unit `Grant_Requests`: `Bad_Value` with the item and the field, `Too_Long` for the count, `Reserved` for an object that no request reaches. A refused request opens no dialog and changes nothing. The decision is one pure procedure of the contract, `grant_request_decide`, which a host test and the fuzz target `grant_request` call with any bytes.

### The pending dialog: one screen for many requests

The root service keeps at most one pending dialog for each process. A pending dialog is the list of the items of each request of that process that is not answered yet.

- **The first request** opens the pending dialog, and starts a gather time of 250 ms on the clock of the system, never a count of loops or of records. Each request of the same process in that time joins the dialog. When the gather time ends, the dialog goes to the trusted display.
- **A request that arrives while the dialog is pending**, shown or not, joins it. The trusted display marks the new items, and arms its buttons again ("The deliberate act"). So many requests of one process give one screen.
- **A repeated item** (the same kind, the same object and the same rights) is merged: the dialog shows it once, and the answer gives each request that asked for it the same outcome and the same handle. Two items on one object with other rights are one row with the union of the rights, and each request receives the rights that it asked for and the principal kept.
- **An item that the process already holds** from the powerbox, with the same rights, gets the outcome `Held` with its handle at once, and no row.
- **The bound of the items.** A pending dialog holds 16 rows. A request whose new rows do not fit whole is answered at once with `Full`, each item with the outcome `Not_Asked`; it does not join in part. The process asks again after the answer of its dialog.

**Why 16.** One row for each item, grouped by kind, fits the reference screen at the scale 1.25 with its headings and its buttons, so the principal sees the whole list with no scroll: a list that scrolls has rows that the principal accepts and never saw. A process that needs more than 16 objects at one time asks for a broad authority, which is a start grant set, an `allow` or a wide grant. One page of the region holds 16 items with room.

**Why 250 ms.** A process asks for its needs on the path of its start or of one act of the principal: its requests come within a few frames. A gather time of a quarter of a second is shorter than the time in which a person reads a screen, and longer than such a burst. The tests never depend on it: a test sends several requests in one batch of its ring, which the root service reads in one pass, and a test that holds the dialog open sends more requests that join it whatever the time.

### The trusted display

The trusted display is a role that the root service gives to one process, as it gives each other role: the start grant `Trusted_Display` on one row of `start_grant_sets`. The tool refuses a table with two rows that hold it, and a disk process never gets it: the root service refuses it with `Reserved`, as `Screen_Capture`. Today the row of the compositor holds it, and the rule of the tool on the row of a part of the system (System_Part alone, with Serve for the compositor) takes `Trusted_Display` too. A replacement module of the compositor ([../api/module_replacement.md](../api/module_replacement.md)) takes the row, so it gets the role and the trust with it. **The trust comes from the role only**: a process that does not hold it and draws a dialog draws a window.

**The contract** is the package `modus:contract/trusted_display` and one ring between the root service and the holder, the trusted display ring.

| Record | From | What it carries |
|---|---|---|
| `Show_Grant_Dialog` | The root service | The serial of the dialog, the asker (its name or nickname, the whole hash of its module, its principal, the process that started it), and the rows in the order of the contract: grouped by kind in the order of `Grant_Item_Kind`, then in the order of their first request. Each row: its kind, its object or "a choice", its rights, its reason, and whether it is new since the last arming. The length choices that the asker can have. The act that the answer needs |
| `Show_Candidates` | The root service | The candidates of one row that the principal picks: names as data, with a change count |
| `Show_Wide_Grant` | The root service | The screen of a wide grant ([wide_grants.md](wide_grants.md)) |
| `Show_Plan_Difference` | The root service | The difference of a plan ("The relation to the other paths") |
| `Withdraw` | The root service | A dialog that ends with no answer: the asker stopped, or its session locked |
| `Mark` | The root service | The state of each mark that the holder must show: the pending dialogs, each wide grant that holds |
| `Shown` | The holder | The serial and the time on the clock of the system at which the dialog was whole on the screen |
| `Answer` | The holder | The serial, the hash of the record that the holder showed, for each row kept or refused, the pick of each row that has candidates (its index, the change count and the hash of the name), the length (this run, or always), "never ask again", and the act that the holder saw |
| `Revoke_Asked` | The holder | The principal pressed revoke on a requested grant or on the mark of a wide grant |

**What the contract fixes:**

- the content of each screen and the order of its rows;
- the act that an answer needs, and the arm time before an act counts;
- the focus: while a grant dialog shows, the holder gives no key and no press to any process, and no input from the input face of the remote display answers it;
- that the asker can neither draw nor drive the dialog: no record of the asker reaches the holder, and the holder takes no surface of a process into the dialog;
- the mark of each pending dialog and of each wide grant that holds, with its press that shows and revokes, on a place that no surface of a process covers;
- the key that always reaches the system: the key that opens the palette today, which lists each pending dialog as its first rows.

**What the contract leaves to the holder:** the look, the layout, the placement, the font, the rendering of the display texts in the language of the principal, and the code. The holder can be another compositor with another bar, or none.

**What the system checks of a holder.** The contract test is a machine test part that runs against the module that holds the role, whatever it is. It uses the test pointer of the tool ([../infrastructure/test_pointer.md](../infrastructure/test_pointer.md)) on the element lines that the holder writes for its trusted surfaces, with the act names that the contract fixes. It tries to break the holder first:

- a test asker that sends keys and presses while its dialog shows: the asker receives none, and the answer is not given;
- a press and a key on the dialog before its arm time, and a key whose press started before the dialog showed: no answer;
- input from a viewer of the remote display on the dialog: no answer;
- a window of the test asker raised over the place of the mark: a press on the mark still opens what the mark holds, and revoke ends the grant (the line of the root service says it);
- a dialog that grows while it shows: the act before the new arm time gives no answer;
- the last case: the act after the arm, and the answer that the root service takes.

The root service checks each answer itself too, so a faulty holder is caught on each machine and not only in the test: an answer of a serial that is not pending, of a record hash that is not the hash of the record sent, of an act that the dialog did not need, before `Shown` plus the arm time on the clock of the system, or of a pick that is not a candidate of the change count sent, is refused with one line, and the dialog stays pending.

### What the dialog shows

The trusted display shows, with no word that the asker wrote:

- the asker: its name, or for a disk process its nickname, which the principal chose, with the hash prefix of its module ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The grants of a disk process"); the process that started it when that is not the root service or the desktop;
- for each row: what the kind gives in words ("a network endpoint", "a store that you choose", "a connection to a service"), the object (`10.0.2.100 port 80, TCP`; `settings`; or a button that opens the picker), the rights in words, and the reason as the claim of the process;
- a tick on each row, set at the start;
- the length: "this run" and, for a disk process, "always for this module";
- the buttons: allow the ticked rows, refuse all, and refuse all and never ask again.

**How the principal tells a true dialog from a picture.** The holder of today shows three signs that no process can make:

- **The bar.** No surface of a process covers the bar. While a dialog shows, the bar holds its mark: "grant request" and the name of the asker. A picture inside a window cannot change the bar.
- **The panel joined to the bar.** The dialog grows down from the bar with no edge between them, in the color of the bar, so the bar and the dialog read as one surface. A window cannot join the bar: a part of its title stays under the bar ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "Palette"; the rule of the drag).
- **The key of the system.** The key super always reaches the holder. With a request pending, the palette lists it first. A principal who doubts presses super: a true request is there, a picture is not.

Refused signs: **a dim of the rest of the screen**: the design rules allow no scrim, and the proof is the bar, so a dim adds no proof; **a pointer shape of its own**: a process can draw a pointer in its surface, and the real pointer is beside it; **a secret picture that the principal chose**: one more thing to set, and a process that sees the screen through a grant learns it.

**The focus.** While a dialog shows, the holder takes each key and each press, as the palette does: the window in front receives none. The dialog shows only while a window of the asker is in front, so it never covers the work of another process. When the asker is not in front, its dialog waits; the bar shows the count of the pending dialogs, and the palette lists them. A choice there brings the window of the asker to the front, and the dialog shows.

### The deliberate act

An answer counts only after an arm time of 500 ms on the clock of the system, from the moment the dialog is whole on the screen, and again from each change of its rows. The focus starts on "refuse all". To allow, the principal moves the focus to "allow" (Tab, the arrows, or the pointer) and presses Enter or releases the press there. A key or a press that started before the arm time is not an act: the holder compares the time of the press with the time of `Shown`. Escape refuses all. A press outside the dialog does nothing, and does not reach the window under it.

Refused: **a second Enter**, as for an entry that destroys in the palette: a principal who types in the window of the asker gives two Enters easily. **A typed word**: a cost on each grant, which trains the principal to type it with no reading; the wide grant has its own act ([wide_grants.md](wide_grants.md), "The deliberate act").

### The choice of the object: the picker

A row whose object is a choice has a button that opens the picker: the list of the candidates, inside the same dialog, with the same focus and the same arm.

- **The candidates come from the service that holds the objects**, through the root service. For a store: the root service asks the storage service, on a connection of its own that acts for the principal of the asker and reads only, for the stores of that principal, and sends the names to the holder with `Show_Candidates`. The asker never receives the list: it receives a handle to what the principal picked.
- **The pick names a drawn row.** The answer carries the index, the change count of the list, and the hash of the name, and the root service checks the three against its copy, as the palette runs the row that is drawn ([palette.md](palette.md), "The subtle points").
- **The root service makes the share** on its own connection, with the rights that the principal kept, and gives its handles to the asker. It combines its access with a name that the principal chose on the trusted path, never with a name from the asker: the rule against the confused deputy holds.

Refused:

- **The picker in the trusted display with a connection of its own to the storage service.** The process that reads each hostile surface then gets the list of the stores and the right to share them: a new authority ([palette.md](palette.md), "The refused forms", the same reason as the compositor that dispatches entries).
- **A picker process with the right to list.** A second process with a broad right of the principal, and one more surface that a process can imitate.
- **The picker in the asker, with a list that the root service gives.** The asker then learns each object of the principal.
- **The document service draws its own picker.** The trusted path is then two processes. When the document service exists, it is the source of the candidates of the kind `Object`, as the storage service is for a store, and the trusted display draws them.

### The grant

- **The handle.** The root service makes the handle with the rights that the principal kept: the intersection of what the item asked and what the principal ticked. It never gives the right to revoke and never more rights than asked. The asker can pass the handle to a child, as each handle; `Handle_Revoke` ends it through each chain of gifts.
- **The record.** Each requested grant is a row of the root service: the process, its number, the kind, the object, the rights, the length, and the serial of the dialog. `grants("name")` lists them with the recorded grant `requested`. `revoke("name", "requested", number)` ends one, and `revoke("name", "requested")` ends all of them.
- **The window.** The trusted display lists the requested grants of the process of each window in the menu of the windows, from the records of the root service, and its revoke there sends `Revoke_Asked`. A revocation only takes authority away, so the holder gains nothing by it. This is the first answer to the open item of property 2: a window that shows the grants.
- **The answer to the asker** is one typed record for each request: for each item, its outcome (`Granted`, `Unticked`, `Refused`, `Not_Asked`, `Not_Grantable`, `Held`, `Ended`), the rights given, and the handles in the order of the items. An app learns item by item what it can do.
- **The length.** "This run" ends with the process. "Always for this module" applies to the rows that the principal kept, and is offered only to a disk process: the root service writes them in the row of its nickname in the disk grant table of the principal, bound to the hash of the module. At the next start of that hash, the same request is answered at once with no dialog, and the answer says `Granted` as before, so the asker has one code path. A move of the nickname to another hash drops these rows, with one line: the principal kept what that code asked, and other code can ask for other things. The grants that `allow` gives follow the nickname, as before: they are a decision of the principal on the nickname. The table holds 8 such rows for each nickname; past them, "always" is refused with its line and the grant is for this run.
- **The lock.** A lock of the session stops each process of the session, so each requested grant of this run ends with its process, and each pending dialog of the session is withdrawn with the outcome `Ended`. The rows kept "always" stay in the table.

### The bound of frequency

- **One pending dialog for each process.** Requests join it ("The pending dialog").
- **One dialog on the screen at a time.** The pending dialogs of other processes wait in a queue of 8 processes; a request of a ninth process gets `Busy` with no dialog.
- **A quiet time after a refusal.** When the principal refuses all, or the dialog of a process is withdrawn by Escape, each request of that process in the next 60 s on the clock of the system gets `Refused` with the outcome `Not_Asked` and no dialog.
- **A bound for a run.** After 3 dialogs of one process refused whole in one run, no dialog of that process shows again in that run.
- **Never ask again.** The button refuses all and records, for each kind of the rows, that the process asks no more: for this run, and in the row of the nickname for a disk process when the length is "always".
- **The ring is bounded.** The grant request ring has 16 records. A full ring stops its writer, the asker ([key_path.md](key_path.md)). The root service reads at most 4 records of one ring in one pass, so a flood of one process does not delay the others.
- **The counts.** The root service counts, for each process, the requests, the dialogs shown, the items granted, the items that the principal refused, and the requests answered with no dialog by cause (`Full`, `Busy`, quiet time, bound of the run, never ask again). `grants("name")` gives them, and the line of the stop of the process names them when one is not zero.

### The relation to the other paths

- **The start grant set.** The start grant set of a process of the boot image is fixed by the image and the plan; the powerbox adds to it for this run, never replaces it. An item for an object that the start grant set gives already is answered `Held`.
- **`allow` in the console.** The principal gives a grant ahead of any request, to a nickname. The requested rows kept "always" are rows of the same disk grant table, so `grants` shows both and `disallow` ends both. One table, two front ends.
- **`connect` in the console.** It connects the console by the start grant set of the console. It is not a request: the console holds that authority already.
- **`plans.apply`.** The difference of a plan is already one screen of many grants. The same contract shows it, with the record `Show_Plan_Difference`, so the principal accepts a difference on the trusted path and not in the console. It has no tick and no length: a plan is applied whole, because `Apply` names the hash of the plan and a ticked part is another plan with another hash. Its act is the act of a grant dialog; while a wide grant holds in the session, a difference that adds a grant needs the proof of the principal ([wide_grants.md](wide_grants.md), "Acts that still ask"). This answers the open question of [declarations.md](declarations.md) on the acceptance at a console that a remote client drives: input from the remote display never answers the trusted display.
- **The question of the console before a call** (the open item of property 19). It is the same mechanism, with the console as the asker. When a line calls an export with a Handle parameter that the line gives no value, the console sends a grant request with the kind of that parameter and a field "for the call of" with the hash of the module and the index of the export. The dialog names the console and the export. The console lends the handle for the call only ([`docs/glossary/access.md`](../../../docs/glossary/access.md), "Lent handle"), so it ends after the call. This needs the description of a Handle parameter to state the kind of its object beside its rights: a change of the format of the description, in its own layer. A second mechanism for the console was refused: two trusted paths that ask the same question drift apart (property 22).

## The refused forms

- **The request on the root ring.** The root ring reaches the whole machine; a disk process must never hold one.
- **A request as text, or a reason that the app writes.** The receiver parses, and the principal reads the words of the asker in the voice of the system.
- **One dialog for each request.** A process with ten needs gives ten screens, and the principal learns to press allow with no reading.
- **A dialog that the asker draws, or a library dialog in the asker.** The asker can then draw what it likes.
- **The picker with any authority outside the root service and the source of the candidates.** See "The choice of the object".
- **A dim of the screen as the sign of a true dialog.** See "What the dialog shows".
- **"Always" for a process of the boot image.** It gets its grants from the plan. Its authority is its row of `start_grant_sets`, which a signed image fixes, and the plan that the principal accepts; a third place then holds a part of its start grant set. A principal who wants a demonstration of the image to keep a store gives it in the plan.
- **"Always" as a row of the disk grant table by the hash of a boot module.** It is the same third place, under another key.
- **"Always" bound to the nickname.** A new file under the nickname then gets what another file asked for.
- **A trusted path bound to the compositor module.** A replacement compositor then copies the code or loses the trust. The role and its contract are the trust.
- **A request from a process with no window.** No principal can relate it to something seen.

## The prior art

- **OAuth 2.0 ([RFC 6749](https://www.rfc-editor.org/rfc/rfc6749), section 3.3, and section 5.1 for the scope of the answer).** Taken: a request lists its scopes; the screen of the authorization server lists them all at one time; the answer says which scopes were given, because the grant can be smaller than the request. Taken from incremental authorization (Google, `include_granted_scopes`): a process asks for more later, and a new screen shows only the new items, with what it holds already as `Held`. Refused: a scope as a text that the client writes and the server parses; a description that the client writes on the screen.
- **The runtime permissions of Android.** Taken: the request at the time of use, not at the install; a grant for this run only ("only this time"); the request refused with no dialog after the principal refused twice; one answer that lists each permission. Refused: groups of permissions that give more than the item asked; a dialog that the app can show in a loop until a later version bounded it.
- **The portals of Flatpak (xdg-desktop-portal).** Taken: the split of the portal front end, which holds the identity of the app and the store of the permissions, from the back ends (GNOME, KDE) that draw the dialogs: here the root service and the holder of the trusted display. Taken: the file chooser, which gives the app a handle to the document that the person picked and no path. Refused: requests and answers as D-Bus messages with text keys; an app identity from a name that the package declares, in place of the hash of the module.
- **Wayland.** Taken: one process alone, the compositor, sees each input and draws each pixel, and its protocol is an interface that many compositors fill; the security context protocol, by which an outside authority tells the compositor which client is sandboxed, as `Client_Add` tells the holder which window is an asker. Refused: a trusted surface that each compositor marks in its own way with no contract and no test.

## The subtle points

- **The order of the steps is a rule.** The border first, then the bound of frequency, then the merge, then the dialog. A request that the border refuses never counts as a request toward a bound.
- **The answer names the dialog that showed.** A dialog that grew after the press is a dialog that the principal did not see whole: the new arm time and the record hash refuse such an answer.
- **The gather time delays the first screen only.** It never delays an answer: a request that joins a shown dialog waits for the answer of that dialog.
- **A request in flight at a stop** is withdrawn: the trusted display removes the dialog, and the root service makes no handle for a process that stopped.
- **A holder that stops** loses nothing: the pending dialogs stay in the root service, which shows them again to the next holder. No answer is taken from a process that no longer holds the role.
- **A process of principal 0 while a named session is in front.** Its dialog waits until the session of its principal is in front, with no mark in the bar of the other session: the stores of principal 0 are not a choice of the session of a named principal, and the bar of that session names no process of the machine.
- **The reserved endpoints.** The ports of the services of the system (the port of `remote`, of `remote_display`) are in a table of the contract, and an item that names one is refused with `Reserved` at the border: the principal can grant only what it holds.

## Security

Each attack, and the answer to it.

- **A dialog that a hostile process imitates.** It draws in its own window only. It cannot change the bar, cannot join the bar, and is not in the palette after the key super. Its picture answers nothing: no grant comes from a process that does not hold the role.
- **Clickjacking: a press meant for the asker.** The dialog shows only while the asker is in front, its buttons are armed only 500 ms after it is whole, a press that started before that is not an act, the focus starts on "refuse all", and allow needs a move of the focus. A dialog that grows arms again.
- **A request just after the principal pressed a key.** The asker sees the principal type and asks at once, so that Enter lands on the dialog. The gather time delays the screen by 250 ms, the arm time adds 500 ms, the press of an Enter that started before `Shown` is dropped, and Enter on the first focus refuses.
- **A flood of requests: 50 000 requests one after another.** In full:
  1. The first request opens the pending dialog of the process and starts its gather time.
  2. The requests that follow arrive 16 records at a time: the ring holds 16, so the process waits for room after each 16, and the root service reads 4 of its records in each pass, so the other rings keep their turn.
  3. Each repeated item is merged into its row. New items join until the dialog holds 16 rows; each later request with a new item is answered `Full` at once, with no screen. Each request with only repeated items joins and waits for the answer of the one dialog.
  4. At the end of the gather time one dialog shows, while the process is in front. The principal sees one screen, at most 16 rows. While it shows, nothing new is drawn but the rows that joined, each with a new arm time; past 16 rows, nothing joins.
  5. The principal refuses all. Each request that joined gets its answer `Refused`. For 60 s each new request gets `Refused` with `Not_Asked` and no screen.
  6. After the quiet time the next request opens a second dialog; after a third refusal the bound of the run holds, and each later request of the run is answered `Refused` at the border of the bound with no dialog.
  7. The cost of the flood falls on the process: each request is one record that it writes and one answer that it waits for. The root service does a fixed work for each record, and the trusted display receives one record for each dialog, never one for each request.
  8. `grants("name")` then gives, for example: 50 000 requests, 3 dialogs shown, 0 items granted, 48 items refused by the principal, and the rest answered with no dialog by their cause. The line of the stop of the process names the same counts.
- **A request from a process that a remote viewer drives.** The dialog shows on the screen of the machine. The input face of the remote display never answers the trusted display, so a viewer, a human or an agent, cannot accept for the principal at the machine. A viewer with `View` sees the dialog, as each pixel; seeing it gives no act.
- **A principal at a remote viewer.** In the first layer a principal away from the machine answers no request: its requests wait for it at the machine. A later layer lets it answer through a viewer whose key holds `Input`, with the proof of the principal for each answer: the viewer sends the answer record with a signature of the principal over the serial and the record hash, and the root service checks the signature before it takes the answer. The input of the viewer alone still never answers.
- **A request while the session is locked.** The processes of a locked session do not run, so they ask nothing. A request in flight at the lock is withdrawn with `Ended`. A process of principal 0 can ask while a named principal is locked: principal 0 is then the session in front.
- **A request for a right that the principal does not hold.** The kinds name only objects that a principal grants: a reserved endpoint, a service outside the table and a scope of wide authority are refused at the border; the candidates of a store are the stores of the principal of the asker only, from the rule of the storage service ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "6. The store of a principal").
- **Escalation by chained requests.** Each item asks for one object; more rights on a held object is an item with a former grant, which the dialog shows as "more rights on" that object. A granted handle never carries the right to ask: an item never names a handle, and the asker asks for itself only. A process holds at most 32 requested grants; past that the root service answers `Full`. A child that the asker starts with a held handle asks through its own window, and its dialog names the asker as the process that started it.

## The order of the work

Each layer works alone and adds one capability. The order starts with the object that needs no picker and whose grant already changes at run time.

1. **The contract, the ring and the endpoint.** The packages `grant_request` and `trusted_display`, the grant request ring with its border and its fuzz target, the start grant `Trusted_Display` with its check of the tool, the endpoint kind (the network service already takes `Endpoint_Grant` while a process runs), the pending dialog with the merge, the bounds of frequency, the length "this run", `grants` and `revoke` of the requested grants, and the contract test with the compositor as the holder. Why first: it proves the whole path with the smallest object, and every later kind reuses it.
2. **The picker and the store.** `Show_Candidates`, the connection of the root service that lists the stores, and the share. It needs the first layer and the existing `share` of the storage service.
3. **The service kind** and its table of requestable services.
4. **The requested grants in the menu of the windows**, with their revoke.
5. **"Always" and "never ask again"** in the disk grant table, with its new format.
6. **The difference of a plan on the trusted path**, when the service `plans` exists ([declarations.md](declarations.md), "The build order").
7. **The console asks before a call**, with the kind of the object of a Handle parameter in the description.
8. **The later kinds**: an object of the document service, an endpoint by name, the device classes.
9. **The answer of a principal at a remote viewer**, through a viewer whose key holds `Input`, with the proof of the principal for each answer.

The wide grants come after the first layer, with their own order ([wide_grants.md](wide_grants.md), "The order of the work").

## Open questions

- **The values of the bounds** (250 ms, 500 ms, 60 s, 3 dialogs, 16 rows, 8 kept rows): set by this design; a measure with a person at the machine can move them.
- **The table of requestable services**: which services give a connection that shows the caller its own data only.

## State

Layer 1 built: the contract package `src/library/modus/contract/powerbox` (closed enums, grouped consent request batch up to 16 items, sealed trusted Display dialog record with canonical BLAKE3 digest, picker candidate list isolated from the asking process, and strict border validators), `Role.Powerbox` and `powerbox_contract()` in `src/library/modus/contract/role_contract`, the pure policy and state machine `src/library/internal/powerbox/powerbox_core` (window check, 3-dialog per-session queue bound, 250 ms anti-clickjacking arm delay, 500 ms per-process rate limit, 60 s expiry and refusal quiet time, 3-refusal run cap, `Held` shortcut, hash-bound `Always` rows for disk modules only, store picker isolation, and whole-or-nothing `Show_Plan_Difference`), and the freestanding service module `src/modules/system/powerbox`. Wiring into the compositor UI, root service handle minting, disk grant table persistence, and machine conformance tests remain.

Layer 4 built in the compositor, with its places and its acts in the pure package `src/library/internal/compositor/bar` (`window_grants.odin`) so a host test reads the layout of the screen. Each grant that the principal allows in the grant dialog of the compositor is a row of a bounded table of 32 grants, with a number that is never given twice in one run; a name that does not fit is refused whole, never cut. The menu of the windows lists, under each window, one row for each grant of its process: the key icon, the object, and a button Revoke. A press on the button, or Enter or Space on the row, ends the grant at once and the menu stays open; a press elsewhere on the row does nothing. Each grant of a process ends when its window closes. The facts `Window_Grant_Recorded`, `Window_Grant_Revoked` and `Window_Grants_Ended` say each change. The exports `window_grants()` and `revoke_grant(number)` give the same table and the same revoke to a caller that acts for the principal. The table is in the compositor, not in the root service: the revoke sends no `Revoke_Asked` yet, and ends the row that the compositor shows, until the root service makes the handles and holds the records.

Layer 6 has its dialog in the compositor, with no caller in `plans` yet: the export `plan_diff_ask(name, added, removed)` shows the name of a plan, what it adds (`+`, in the color of an expected answer) and what it removes (`-`, in the coral of a failure), at most 8 items on each side, in the frame and the tokens of the grant dialog in both appearances. Its state is `bar.Plan_Difference_Dialog` (`plan_difference.odin`). The act is the act of a grant dialog: the focus starts on Refuse, an act counts 500 ms after the dialog showed, Tab and the arrows move the focus, Enter acts on the button that has it, a press on a button acts on that button, and a press elsewhere reaches no window. Escape refuses at once: a refusal gives nothing, so it needs no arm. One dialog of the trusted display shows at a time: the grant dialog and the plan dialog refuse each other with `Busy`. The facts `Plan_Difference_Accepted` and `Plan_Difference_Refused` record the decision. The lists are names that commas separate, as the texts of `powerbox_ask`: a stand-in for the record `Show_Plan_Difference` of the trusted display ring, which the root service sends when `plans.apply` calls it.
