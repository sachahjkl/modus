# Several machines

A principal uses more than one machine: a desktop, a laptop, a machine at home with the large disks. This file records how modus works across them: how a machine proves who it is, how a principal pairs two machines by an explicit act, how a principal lives on several machines, how a role of one machine serves the processes of another, how two machines exchange the versions of one store and merge them, and which objects cross and which never leave a machine. It is layer 5 of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users".

The terms Machine identity key, Pairing, Pairing code, Paired machine, Machine list, Remote role, Mesh frame, Relay envelope, Store exchange, Common version, Merge export and Conflict value are in [`docs/glossary/access.md`](../../../docs/glossary/access.md) and [`docs/glossary/storage.md`](../../../docs/glossary/storage.md). Client key, Client table and Use of a client key are in [`docs/glossary/access.md`](../../../docs/glossary/access.md); Object cache and Realisation in [`docs/glossary/code.md`](../../../docs/glossary/code.md).

## Purpose

Today a machine of modus is alone. A client of `remote` or a viewer of `remote_display` proves its key, and a principal allows that key for its uses ([remote_client_keys.md](remote_client_keys.md), [remote_display.md](remote_display.md)). The other direction has no identity: `remote` makes a new key at each start, and a client pins it from the log. Two machines of one principal do not know each other, cannot give each other a role, and cannot keep one store on both. The design must give each of these with no ambient access, no discovery, and no server of authority.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", and "20. No ambient access: the other holes to close": no process reaches another machine because it runs. Line 3: a network grant names the hosts. Line 11: no global name. Line 13: each grant is recorded, visible, and can be revoked.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": each change is a version, and no save action exists. Two machines that change one store must keep that rule on each machine.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": an object is its hash, so its bytes can come from any source.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM": the TPM seals a key to the measure of the system, and use 3 of the TPM is a proof of the system to a remote party.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": the protocols between machines carry records.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": the identity across machines is a public key; layer 5 says that the key of the principal signs the key of each machine, and that a signed grant that left a machine needs a short lifetime or a revocation list.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task": a paired machine is a client key with uses, not a second mechanism beside the client table.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable", and [roles_and_contracts.md](roles_and_contracts.md): a role is a typed contract that the root service gives to a role holder, and a client gets a connection to the holder, never finds one. An interposed holder fills the same contract between a client and the holder. A role held on another machine is such an interposed holder.
- [supervision.md](supervision.md): what the root service does when a holder fails. A link that breaks is a failure of a holder, seen from its clients.

## The chosen form

### The identity of a machine

**The machine identity key** is an Ed25519 key pair of principal 0. Its public key names the machine to other machines, and nothing else does: no host name, no address, no serial number.

- **Its seed comes from the machine key.** The seed is keyed BLAKE2b of the machine key over the fixed text `modus machine identity key`, as the key of the tag of the disk grant table is ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "Principal 0 and its machine passphrase"). So the identity key has the three forms of the machine key with no new record: sealed by the TPM to PCR 7 and PCR 11 (`MACHINET`), sealed by the TPM with the machine passphrase (`MACHINEP`), or under the machine passphrase alone (`MACHINEK`). It has the same recovery key. A machine with no machine key draws an identity key at each start, as `remote` draws its key today, and the key lasts until the machine stops.
- **Where the TPM exists, the TPM roots it.** The TPM releases the machine key only to the system whose measure it holds, so another system on the machine, and a copy of the disk on another machine, cannot prove the identity. The attestation key of the TPM, when it is built, stays in the TPM and signs a quote of PCR 7, PCR 11 and PCR 12 whose qualifying data holds the hash of the public identity key and a nonce of the asker. So a paired machine can ask which system holds the identity, with no second key to trust.
- **The root service holds the secret key; `remote` never does.** `unlock` gives the root service the seed with the key of the tag, at the open of the machine key. `remote` reads hostile bytes from the network, so it never holds the long-term key: it sends the root service the transcript hash of a handshake, and the root service signs the content of a TLS 1.3 CertificateVerify over it (the 64 spaces, the context text of the server or of the client, the zero byte, the hash). The root service refuses each other content, so a fault of `remote` can make the identity key sign a handshake, and never a grant, a release pointer or a record of the machine list. This is the factotum of Plan 9: the network code asks an agent with no network to sign.
- **`remote` presents the identity key.** The server key of `remote` and of `remote_display` becomes the identity key in place of a key for each start. So a client pins one key for the life of the machine key, and a pin no longer breaks at each start of the service.

**How it compares with the keys of today.**

| Key | Who holds it | What it proves | Its life |
|---|---|---|---|
| The server key of `remote` today | `remote` | This start of `remote` | One start |
| A client key | A client: the tool, a viewer | The client that a principal allowed for its uses | Until a revocation |
| A viewer key | A client key with the use View | The same, for the screen | Until the machine stops |
| The machine identity key | The root service, from the machine key | This machine, on this system where the TPM seals it | The life of the machine key |

A client key stays the key of a client that is not a machine of modus: the tool, the viewer, an agent. A paired machine is a client key too, with its own uses, so one table and one revocation serve both.

### A principal across machines

A principal is one principal root key across its machines: its identity across machines is the public key of that root key (property 21). The root key stays offline. Each machine of the principal holds its own keys of the principal, which the root key signs. On each machine, the principal has its own session, its own stores, its own disk grant table and its own grants. A pairing never gives a process of one machine a grant on another machine; it gives a row of the client table, which the principal sees and revokes.

