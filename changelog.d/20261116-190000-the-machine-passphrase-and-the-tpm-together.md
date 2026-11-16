type: Added

**The machine passphrase and the TPM together.** On a machine with a TPM and Secure Boot on, `machine_passphrase()` has the TPM seal the machine key with the passphrase, in the record `MACHINEP`: the TPM counts each wrong machine passphrase, another system opens nothing even with the right one, and a recovery key, shown one time, opens the key and then seals it again to a new machine passphrase. A machine with no TPM, or with Secure Boot off, keeps the record under the passphrase alone, and a machine key sealed by the TPM with no passphrase keeps its form.
