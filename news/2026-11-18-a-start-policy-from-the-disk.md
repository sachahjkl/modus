title: A start policy from the disk, measured into PCR 12
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The machine can now start with a start policy that a third party publishes, in place of the one of the boot image. On a machine whose machine key the TPM seals with no passphrase, `start_policy_choose("tiny", hash)` in the console of principal 0 chooses a module of the store `module_files` by its hash. At the next start, the root service reads the choice before any start policy runs, checks the hash of the bytes, and starts the module with the start grant `Start_Policy` only: it can start and stop processes of the machine, and nothing more.

Each start policy is now measured into PCR 12 before it runs, the default one and the rescue too, and the log gives the value of PCR 12. A remote party can then see which start policy ran. The seal of the machine key still reads PCR 7 and PCR 11 only, so a new choice opens the machine key as before.

A chosen module that is absent, has another hash, cannot be measured or fails gives way to the rescue start policy. `start_policy_default()` ends the choice.