- **The principal root key stays offline.** It is an Ed25519 key pair whose secret key is on no machine of modus: on a removable disk, or as a recovery text on paper, which the principal brings to a machine for an act of the root key and takes away after it. No store holds it, no TPM seals it, and no machine keeps it after the act.
- **One key for each machine.** At a join, `unlock` on the new machine makes the keys of the principal there, as it makes them for a new named principal, and seals them in the form `PRINCIPT` with the TPM of that machine, with a recovery key of its own. No secret key of the principal crosses a network, also not inside the pairing connection.
- **The root key signs each machine key.** The act of the join brings the root key to the new machine: the root service there signs, with the root key, the public signing key of the principal on that machine, with the identity key of the machine and its uses, in a new machine list. The root key then leaves the machine.
- **The machine list.** The root key signs one record for the machines of the principal: for each machine, the identity key of the machine, the public signing key of the principal on that machine, its uses, and a number that only grows. Each machine of the list keeps the newest list that it has seen, and refuses a list with a lower number. So a join on one machine makes the new machine known to all of them at their next contact, and the removal of a lost machine is a new list with no row for it, signed by the root key on any machine of the list. This is the form of a release pointer ([declarations.md](declarations.md), "Declaration inputs, pins and release pointers"), with the principal as its publisher.
- **A machine with no TPM, or with Secure Boot off, refuses the join of a named principal by default.** There the keys of the principal are under the passphrase alone, so a copy of the disk allows an attack on the passphrase away from any TPM, with no count of the tries. The setting `principal_join_without_tpm` of principal 0 on that machine accepts the join; `unlock` then shows a warning in its window that says this, before the principal types the passphrase. The pairing of principal 0 needs no such setting: it carries no key of a named principal.
- **The rows of each machine.** The root service of each machine derives, from the newest machine list of a principal, one row of the client table for each other machine of the list, with the uses of the list, for that principal. The rows last as the disk grant table of the principal lasts. A row with no list behind it is a pairing of principal 0, which has no signing key: the two machines then know each other only by the rows that the pairing wrote.
- **The grants on each machine are per machine.** The plan of the principal on each machine says which roles another machine holds for it and which stores it exchanges. A plan can name a paired machine only by its identity key, through the machine list.

**What a stolen machine gives.** The thief holds the keys of the principal on that machine, sealed by its TPM with the passphrase. Without the passphrase, the count of the TPM limits the tries. With it, the thief acts as the principal on that machine and toward the other machines, while the machine is in the list. The thief cannot sign a machine list, because the root key was never kept there. So the removal of a stolen machine is a new list with no row for it, signed by the root key, and the principal keeps its identity.

### A role held on another machine

A **remote role** is a role whose holder runs on a paired machine: the storage at home while the display is here, a sound device, the builders of recipes.

- **The form is interposition.** On the machine of the clients, `remote` is the role holder for the clients of that role, by the plan of the principal: `plan { roles = { storage = machine(home).storage } }`. It fills the role contract, and it carries each call and each record of the contract over QUIC to `remote` on the paired machine. There, `remote` asks its root service for a connection to the real holder, for the row of the paired machine, as it asks today for a connection to a service for a client key. So a client sees a connection to the contract and nothing else, and the holder at home sees a client that acts for the principal of the row.
- **Only a contract of calls and records crosses.** A face of a contract that lends memory or carries a handle (a surface, a window ring, a mapped object) cannot cross a machine: a handle names an object of one kernel. A role with such a face is not a remote role. The display of another machine is the remote display, which copies pixels and has its own protocol.
- **The latency is stated in the contract.** A local call costs microseconds; a call to a machine of the local network costs about a millisecond, and across the Internet tens to hundreds of milliseconds. A role contract states, for each export, whether a remote holder is acceptable.
- **The storage at home holds only while the link holds.** A process sends each change when it occurs (property 9). With the storage at home, each change crosses the link, and with no link each change fails with `Unreachable`: the document stays whole at home, but the change is not kept. So the storage at home fits a machine with no disk of its own on a network that holds. A principal who works on both machines with no link exchanges the store instead ("The exchange of a store between machines").
- **A call has an outcome, a refusal, or no known outcome.** A call whose answer did not come before the link broke can have run: `remote` answers it with the status `Unknown_Outcome`, never with a refusal. The link sends a call again only when the contract marks its export as idempotent. A client never waits past the bound of the call.
- **A record output across a link has a stated capacity.** The writer at home never waits for a link. Past the capacity of its side, `remote` counts the records that it drops and sends one gap record with the count when the link comes back. No record is dropped in silence.
- **What a client sees when the link breaks.** Each call in flight ends with `Unknown_Outcome`, each new call with `Unreachable`, at once, while `remote` tries the link again with a growing interval. The role stays given: the root service does not take it back. A link back is a record of the role, so a client that waits for it gets a wake, not a poll. Whether the root service then gives the role to another holder of the plan is a decision of supervision.
- **The revocation crosses the link.** A revocation of the row of the paired machine, a lock of the session of its principal and a new machine list without it each end the connections that the root service made for the row, as for a client key, and `remote` ends the QUIC connection with the code `Revoked`.

### The exchange of a store between machines

A **store exchange** keeps one store of a principal on two machines or more. Each machine has the whole store and writes it at once, also with no link: property 9 holds on each machine. When the machines meet, each sends the versions that the other lacks, and each machine merges.

**The versions become a graph.** Today the versions of a store are a line of generations. With two writers, a version has one parent or two. The exchange needs three things of the storage service:

- a version of a whole store with a tree hash, so two machines compare a store by one hash and exchange only the trees that differ, by hash, with the protocol of the cache;
- the parents of each version, so a merge has two parents;
- the **common version** of each paired machine: the newest version that both machines hold. The retention rule never thins it, because it is the base of the next merge.

**The forms compared.**

| Form | What it gives | What it costs | Decision |
|---|---|---|---|
| CRDTs (Automerge, Yjs) | Two replicas converge with no conflict and no server; good for live edits of one document | The format of the data must be a CRDT, so the system cannot apply it to any store; the history and the tombstones grow; a merge that converges can give a state that no one wrote (two edits of one field: the last writer wins) | Allowed inside a module, behind the merge export; not the mechanism of the system |
| The operational transform | Live edits of text, as Google Docs | A server that orders the operations, a transform function for each pair of operations, and a link at each edit; the proofs of its properties failed for years | Refused: two machines of modus change a store with no link |
| A three-way merge by type, with a resolution that the principal makes | The base is the common version; an object that changed on one side is taken; an object that changed on two sides goes to the merge of its type | A merge for each type; a conflict needs the principal | Chosen as the merge |
| The model of Jujutsu: a conflict is kept in the data | A merge never stops: a conflict is a value with its base and its sides, which a later change resolves, once, on any machine | A reader of the object must know the conflict value | Chosen as the form of a conflict |

