# The client keys of remote

## Purpose

A call from another machine acts for a principal that allowed its client, and for no other. Before this design, the program `remote` admitted the host by its address alone: each program of the host that reached the address of the gateway called as the principal of the session of `remote`, and the system could not tell one client from another.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": a grant is recorded, visible, and can be revoked; the principal is the only source of a new grant.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": a remote caller is a program tree that received handles from a principal; identity across machines is a public key.
- The root service is the one holder of the grants. A service learns the principal of a caller from the grant of its connection, never from the caller.
- No stream of a client is read before the client is known: a call must not run, even in part, for a key that no principal allowed.
- The QUIC library of the project is its own code: what it supports is what it implements, and its handshake reads only raw public keys.

## The chosen form

**The proof: mutual TLS 1.3 with raw public keys.** The server of `remote` sends a CertificateRequest; the client answers with its Ed25519 key as a raw public key (RFC 7250, `client_certificate_type`), a CertificateVerify signed with the context string of a client, then its Finished. The library verifies the signature first, then gives the proven key to a procedure of its caller (`Tls_Configuration.client_key_check`). A refusal fails the handshake with access_denied. The transport of a server opens no 1-RTT packet before the handshake is connected (RFC 9001, section 5.7), so no stream of a refused client is ever read. The form is the standard one: the signature covers the transcript, so it binds the key to this connection and to the key of the server, with no format of the project.

**The grant: a row of the client table, in the root service.** A principal allows a key with `remote_allow(key)` from a console that acts for it (`Root_Command.Remote_Client`). The root service writes the row: the key, the principal of the caller, a serial, and the state of the session of that principal (a row of a locked principal holds no grant until the unlock). One principal holds 4 of the 8 rows at most (`remote.CLIENT_ROWS_OF_ONE_PRINCIPAL`), so a principal that allows many keys leaves rows to the others. The table is one page that the root service writes and that `remote` maps with the right Read only, by its start grant `Remote_Clients`: `remote` reads each grant and gives none. The form is the form of the replacement table, which loaders read the same way.

**The principal of a call: a connection to a service for one row.** `remote` binds each QUIC connection to the row of the proven key, and sends `Connect` with the row and its serial. The root service checks that the row holds that serial and that the session of its principal is not locked, and gives the connection the principal of the row, with the flag to act for it. So the principal is decided by the root service from its own table, not by `remote`. Each rule of the root service that compares a principal with the caller of a connection reads it through `connection_principal`: the debug access of a client is the debug access of the principal of its row.

**The end of a grant: a serial.** A revocation frees the row; a lock of the session of its principal, and the unlock after it, give the row a new serial. The root service ends each connection to a service that it made for the row, then wakes the version word of the table. `remote` waits on that word with its other waits, reads the table at each pass, and ends the QUIC connection of each client whose row no longer holds its serial, with the application code `Revoked`. At each pass it also frees each of its connections to services whose row no longer holds its serial, whether a client of that row is connected or not; the root service ended the other side already, so `remote` tells it nothing. Without that, a grant that ends while no client is connected (a lock and an unlock, a revocation after the client left) would keep its slots, and a few lock cycles would fill the 24 slots. A key whose grant ended is refused in its next handshake.

**What an unknown client gets.** The alert access_denied in its handshake, before any stream, and one line on the log of `remote` with the key, while the log has room in that second (the bound of 50 lines of connections). The client of the tool reads the alert as the outcome `Client_Refused`, with a reason that says to allow the key.

## Refused forms

