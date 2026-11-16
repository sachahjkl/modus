title: A named principal changes its passphrase and its recovery key
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

Before, a named principal got a new passphrase only after a recovery, when the TPM refused its keys. Its recovery key never changed.

Now a console of the session asks for a change. `passphrase_change()` opens the window of `unlock`, which asks for the current passphrase first; the TPM counts a wrong one. The TPM then seals the keys to the new passphrase. `recovery_key_change()` shows a new recovery key one time, and writes the file after Enter.

The keys themselves do not change: they are the principal. The store keeps the file from before the change as a version on the same disk, and that version still opens with the old passphrase and the old recovery key. So today a change protects the keys only against a party who knows the old secret and never gets this disk. The erase of the old versions is planned.

In the test, after a change the old passphrase is refused and counted, and the new one opens the session. On another system, the recovery key from before is refused, and the new one opens the keys.