**The chosen form: a three-way merge by type, with the conflict kept in the data.**

1. For each object of the store, the merge compares the object in the common version and in the two new versions, by hash. An object that only one side changed takes that side. An object that both sides changed to the same hash is equal.
2. An object that both sides changed goes to the **merge export** of the module that owns the store: `merge(base, ours, theirs) -> Merge_Result`, an export that its module describes (property 19). The module of a store knows its format: a text merges by lines, a table by the key of its rows, a CRDT document by its own merge, which never conflicts.
3. A store whose module has no merge export, and a merge that cannot decide, give a **conflict value**: the object holds the hashes of the base and of the two sides, and the merge commits it. The exchange never stops on a conflict, and both machines keep working.
4. The principal resolves a conflict once, in the module that owns the store or in a generic view that shows the two sides. The resolution is a change like any other: it is a version, and it crosses to the other machines with the next exchange.

**The merge runs where the store is.** Each machine merges with the module of the store, in a process of the session of the principal, started by the storage service for the merge, with a connection to that store only. The merge is in no service with a wider grant.

**The answer to the open question of [declarations.md](declarations.md).** "Two machines that change one source give two trees": the source of a project is a store, so its two trees are two versions with a common version, and the same merge applies. A text object of a source merges by lines; `pins.lex` merges as a record by its fields, and a conflict of one pin is a conflict value that `projects.update` resolves. Git is not involved: it stays an import and an export format.

**Which stores are exchanged.** Only a store that the plan of the principal names, with the machines that hold it: `plan { exchange = [ store("notes", machines = [machine(laptop)]) ] }`. A store is never exchanged by default.

### Objects by hash between machines

The cache protocol of [recipes.md](recipes.md), "The object cache and its protocol", is the base: `Object`, `References`, `Realisation`, `Release_Pointer`, `Has`. A paired machine is an object cache of the other, with its identity key in place of the key of a cache endpoint. The exchange of a store adds one request, `Versions(store, since)`, which gives the hashes of the versions after a common version; each tree and object then crosses by `Object`, which checks itself.

**What is shared**, and only for the principal of the row:

- the objects of `module_files` that a plan of that principal reaches: modules, debug objects, trees, realisations, release pointers. `Has` answers only for the objects that the principal of the connection reaches, so a machine does not tell one principal what another holds;
- the versions of the stores that the plan of that principal exchanges with that machine;
- the newest machine list of the principal.

**What never leaves a machine:**

- the records of the keys: the machine key, the file of a named principal, the recovery copies, and each store of `unlock`. Each is sealed to one TPM and one system, so a copy elsewhere is useless and only gives an attacker a target. No secret key of a principal crosses: each machine makes its own, and the root key is on no machine;
- the disk grant table and the client table: a grant is a fact of one machine, signed with the key of the tag of that machine;
- the applied plans and the row "current plan": the system that a machine runs is a fact of that machine. The declaration that gave it is a tree, which can cross;
- the log, the fault records, the measures and the TPM floors;
- each store that holds a secret, whose versions a process with the grant `Versions_Erase` ends;
- each handle, each memory object, and the state of each process.

### Pairing, and no discovery

A machine finds another only when the principal pairs them by an explicit act. The pairing gives each machine the identity key of the other, the uses, and an address to try.

1. On the first machine, in a console that acts for the principal, `machine_pair()` asks the root service for a pairing, and `unlock` shows the **pairing code** in its window, a trusted surface: an address of the machine, and a secret of one use of 50 bits as ten groups of base32. A QR code in the same window holds the same code and the whole identity key, for a device with a camera.
2. On the second machine, `machine_join("<code>")` makes `remote` connect to the address. Neither key is pinned yet: the handshake proves each identity key, and the pairing code then runs the PAKE CPace over the group Ristretto255 over the TLS exporter of the connection, so both sides prove the same code and bind it to both identity keys. A relay on the path that does not know the code learns nothing and cannot pass the check.
3. Each window then shows the head of the identity key of the other machine and the uses, and the principal accepts on each machine with a key. Each root service writes the row of the other machine in the client table and in the disk grant table of the principal.
4. One wrong code ends the pairing on both sides, and the code is spent. The code ends 10 minutes after it was shown.

**The PAKE is CPace over Ristretto255.** CPace is a balanced PAKE of the CFRG of the IRTF, still a draft; the design follows the draft until it is published as an RFC, and then follows the RFC. It needs one exchange of one point each way and a hash, over the group Ristretto255, which the cryptography of Odin has and the copy of the system adds for it. A balanced PAKE fits: both machines know the code, and no machine stores a verifier.

**The address.** The pairing code holds an address, and each connection after it tells the paired machine the addresses of the machine. When an address changes, the next contact from the other machine carries the new one; when both changed, the principal gives an address with `machine_address(key, "…")`. An address is never a grant: the handshake decides, by the identity key.

**A machine behind a NAT.** The principal gives a reachable address: a port that the router of the network forwards to the machine, given with `machine_address`. When no address is reachable, a machine of the same principal that both machines reach can relay their datagrams, as "The relay envelope" says. The relay is a paired machine that the principal chose, never a server of the project.

**The address hint on the local network.** It is off by default, and the setting `machine_address_hint` turns it on for one machine. When it is on, the machine sends on the local link only, at its start and at each change of its address, a datagram that holds its address and a tag that only its paired machines can check: a keyed BLAKE2b of the identity key over a fresh nonce, with the nonce. It holds no name and no identity key in clear. A paired machine that checks the tag takes the address as a hint and tries it; the handshake decides, as for each address. It is off by default because it tells each host of the local network that a machine of modus is there.

