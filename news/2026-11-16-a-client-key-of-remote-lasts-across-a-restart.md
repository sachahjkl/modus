title: A client key of remote lasts across a restart
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

A principal allows the key of a client of `remote` once. The key now lasts across a restart of the machine, in the disk grant table of that principal, beside the grants of its disk programs and under the same tag.

After the restart, the key holds again when the table is read: at the unlock of a named principal, or when principal 0 gets its machine key. A call of that client then acts for the principal, with no new `remote_allow`.

`remote_disallow` takes the key out of the table, and says when the disk did not take the revocation, so that the key can come back at the next start. `remote_clients()` now also gives the state of each key: `holds`, `locked` while the session is locked, or `contested` when another principal allowed the same key: such a key acts for neither principal until one of them revokes it.
