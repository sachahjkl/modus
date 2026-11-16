title: A call from another machine acts for the principal that allowed its client
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The program `remote` takes calls from another machine over QUIC. Each client now proves a key of its own in the handshake, and `remote` takes only a key that a principal allowed.

A principal allows a key in a console that acts for it: `remote_allow("<64 hexadecimal digits>")`. Each call of that client then acts for that principal, and sees what a console of that principal sees. A key that no principal allowed is refused in its handshake, before any call, with one line on the log.

`remote_disallow` ends the grant. The open connection of the client ends at once with the code Revoked, and the next handshake of the key is refused. A lock of the session of the principal ends the grant in the same way, until the unlock. `remote_clients()` lists the keys that a principal allowed.

`modustool run` prints the key of the client of its peer for each run, with the line to type in the console.