**The listen grant.** Today the listen grant of `remote` admits only the host at the gateway. A machine that pairs gets a listen grant that admits each address, and the handshake with the client table decides. The Retry and the budgets of work of QUIC ([`docs/QUIC.md`](../../../docs/QUIC.md), "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)") bound what an unknown address costs.

**mDNS broadcast is refused as a source of authority.** Any host of the local network can answer an mDNS question with any name and any address, so a name that a broadcast gives proves nothing. A name of the network that every process can resolve is a global name (property 20, line 11). A machine that announces itself tells each network where it is, which is a fact that the principal did not grant. A grant must come from the principal, as a record that the principal sees; a packet from the network is no such record. The address hint above is no discovery: it reaches only a machine that was paired already, and it gives an address, never a grant.

### Sharing between two principals

A principal shares an object or a role with another principal by a **signed grant**: a record that the signing key of the giver signs for the public root key of the receiver. Sharing between principals is the second half of layer 5 of property 21; it uses the machine lists and the client table of this file, and adds one record and one check.

**The record.** A signed grant holds:

- what it gives: a share of one object of a store of the giver, with Read or with Read and Write, or a connection to one role of a machine of the giver, by its role contract;
- the identity key of the machine that serves it, which is a machine of the machine list of the giver;
- the public root key of the receiver;
- an end time on the clock of the system, and a grant serial that names the grant in a revocation list;
- the signature of the signing key of the giver on the machine where the giver made the grant, a key that the newest machine list of the giver names.

**The check.** The receiver connects to the serving machine with a key of a machine of its own list, and presents the grant and its newest machine list. The root service of the serving machine checks, in this order, and refuses at the first fault with an error record that names it: the signature of the giver against a key of the newest machine list of the giver that this machine holds; the identity key of this machine in the grant; the machine list of the receiver, signed by the root key that the grant names; the key of the handshake in that list; the end time; the grant serial against the revocation list of the giver. Then it makes the connection that the grant names, for the receiver, as it makes a connection for a row of the client table, and it writes the grant in the act records of the giver.

**A short life or a revocation list.** A signed grant left the machine that made it, so a revocation does not reach a copy of it at once (property 21, "Cost"). Two forms bound it, and each grant takes one:

- **A short life.** The end time is at most one day after the grant, and the receiver asks the giver for a new grant to go on. No list is needed: a grant that leaks ends with its day.
- **A revocation list.** A grant with a longer life holds the grant serial of a revocation list of the giver: a record that the signing key of the giver signs, with the serials of the revoked grants and a number that only grows. Each machine of the giver keeps the newest list, and it crosses with the machine list. The machine that serves the grant is a machine of the giver, so a revocation made there holds at once; a revocation made on another machine of the giver holds at the next contact between the two.

**What the receiver gets.** A connection for its own principal, never a row of the client table of the giver and never a grant of the giver. The receiver cannot give the grant on: a signed grant names one receiver root key, and the serving machine checks the key of the handshake against that root key. A receiver that wants to share further asks the giver.

**The frequent tasks.**

| Task | Expression |
|---|---|
| Share a store with another principal for a day | `share_with(principal_key, store("notes"), rights = .Read)` |
| Share for longer, with a revocation | `share_with(principal_key, store("notes"), rights = .Read, until = date(2027, 6, 1))` |
| See what this principal shared | `shared()` |
| End a share | `share_revoke(serial)` |

### The frames on a stream of remote

The protocols between paired machines cross the QUIC connection of `remote`, on the streams that the calls of the host use (`modus:contract/machine_wire`). Each stream carries one request and its answer, then the end of the stream, as a call does.

- **The first word of a stream chooses the protocol.** A call request starts with the word of `Request_Kind.Call`, a mesh frame with the word of `Request_Kind.Mesh`. `request_check` refuses the word `Mesh`, and `frame_decode` refuses each other word, so a stream reaches one protocol only. Both protocols share the stream records, the bounds of time and the limit of bytes of `remote`.
- **A mesh frame.** A header of 16 bytes: the kind word, the message word, the count of the body, a zero word; then the body. The answer is one frame: the answer message of the request, or a `Refusal` with its reason and the status of the contract that refused. `frame_decode` is the border of the message word.
- **The transport names the peer, never the frame.** `serve` takes the identity key that the handshake proved, and the principal root key of the list that names it. A body that names another key is refused: the associated data of CPace must be the key of the handshake, and a grant is checked for the receiver that the transport proved. Today `remote` proves a principal only for a machine of the newest machine list of its own principal, because a machine of another principal does not present its list yet.
- **Who a stream of a paired machine reaches.** The handshake of `remote` admits a key of the client table, a key of a paired machine, and, while an offer is open and its code has not ended, the key of the machine that pairs (`peer_admits`). The service ends an offer whose code ended at its next pass (`pairing_expire`), which erases its secrets and ends the connection of its machine. A connection of a paired machine with no row of the client table carries mesh frames only: a call request on it is refused with `No_Grant`. When its row ends, the connection ends with the code `Revoked`.
- **Each request is authorized before any table is read.** A machine that is not paired reaches the two pairing steps only; each other request is refused with `Not_Paired`. A paired machine reaches a request only when the grant of the plan gives it the use of that request (`Machine_Use`: `Objects`, `Stores`, `Roles`, `Relay`, `Grants`); else the refusal `Use_Not_Granted` names the use. A pairing gives no use. A grant holds only while the row of the paired machine holds.
- **A signed grant needs a pairing.** The authority of a share is the signed grant, but the machine that presents it is a paired machine with the use `Grants`, and the transport must prove the principal of the receiver; with no proven principal the refusal is `No_Principal`. A machine of another principal is paired by its principal as any machine, and presents its machine list in a later step.

**The messages.**

