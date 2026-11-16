title: The TPM counts the wrong machine passphrases
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The machine passphrase of modus guards the machine key, which signs the disk grants of the machine. Its record held the key under Argon2id of the passphrase alone. With a copy of the disk, an attacker could try passphrases with no limit, and a changed system could open the key with the right passphrase.

Now, on a machine with a TPM and Secure Boot on, `machine_passphrase()` gives the record the form of the keys of a named principal. The TPM seals a secret to the measure of the system and to a value that the passphrase gives. The TPM counts each wrong machine passphrase, and on another system it refuses even the right one. The window of `unlock` shows a recovery key one time. That key opens the machine key when the TPM refuses, and the window then asks for a new machine passphrase.

In the test, a wrong machine passphrase is refused and counted on the system of the seal, and the right one opens the key. On another system, the right passphrase opens nothing, and the recovery key opens the key.
