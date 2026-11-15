title: The TPM releases the machine key to the measured system only
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

A machine with no machine passphrase and with Secure Boot on can now keep its disk grants across a restart. `machine_seal()` in the console makes a machine key, and the new TPM service seals it to PCR 7 and PCR 11: the state of Secure Boot and the measure of the system description. At each start of the same system, the TPM gives the key back and nothing is typed. An older or a changed system, or a copy of the disk on another machine, gets nothing from the TPM. Before each unseal the TPM proves that it made the sealed object under those PCR values, so a record that another system wrote is refused.

The window of `unlock` shows a recovery key one time, as 32 characters in groups of 4. When the TPM refuses, for example after an update of the system, that key opens the machine key, and `unlock` seals it again to the system that runs. The TPM service is a program: it builds each command of the TPM itself, and its one client cannot send it a raw command.