| Request | Answer | What it does |
|---|---|---|
| `Pairing_Element` | `Pairing_Element_Reply` | The joiner sends its CPace element and its key; the offerer answers its element, its key and its confirmation tag |
| `Pairing_Confirm` | `Pairing_Confirmed` | The joiner sends its tag; the offerer writes the row and answers the fingerprint of the session key, which the joiner compares with its own |
| `Object_Request` | `Object_Response` | A kind, a hash and the offset of a piece; the size of the whole object, the offset and the bytes of the piece. The receiver computes the hash of the whole object again before it keeps it |
| `Grant_Present` | `Grant_Accepted` | A signed grant of another principal; its serial and its end time |
| `Store_Offer` | `Store_Offer_Reply` | A page of the version of an exchanged store, or the request for a page of the reply; the cursor of the next page, or a page of the version of the receiver before its merge |
| `Role_Call` | `Role_Reply` | One call of a role contract; its outcome, its integer result and its bytes |
| `Relay_Deposit` | `Relay_Deposited` | A relay envelope for a routing token |
| `Relay_Collect` | `Relay_Delivery` | The oldest envelope of a routing token, byte for byte |

**The pairing in frames.** A wrong code fails the check of the tag on the joiner. The joiner still sends its own tag, so the offerer fails too, and the code ends on both machines. A confirm from another key than the key of the exchange is refused, and does not end the exchange.

**The channel binding.** CPace binds the code to the connection by a channel identifier. The design names the TLS exporter, but the QUIC library has no exporter yet. Until it has one, the binding is a keyed hash of the two identity keys that the handshake proved (`channel_binding_of_identities`). A relay that ends the handshake with its own key gives other bytes. Two connections of the same two machines give the same binding, and the code still runs one exchange only.

**The uses of a pairing.** The window of `unlock` that shows the head of the other key before the principal accepts is not built. Until it is, the principal gives the uses at the offer and at the join (`mesh_pairing_offer`, `mesh_pairing_join`), and the row takes them when the exchange confirms.

**An object in pieces.** An object of any size crosses in pieces of `OBJECT_CHUNK_BYTES`: the receiver asks for each piece at the offset that the answer before gave, writes it past the bytes in use of its store, and keeps the object only when its last piece came and the whole object hashes to its hash; a piece out of order or past the size ends the object, and nothing is kept. The process sizes its store of objects from its budget: the contract fixes no count of objects and no size of an object. Refused: a frame as large as the largest object, which bounds an object by the buffer of a stream.

**The store exchange in frames.** A version has any count of entries, so it crosses in pages: each page names the hash of the whole version, its counts, and the cursor where it starts, and the reader appends the pages in order and checks the hash of the whole version before any merge. The sender offers a snapshot of its version, with the hash of its common version, page by page; the receiver takes each page (`Page_Taken`), and at the last one computes the merge before any change, applies it, and answers the first page of its version before the merge. The sender asks for each other page of that reply (`Reply_Page_Request`), and merges at the last one. The versions of a store are memory of the caller, divided among the stores that the peer holds: the budget of the process, not the contract, sets how many stores it exchanges and how large a version is. Refused: an offer whole in one frame, which stops the exchange at the entries of one frame; a page by an identifier as its cursor, which a write between two pages moves. The sender merges the same three versions. The merge is symmetric, so both machines end with one common version and one set of conflict values. A write of an object that holds a conflict value is refused until the principal resolves it, once; the resolution crosses with the next exchange.

- **Each version carries its conflict records.** A record crosses with its entry. Its reader computes its hash again from its base and its sides, and refuses a record that its entry does not hold and that no other record of the object names.
- **A write in flight is kept.** The sender writes while its offer waits, to its current version; the snapshot does not change. When the reply comes, the sender merges the snapshot with the reply, then merges its later writes over that result, with the snapshot as their base. A later write of an object that the merge also changed gives a conflict whose side is the conflict value of the merge: the version keeps both records, so the write of each machine stays a side. One resolution ends both.
- **The common versions must agree.** An offer, and a reply, whose common version is not the common version of the reader are refused with `Refused_Base_Differs`, and nothing changes.
- **The recovery of a lost reply.** The receiver merged, and its reply was lost: its common version is newer than the common version of the sender. The sender keeps its offer in flight and sends the same snapshot again from its first page. The receiver keeps the last exchange that it answered (its common version before it, the hash of the offer, and its reply), and answers the first page of the repeat with the first page of the same reply, and each request for a page of it from that reply, with no change. The sender then reaches the same common version. An offer of the receiver in the meantime is refused by the sender, as its common version differs.
- **Two offers at once.** Each machine answers the offer of the other and merges; the two merges are equal, and each machine drops its own offer, whose reply now names an older common version and is refused.

**A role call in frames.** The proxy on the machine of the clients keeps each call in flight with its bound; a bound whose end passes the largest time is refused. A refusal that says the call did not run (`Role_Refused`, `Not_Paired`, `Use_Not_Granted`) is `Refused`. A holder that ran and then broke its contract (a count past its result, an outcome of a link) gives `Role_Holder_Fault`, which the proxy reads as `Unknown_Outcome`, as a malformed reply, a reply for another call, a reply with an outcome of a link, a break of the link and a passed bound. A call that starts while the link is broken gives `Unreachable` at once. An idempotent call waits for the link and goes again.

### The outbound link

The frames above are answered by `serve`. The other direction is the **outbound link** (`modus:contract/machine_wire`, `client.odin`): this machine opens a QUIC connection to a paired machine and sends the requests. One session, `Mesh_Link`, holds one link: the key that it pins, its state, and the requests in flight with their bounds. The transport stays outside the session, so `remote` drives it from its QUIC loop, and a scheduler or a host test drives it over a transport that answers at once (`Mesh_Transport`).

