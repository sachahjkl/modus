title: The TPM service sets a lockout value that nobody keeps
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The TPM counts the wrong passphrases of a named principal, but a TPM with an empty lockout authorization value lets any system on the machine reset that count. With such a TPM, an attacker with the machine starts another system, resets the count, and guesses passphrases with no limit of the TPM.

Now the TPM service of modus reads the bit `lockoutAuthSet` before the first use of a passphrase in a run. A start that uses no passphrase with the TPM changes nothing. When the bit is clear, the service sets 32 random bytes as the lockout value, then erases them. No program, file or store keeps the value, so no system can reset the count or change its limits, this one included. The service also writes the count limits of the TPM on the log: on the test machines, a lockout after 3 wrong passphrases, then one forgiven each 1000 seconds.

In the test, a new TPM takes `TPM2_DictionaryAttackLockReset` with the empty value from the host. The TPM of the test machines refuses it with `TPM_RC_AUTH_FAIL`. A principal who reaches the lockout waits, or types the recovery key.
