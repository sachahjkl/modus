title: The TPM seals the keys of a named principal and counts its wrong passphrases
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

On a machine with a TPM and Secure Boot on, `principal_create("alice")` now has the TPM seal the keys of alice to the measure of the system and to her passphrase together. Another system, another machine, or a copy of the disk opens nothing. The TPM counts each wrong passphrase. After three on the test machines, it refuses each try for a time, the right passphrase too. This count holds only while the lockout hierarchy of the TPM has an authorization value that an attacker does not know, and modus does not set one yet.

The window of `unlock` shows a recovery key one time, at the creation. When the TPM refuses, or when alice loses her passphrase, the recovery key opens her keys. The window then asks for a passphrase, and the TPM seals the keys again to it and to the system that runs.