- **The link pins the key before it connects.** A link of purpose `Paired` opens only to a key of a row of the paired machines; a link of purpose `Pairing` opens only while this machine joins an offer with a code that has not ended, by the rule of `peer_admits` (`Refused_Code_Expired`). The TLS handshake of the client pins the same key, and the session checks the proved key once more (`mesh_link_established`): any other key breaks the link, and no frame leaves.
- **A link carries the requests of its purpose only.** A paired link carries `Object_Request`, `Store_Offer` and `Role_Call`; a pairing link carries `Pairing_Element` and `Pairing_Confirm`. A frame of another kind, or an answer message, is refused before it leaves.
- **Each request ends in one of four ways.** `Answered`: the answer message came. `Refused`: the other machine refused it before it ran (`Not_Paired`, `Use_Not_Granted`, `Role_Refused`, `Object_Absent` and each other reason that the server writes before it acts). `Unknown_Outcome`: the request left, and the link broke, the bound passed, the stream was reset, or the answer was malformed, another message, or a `Role_Holder_Fault`: it can have run. `Unreachable`: the link was not up, so it never left. A link that breaks during the handshake ends its requests `Unreachable`; a link that breaks once up ends them `Unknown_Outcome`.
- **The effect of an answer is checked as on the server.** An object is kept only when its bytes hash to the requested hash (`object_response_accept`). A role reply must name the call of the request in flight: a reply of another call, late or out of order, is `Unknown_Outcome`. A store reply merges as the receiver merged, and a lost reply keeps the offer in flight, so the next sync sends the same snapshot and the partner answers it again. A pairing link that breaks fails the pairing: the code is spent on this machine, and the joiner keeps no row of a pairing that it did not see confirmed.
- **In `remote`.** `mesh_client.odin` holds two links, each a QUIC connection of a client whose key is the identity key of this machine, and four streams. A datagram goes to a link only when it comes from the address and the port of that link and the Destination Connection ID of its first packet is the identifier that the connection of the link chose; each other datagram goes to the server. So a machine that connects to this machine while this machine connects to it, from one address and one port, reaches the server, and one address and port has one link at most. A pairing request that ends with no confirmation fails the pairing and removes the row of the offerer that it wrote, and a paired link ends with the code `Revoked` when its machine is no longer paired; the loop sends the datagrams of each link after the pass of the server, and waits for the nearest deadline of the links. `mesh_connect`, `mesh_fetch_object`, `mesh_call_role`, `mesh_sync_store` and `mesh_pairing_join_send` start a step and give an error record for each refusal; `mesh_request_result` gives the end of a request, with the error kinds `Refused`, `No_Answer` for `Unknown_Outcome` and `Link_Down` for `Unreachable`.

**Refused: a request that the link sends again by itself.** A request with `Unknown_Outcome` can have run; only its caller knows whether a second run is safe. A build of a recipe is safe to run again, so the distributed builder sends it to another builder ([recipes.md](recipes.md), "Builds across paired machines"); a role call goes again only when its contract marks the export idempotent.

**Refused: the key of the link from the answer.** A frame names no key: the handshake proves it. A link whose pinned key comes from an answer would let a machine on the path choose who this machine talks to.

### The relay envelope

A relay carries the datagrams of two machines that cannot reach each other: a machine of the principal that both reach, and that is paired with both.

- **The envelope holds a routing token and sealed bytes.** The two ends share a key from their pairing. The sender seals the datagram with ChaCha20-Poly1305 under that key, with the routing token as its associated data, and puts the nonce before the sealed bytes. The envelope adds no identity key, no address and no plaintext. The relay holds no key: it cannot open, change or forge an envelope. It knows the two ends of each route, which its principal named, and the keys that the handshakes of their connections proved.
- **The routing token** is a keyed hash of the shared key and an epoch (`relay_routing_token`). The relay cannot link two epochs of one pair.
- **A route has one sender and one receiver.** The principal of the relay adds a route with its token, the machine that deposits and the machine that collects; two directions are two routes. A deposit of another machine, and a collect of another machine, get the refusal of an unknown token, also from a paired machine that learned the token: it can neither take the envelopes of the route nor fill its queue, and it learns nothing of the routes of others. Both ends need the use `Relay`.
- **The queue of a route is bounded, and an envelope has a lifetime.** Past two envelopes, a deposit is refused, never dropped in silence. An envelope that waited one minute is dropped, so a sender whose receiver is gone gets its route back. The end of a route erases what waits on it.

## The prior art

| Work | What modus takes | What modus refuses |
|---|---|---|
| Plan 9: 9P, per-process namespaces, cpu servers, factotum | A resource of another machine has the same interface as a local one: a remote role fills the same contract. A process sees what its starter gave it, as a namespace of Plan 9 is per process. The secret key in an agent with no network that signs for the network code (factotum). The cpu server as a later remote role of a builder | Files and text as the one interface (properties 3 and 19). A mount by a path. A process that changes its own view of the world: here the plan and the starter decide |
| Syncthing | A device is the hash of its key. Both sides add each other before any exchange. The exchange of content by hash in blocks | A conflict as a file beside the original, with a name that the principal must find. The broadcast of the local discovery, and the global discovery servers, which know where each device is |
| Tailscale and WireGuard | A peer is its public key and nothing else, and the key decides what the peer reaches (the routing by key of WireGuard). The address learned from the last authenticated packet | The coordination server of Tailscale as the authority of the keys, and the login through an identity provider. A tunnel of layer 3, which gives a whole network and each port of the other machine in place of one role |
| SPKI/SDSI and UCAN | A grant as a record that one key signs for another key, with an end time, checked by the party that serves it with no server of authority | The chain of delegations, by which a receiver gives a part of its grant on: here a receiver asks the giver. A name of SDSI as a second name of a key |
| Fuchsia Overnet | A typed protocol carried between devices by a part that looks local to both ends | A mesh that routes between nodes, so a node reaches the nodes behind another. Any handle passed across devices: a handle names an object of one kernel, and its revocation is no longer local. mDNS as the way to find a device |

## The frequent tasks

| Task | Expression |
|---|---|
| Pair this machine with another | `machine_pair()` here, then `machine_join("<code>")` there |
| See the paired machines of this principal | `machines()` |
| Remove a lost machine from every machine | `machine_remove("<key>")` |
| Hold a role on another machine | `plan { roles = { storage = machine(home).storage } }` |
| Keep a store on two machines | `plan { exchange = [ store("notes", machines = [machine(laptop)]) ] }` |
| See the conflicts of a store | `storage.conflicts("notes")` |
| Fetch the objects of a plan from a paired machine | the substitution policy names it as a source, by its identity key |

