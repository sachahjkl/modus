type: Added

**Principal self-removal, reserved session budgets, and per-principal client keys.** `principal_remove()` durably destroys a named principal's key material (cryptographic erasure) and transitions its format-4 TPM pin to free while retiring the slot until reboot, each unlocked session reserves a child kernel budget and enforced storage block quota, and `remote` client keys are keyed by `(principal_identifier, public_key)` without cross-principal contests.
