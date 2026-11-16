title: A named principal changes its passphrase and its recovery key
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

Before, a named principal got a new passphrase only after a recovery, when the TPM refused its keys. Its recovery key never changed.

Now a console of the session of the principal asks for a change. `passphrase_change()` opens the window of `unlock`, which asks for the current passphrase first. The TPM checks it and counts a wrong one, as at an unlock. The window then asks for the new passphrase two times, and the TPM seals the keys again. `recovery_key_change()` asks for the current passphrase too, then shows a new recovery key one time; the file is written after Enter, when the key is written down. The window ends on the result, and the line of the console gives the same result. The console of the machine cannot ask: a change needs the session of the principal.

The keys themselves do not change: they are the principal. The store keeps the file from before the change as a version on the same disk, and that version still opens with the old passphrase and the old recovery key. So today a change protects the keys only against a party who knows the old secret and never gets this disk. The erase of the old versions is planned.

In the test, after a change the old passphrase is refused and counted, and the new one opens the session. On another system, the recovery key from before is refused, and the new one opens the keys.