`machines()` is the client table and the machine list of the principal in one table: an alias, no mechanism ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task"). `machine_remove` signs a new machine list and revokes the row; `remote_disallow` revokes the row on this machine only.

## The refused forms

- **A second table of machines beside the client table.** Two tables for "a key from outside acts for a principal here", with two revocations that drift.
- **The long-term key in `remote`.** `remote` parses hostile bytes; a fault there then gives the identity of the machine for ever.
- **The TPM signs each handshake.** Few TPMs sign with Ed25519, the transport speaks Ed25519 only, and each handshake then waits for the TPM service. The TPM roots the identity through the seal and the quote.
- **A key of the machine apart from the machine key.** A new record, a new seal and a new recovery key, for the same life and the same root.
- **One signing key of the principal, copied to each machine.** A thief of one machine who learns the passphrase can sign a machine list, and the only answer is a new identity of the principal, whose new list each machine takes only from a machine of the old list. With one key for each machine under a root key that stays offline, a stolen machine is removed by a new list and the identity stays.
- **The root key kept on a machine, sealed by its TPM.** The theft of that machine with the passphrase then gives the root key, and the gain of the two levels is lost.
- **The join of a named principal on a machine with no TPM, or with Secure Boot off, with no setting.** A copy of its disk gives an attack on the passphrase with no count of the tries. The setting makes the choice visible and the warning says its cost.
- **SPAKE2 as the PAKE.** It is an RFC (RFC 9382), but it needs two fixed points of the group whose discrete logarithm no one must know. CPace needs no fixed point, and the CFRG chose it as its balanced PAKE.
- **A relay of the project for the machines behind a NAT.** A relay learns when two machines speak, and the project then runs a server for every principal. The relay is a machine of the principal, paired, with a route that its principal adds.
- **A relay frame that names the destination by its identity key.** The first form of the relay frame carried that key in clear in each datagram. The routing token names a route of one epoch, and the envelope adds no key.
- **A route that any paired machine with the token can use.** A token can leak; a machine that knew it could take the envelopes of the route or fill its queue. A route names its sender and its receiver.
- **The address hint on by default.** Each machine then tells each local network where it goes that a machine of modus is there.
- **A signed grant with no end time and no revocation list.** A copy of it gives access for ever, against property 20, line 13.
- **A signed grant that its receiver gives on.** A chain of delegations makes each check walk the chain, and the giver no longer knows who holds its object.
- **A certificate authority, X.509 certificates, or a name that a server gives.** A server of authority over every machine of every principal.
- **Discovery by mDNS, by a broadcast, or by a directory server.** See "Pairing, and no discovery".
- **A pairing by a long code typed by hand.** A whole key in base32 is 52 characters; a short code with a PAKE gives the same proof.
- **A role that crosses with a handle or shared memory.** A handle names an object of one kernel.
- **The storage at home as the one way to keep a store on two machines.** Each change then waits for the link, and no change is kept without it.
- **A call sent again by the link with no mark of the contract.** A call that ran once then runs twice.
- **CRDTs as the mechanism of the system.** They fix the format of each store; a module that wants one keeps it behind its merge export.
- **The operational transform.** It needs a server and a live link at each change.
- **A merge that stops on a conflict until the principal answers.** Both machines then stop the exchange of the whole store for one object.
- **A conflict as a second object with a derived name.** The principal must find it by its name, and a process that reads the store does not know it.
- **The last writer wins.** A change is lost in silence (property 9 promises that a document is never lost).
- **Each store exchanged by default.** A store of secrets then leaves the machine.
- **A tunnel that gives the whole network of another machine.** Ambient access to each of its ports.

## Subtle points and hazards

- **The identity key has the life of the machine key.** Today each update of the system asks for the recovery key one time. The identity does not change, because the recovery key opens the same machine key. A machine with no machine key changes its identity at each start, and a pairing with it lasts until it stops.
- **A machine passphrase delays the identity.** Until the passphrase is typed, the machine has no identity key, and `remote` accepts no paired machine.
- **The signer checks the form, not the intent.** The root service signs any CertificateVerify content that `remote` gives. A fault of `remote` can prove the identity in a handshake that it chooses while the machine runs; it cannot take the key away.
- **The machine list is a monotonic record, not a log.** A machine that never meets the others keeps an old list, and trusts a removed machine until its next contact with a machine of the newer list. A short life of each row bounds this; its length is an open question.
- **A restore of the disk can bring back an older machine list**, as it brings back an older disk grant table. A counter of the TPM that only grows ends both ([processes_from_a_disk.md](processes_from_a_disk.md)).
- **The merge needs object identifiers.** Today an object has a name in its store. A rename on one side and a change on the other are then a removal and a new object. Property 9 asks for identifiers; the exchange depends on them.
- **The common version pins old blocks.** A paired machine that never comes back keeps the common version from thinning. The removal of the machine from the list ends that pin.
- **A conflict value is a new kind of object.** Each reader of a store must refuse it or show it, never read its bytes as the content. The border of the storage service gives the kind.
- **The merge export runs foreign code on two foreign versions.** It runs in a process with a connection to that store only, and its result is checked as any write.
- **`Has` and `Versions` leak.** A question tells the other machine what this machine wants. A machine asks only paired machines.
- **A call with no known outcome is not a failure.** A client that treats `Unknown_Outcome` as a refusal and asks again runs the call two times.

## The order of the work

Each step adds one capability to a system that works.

1. **The identity key from the machine key**, signed by the root service for `remote`, and the server key of `remote` and of `remote_display` as that key. The tool pins one key for the life of the machine key.
2. **Pairing of principal 0 by a code**: the PAKE, the window of `unlock`, the row of a paired machine in the client table, and the listen grant of each address. Two test machines on one network of the tool pair, then one refuses a wrong code.
3. **Objects by hash between paired machines**: the cache protocol over `remote`, with a paired machine as a source of the substitution policy.
4. **A principal joins a second machine**: the principal root key, the keys of the principal made and sealed on the new machine, the machine list that the root key signs, and the setting for a machine with no TPM.
5. **A remote role** of a contract of calls and records, with `Unknown_Outcome`, `Unreachable` and the gap record.
6. **Versions as a graph, with a tree hash for each version of a store**, after the object identifiers.
7. **The store exchange and the merge**, with the merge export and the conflict value.
8. **The quote of the TPM** over the identity key, after the attestation key.
9. **Signed grants between two principals**, with the short life and the revocation list.
10. **The address hint on the local network**, behind its setting.