- **A signature over the handshake in the first stream.** The stream exists before the proof, so `remote` would hold streams of a client that nobody allowed, and the binding of the signature to the connection would be a format of the project. The handshake already has the transcript and the rule of no 1-RTT before the end.
- **The keys in a store of the principal.** `remote` would read the stores of each principal, which the storage service refuses to a caller that acts for one principal, and the grants would have a second holder beside the root service.
- **A table that `remote` writes, or the principal that `remote` names in its Connect.** `remote` would choose for whom it acts. The root service gives the principal from its own row.
- **The check of the key at the Certificate of the client, before its signature.** A peer that does not hold the private key would learn which keys are allowed.
- **One key for several principals.** A call would not say for whom it acts; `Remote_Client` refuses a key that another principal allowed (`Exists`).
- **The end of a grant at the root service alone.** The connections to the services end, but the open QUIC connection would stay until its idle timeout, and its next call would make new connections. `remote` ends it at once.
- **A wait for the next deadline of QUIC before the end.** A quiet connection has no near deadline: the revocation would wait for the idle timeout. The root service wakes `remote` on the version of the table.
- **A start grant `Remote_Clients` that a revocation ends.** The table gives nothing by itself: each row is a grant of a principal, which that principal revokes. The end of the handle would unmap a page that `remote` reads at each pass.
- **The address alone.** The listen grant still admits the address of the host only, as a second fence, but it names no principal.

## Subtle points

- The client is connected in TLS before the server checks its key: it sends its Finished right after its proof. A refusal then ends a connection that the client counted as made. The peer of the tool fails each call of that connection at once and makes no new one for them.
- The row can end between the check of the handshake and the first pass of `remote` (`client_bind`): `remote` reads the table again before it binds, and ends such a connection with `Revoked`.
- The end of a grant is enforced by the end of the connections to services, not by a check of each call. The order: the root service writes the row, ends each connection of the row (a Disconnect on the service ring of each service), then wakes `remote`. A service reads its service ring before its call rings in each pass (`service_run`), so a call that waits in the ring of an ended connection is dropped. Two calls can still run after the revocation completes: a call that the service took in its pass before the Disconnect came, and a call that `remote` sends in the same pass in which the row ended, after its copy of the table (`serve_next` checks the copy of the start of the pass). Each one runs as the grant stood a moment before; the window does not grow with time. A call that waits for its turn at the next pass is not made: `serve_next` resets its stream with `Revoked`.
- The debug access of a client is recorded against the program and the row (`Started.debug_for_row`, `Debug_Store.report_for_row`): the clients of two principals are the one caller `remote`, so the end of a connection of one row ends the debuggings of that row only, and a client of one row cannot end or take the debugging of another.
- `Remote_Client` refuses a key that another principal allowed with `Exists`. So a caller learns that some other principal allowed that key, and not which one. The key is public, and one key for several principals is refused for a stronger reason: a call would not say for whom it acts.
- A lock ends the grants of the principal without a revocation: its rows stay, locked, and the unlock gives them a new serial, so a connection to a service made before the lock never serves again.
- The connections of `remote` to one service are one for each row: the root service keys a connection by the caller, the service, and the row.
- `remote` is trusted with the rows: a fault of `remote` could use each row whose grant holds. It cannot act for a principal with no row, and the root service checks each serial.
- The peer of a machine test has a fixed key, which protects nothing but the test; the peer of `modustool run` draws a key at each run from the generator of the host, so no key that the source fixes is ever allowed outside a test.

## State

Built: the proof of the key of the client in the QUIC library with its host tests; the client table, its host test, the command `Remote_Client` and the connections for a row in the root service; the lock and the unlock; the check of the handshake, the binding, the end with `Revoked` and the wake in `remote`; `remote_allow`, `remote_disallow` and `remote_clients` in the console; the key of the client of the peer and the machine test of an allowed key, a revoked key and an unknown key, for principal 0, then three grants of one key that each end while no client is connected, each with the line of the slot that it freed. The lock and the unlock are not in a machine test: principal 0 has no lock, and each new allow gives the row a new serial as an unlock does.

Left: a row that lasts across a restart (in the disk grant table of its principal); a machine test of a key of a named principal; a grant signed by the key of a principal for another machine (layer 5 of [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "9. Not built").
