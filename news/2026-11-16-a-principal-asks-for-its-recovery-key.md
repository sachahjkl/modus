title: A principal asks for its recovery key with no wrong try
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The TPM counts each wrong passphrase of a named principal, and of the machine, in one count. After three wrong tries on the test TPM, it refuses each try for a time. A principal who lost the passphrase had to type wrong tries until the TPM refused, and each one also counted against the machine passphrase.

Now the window of `unlock` has the item Ctrl+R "recovery key" at the passphrase of a named principal, as it has at the machine passphrase. Ctrl+R asks for the recovery key at once, and nothing reaches the TPM. Enter with nothing goes back to the passphrase. The recovery key opens the keys. With Secure Boot on, the window then asks for a new passphrase, and the TPM seals the keys to it.