## Open questions

- **The life of a row of the machine list**, and whether a machine that does not meet the others for that time loses its rows.
- **A fallback holder of a remote role** when the link breaks: a second holder in the plan, or nothing. It belongs to supervision.

## State

The freestanding contract layer in `src/library/modus/contract/machine_mesh` is built and tested on the host: the monotonic signed machine list under the offline principal root key with default non-TPM join refusal and opt-in warning, the off-by-default keyed BLAKE3 local network address hint, signed cross-principal grants with one-day expiry or monotonic revocation lists, the store delta sync wire protocol with pure three-way fast-forward and conflict-fork reconciliation, and CPace PAKE over Ristretto255 (`CPaceRistretto255`) with mutual key confirmation.

The same package holds the pairing by a code (`pairing.odin`): a 50-bit code as ten characters of base32, a session that runs CPace once with the TLS exporter as the channel identifier and each identity key as the associated data of its side, a ledger of spent codes, the bounded table of paired machines, and the holder of the newest machine list, which removes at once the row of each machine that a newer list no longer names as active. A refusal at any step ends the session and erases its secrets. `modus:contract/machine_sync` holds a bounded store of objects by hash that keeps an object only when its bytes hash to the requested hash, and its replay set of cross-machine grants refuses each grant once it is full.

`modus:contract/machine_wire` holds the frames of "The frames on a stream of remote" and the state of one machine (`Peer`): the dispatch `serve`, the pairing by frames, the fetch of objects by hash in pieces, the check of a presented grant, the store exchange in pages with its conflict values and their one resolution, the proxy of role calls, and the relay envelope with its routes. Its tables (the objects, the stores and their versions) are memory of the caller (`Peer_Memory`), and each has a growth procedure that the contract calls when a table needs room. The memory of the mesh: `remote` holds the object bytes, the object rows and the store rows in arenas as large as its budget that commit the exact pages of each growth (`exact_commits`), and each version in a memory object of its own, which a growth replaces by a larger one and closes. Before each growth it counts the pages that the growth commits, from `arena_push_commit_pages`, or the size of the new object with its frame list (`op.memory_list_pages`), which the budget pays too, and `machine_wire.memory_growth_allowed` refuses a growth that would leave less than 512 pages of the budget (`MESH_BUDGET_KEPT_PAGES`) for the streams and the window: a step of the arena never takes the kept pages. One store holds at most a quarter of the rest, and one partner at most a half: the versions of its stores and the object in assembly that it sends, which counts as a store of its own too (`Memory_Shares`), so one partner cannot hold the mesh. A version that a refusal empties (a page out of order, a hash of the whole version that its pages do not have) closes its object, an offer that starts again from its first page gives back the pages of the offer before it that stalled between two pages, a store that the plan stops exchanging gives back the objects of its versions, and the row that a later store takes starts with no page counted, and an object that does not prove its hash, or stops between two pieces, trims the arena of the bytes: the pages that a partner made the mesh take go back to the budget at once. A growth that the budget or a share refuses refuses the write, the page or the piece that needed the room, and the store keeps what it held. A sync that stops between two pages ends with `Stopped_Between_Pages` (`No_Answer` at the export of `remote`), never as done. The room of a version or of an object grows with each page and each piece that arrives, never with the total that the sender states: a total is a claim until its bytes come. The missing objects of a sync (`machine_sync.store_missing_hashes`) are a page of two sorted lists from a cursor, so a list of hashes has any length. Its host tests run two and three peers in memory through the frames, and try each refusal; they exchange 300 notes in pages, six stores, and an object of 2 MiB in pieces; with tables that start empty, 1000 notes, 20 stores and an object of 3 MiB; and with a budget that pays for about 100 notes, an offer of 1000 refused at its page and an object refused at its piece. The delta sync of `modus:contract/machine_mesh` (`store_sync.odin`) carries an object in pieces of `SYNC_CHUNK_BYTES` with the size of the whole object, and its host test receives an object of 200 KiB in four pieces.

`remote` holds one `Peer` (`src/modules/system/remote/mesh.odin`): it takes its own public key as the machine identity at its start, draws the code and the CPace scalar from its generator for keys, and checks the signatures with the module cryptography. Its handshake admits paired machines and the machine of an open offer, and a stream whose first word is `Mesh` goes to `serve`. Its identity is still the key of one start, because the root service does not hold the machine identity key yet.

`modus:contract/machine_wire` holds the outbound link (`client.odin`): the session of one link with its pinned key, the four ends of a request, and the requests of the joiner, of an object, of a role and of a store over a transport that answers at once. Host tests check each refusal of the session, a handshake that proves another key, an object with one changed bit, each end of a role call, a lost reply of a store offer, and a pairing link that breaks. `remote` drives the same session from its QUIC loop (`mesh_client.odin`), with the key of this machine as the key of the client. The links keep no copy of that key: `mesh_connect` copies it from the server, which keeps it for its life, into the configuration of one start, and erases that copy with volatile stores on each path. Refused: a copy in the memory of the links from the start of `remote`, which waits there while no outbound link runs.

Left: the identity key from the machine key in the root service and `unlock`; the TLS exporter as the channel binding; the window of `unlock` that shows the code and the key of the other machine; the listen grant of each address, so that the network service carries the datagrams of an outbound link to another address than the host, and the calls that start an outbound link from a console; the rows of paired machines in the client table; the holder of a remote role, which asks the root service for a connection to the real holder; the store exchange in `storage`, with the merge export; the end-to-end sealing of the relay in the modules; and the multi-machine QEMU tests.
