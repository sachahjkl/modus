# The keys of a named principal sealed by the TPM, and their recovery key

## Purpose

The keys of a named principal were sealed under a key that Argon2id derives from its passphrase, and nothing else. A copy of the disk then allows tries of passphrases without limit, at the cost of one derivation each. A principal who loses the passphrase loses the principal: no administrator can reset it (property 21).

This design seals the keys by the TPM, to the measure of the system and to the passphrase together. A copy of the disk then allows no try away from the TPM of the machine. The TPM counts each wrong passphrase, and after too many it limits the rate of the tries; this holds only while the lockout hierarchy of the TPM has an authorization value that the attacker does not know, and modus does not set one yet (see "The count holds only with a lockout authorization value"). A recovery key, shown one time at the creation, opens a copy of the keys when the TPM refuses or when the passphrase is lost.

The guide is [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The keys sealed by the TPM". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md): "Authorization value", "TPM secret", "Recovery key". The design of the seal itself (the TPM service, the proof of the creation, who may seal) is [tpm_sealed_machine_key.md](tpm_sealed_machine_key.md); this file states only what differs.

## Constraints

- **The TPM and the passphrase together.** A seal by the TPM beside a seal under the passphrase, each enough alone, is refused for the machine key ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "Refused forms"): an attacker with the disk tries passphrases against the second one. The same holds here.
- **The tries must be counted where the attacker cannot copy them.** Only the TPM can count: a count on the disk is reset by a copy of the disk.
- **The count of the TPM is set by its lockout hierarchy.** `TPM2_DictionaryAttackParameters` and `TPM2_DictionaryAttackLockReset` need only the lockout authorization value, not the PCRs. A new or cleared TPM has an empty one, and modus sets none yet.
- **The system has no orderly stop.** A machine stops at once; no program sends `TPM2_Shutdown`. A TPM counts one failure at each start that follows a use of an object that it protects, with no `TPM2_Shutdown` between them.
- **No new kernel operation, no new grant.** `unlock` already holds the ring of the TPM service.
- **The tests run on one software TPM (libtpms)**: three tries, then a lockout of 1000 seconds of the time of the TPM, which runs only while a machine runs.

## The chosen form

### What the TPM seals

The TPM seals a TPM secret: 32 random bytes. The file keeps the two secret keys sealed with ChaCha20-Poly1305 under the seal key: keyed BLAKE2b of the TPM secret over the key of the passphrase. The key of the passphrase is Argon2id of the passphrase and the salt of the file, as before.

The sealed object has an authorization value: keyed BLAKE2b of the key of the passphrase over a text of its own. Its policy is `TPM2_PolicyPCR` with PCR 7 and PCR 11, then `TPM2_PolicyPassword`. Its attribute `noDA` is clear: each wrong value is a failure that the TPM counts.

So the keys need three things: the TPM of this machine, the measure of this system, and the passphrase. Why the passphrase enters twice:

- **As the authorization value**, so that the TPM checks it and counts each wrong one.
- **In the seal key**, so that a reader of the TPM secret still runs Argon2id for each guess. The secret crosses the bus of the TPM in clear at each seal and unseal (no encrypted session is built), and a TPM can leak.

### Why `TPM2_PolicyPassword` and not `TPM2_PolicyAuthValue`

`TPM2_PolicyAuthValue` sends an HMAC keyed with the value, and the TPM service would compute and check HMACs. `TPM2_PolicyPassword` sends the value in clear. Both extend the policy with the same code, so the object is the same. A reader of the bus gains nothing more from the value in clear: the session has no salt and no bind, so an HMAC with the known nonces is the same test of a guess. Each guess still costs one Argon2id. The encrypted session, when it is built, covers both.

### The order of the checks of the TPM

The TPM checks the lockout, then the policy (the PCRs), then the value. So:

- On another system, the TPM answers `TPM_RC_POLICY_FAIL` and counts nothing: the passphrase is not checked there. A changed system asks for the recovery key, whatever the passphrase typed.
- On this system, a wrong value answers `TPM_RC_AUTH_FAIL` and counts one failure. The TPM answers `TPM_RC_BAD_AUTH` for a failure that it does not count; the service never sees it, as it checks that `noDA` is clear before the unseal.
- After too many failures, the TPM answers `TPM_RC_LOCKOUT` on each system, even before it checks the PCRs. The window then asks for the recovery key, or the principal waits.

### The count holds only with a lockout authorization value

The count limits a rate, not a number. After the lockout, the TPM forgives one failure at each recovery time. On the test TPM (libtpms, with no setup) that is three tries, then one try for each 1000 seconds of the time of the TPM: about 86 tries a day while the machine runs. A hardware TPM has the limits that its owner or its firmware set.

The count is worth only as much as the lockout authorization value. With an empty one, an attacker with the machine starts another system (Secure Boot off, or any signed loader), sends `TPM2_DictionaryAttackParameters` with a recovery time of 0, or a large count of tries, or `TPM2_DictionaryAttackLockReset`, then starts this system again. The PCRs match the seal, and the attacker types guesses in the window of `unlock` with no limit of the TPM: each guess then costs one derivation of Argon2id, as for the form `PRINCIPL`. So the form `PRINCIPT` is never weaker than `PRINCIPL`, and it limits the rate of the tries only on a TPM whose lockout authorization value the attacker does not know. modus sets none today.

The later form: the TPM service sets a random lockout authorization value when it finds an empty one, and keeps no copy, or keeps it sealed; it reads the count limits of the TPM and writes them on the log. A `TPM2_Clear` of the platform then destroys the seal only, and the recovery key covers that case. It is a roadmap entry.

### `TPM2_Shutdown` after each use of the passphrase

The TPM marks in its memory that an object with `noDA` clear was used. At the next start it counts one failure, unless `TPM2_Shutdown` came first. The system never sends it at a stop, so each start after an unlock would count one failure; the third start would lock the TPM.

So the TPM service sends `TPM2_Shutdown(CLEAR)` after each unseal with an authorization value that the TPM answered, before it gives the completion, except after a counted failure (`TPM_RC_AUTH_FAIL`). It says only that no try is in progress. An attacker who cuts the power during a try still gets one failure counted at the next start, as the TPM marked the use before the check.

**No shutdown after a counted failure.** The reference code writes a failure to its non-volatile memory before it answers, when that memory is available; a hardware TPM can defer or rate-limit that write, and keep the failure in its RAM. A shutdown then makes the state orderly, and a cut of the power loses the failure: "guess, then cut the power" would count nothing. With no shutdown, the mark of the use stays, and the next start counts one failure at least. The cost: a principal who mistyped and then stops the machine pays one more failure at the next start; a right passphrase later in the same run sends the shutdown and clears it. After every other answer, a policy failure included, the shutdown is sent: the TPM marks the use before it checks the policy. The TPM goes on to take commands after `TPM2_Shutdown`; a later command that changes state makes the state not orderly again, which counts nothing when no object of this kind was used.

A TPM that follows the reference code answers `TPM_RC_RETRY` at the first use of such an object after a start. The service sends the unseal again, three times at most. libtpms does not ask.

### The file

`unlock` keeps one file of a named principal, the object `principal`, in one of two forms by its first 8 bytes: `PRINCIPL` (under the passphrase alone) or `PRINCIPT` (sealed by the TPM). The form `PRINCIPT` keeps the first 124 bytes of `PRINCIPL` (the name, the public keys, the parameters of Argon2id, the salt), then the PCRs, the four parts of the sealed object in the form of the record of the machine key, the keys under the seal key, and the keys under the key of the recovery key.

The additional data of the seal under the seal key is each byte before the PCRs. The additional data of the recovery seal stops before the salt, so a new passphrase, which has a new salt, keeps the copy under the recovery key.

The opened keys must give the public keys of the file: that check takes the place of the key check of the machine key.

### The life of the file

**The creation.** With the TPM service and Secure Boot on, `principal_create("alice")` gives the form `PRINCIPT`. The passphrase is typed two times. `unlock` makes the keys, the recovery key and the TPM secret, seals the copy under the recovery key, has the TPM seal the secret with the value, seals the keys, writes the file, gives the record to the root service, and starts the session. Its window then shows the recovery key until Enter. With no TPM service, or with Secure Boot off, the form is `PRINCIPL`, with a line of the log that says why.

**The unlock.** The passphrase gives the value; the TPM gives the secret; the two give the seal key. A wrong passphrase: the window says that the TPM counts it.

**A refusal of the TPM.** Another system, another machine, a lockout, a record that the TPM did not make, or no TPM service: the window asks for the recovery key. Enter with nothing goes back to the passphrase while the TPM service runs.

**The recovery.** The recovery key opens the copy. With the TPM service and Secure Boot on, the window asks for a passphrase two times, and the TPM seals the keys again to it and to the system that runs: the file gets a new salt, a new TPM secret and new parts. So the recovery is also the change of a lost passphrase. With Secure Boot off, nothing is sealed again, for the reason of the machine key. The session starts in each case.

### The machine passphrase

This work gives the TPM and the passphrase together to a named principal. The machine passphrase stays under Argon2id alone, and its record keeps its form: a machine key sealed by the TPM needs no typing, and the record of a machine passphrase is for a machine on which a passphrase is typed at each start. The machine passphrase with the TPM is the same layer on the other record; it stays a roadmap entry.

## Refused forms

- **The keys sealed by the TPM alone, with no passphrase in the seal key.** A reader of the bus at one unseal gets the secret, and then the keys, with no guess.
- **The authorization value as the passphrase itself, or as a fast hash of it.** The value crosses the bus in clear: a reader would test guesses at the speed of a hash.
- **A count of the tries in the file, or in the store.** A copy of the disk resets it.
- **A lockout in `unlock`, with a delay after each wrong try.** A restart of the program, or of the machine, resets it.
- **`TPM2_DictionaryAttackLockReset` from the service.** A program of this system that can ask for it makes the count worthless. No command of the service resets it. This does not stop another system while the lockout authorization value is empty (see "The count holds only with a lockout authorization value").
- **`TPM2_Shutdown` at the stop of the machine only.** The machine has no orderly stop, and a stop by the power is a stop too.
- **No `TPM2_Shutdown`.** Three starts after three unlocks would lock the TPM, with no wrong passphrase.
- **The recovery key under Argon2id, or chosen by the principal.** As for the machine key: 160 random bits need no slow derivation.
- **A recovery that keeps the old passphrase.** The passphrase that was typed before a refusal of the policy was never checked; and a lost passphrase is the case that the recovery is for.
- **A recovery copy for the form `PRINCIPL`, now.** It is the same work on the other form; it is a roadmap entry.

## Subtle points

- **A wrong passphrase on another system is not counted, and not known as wrong.** The policy fails first. The window then asks for the recovery key: a principal who mistyped on an updated system needs the recovery key anyway.
- **The lockout comes before the policy.** A locked TPM refuses the right passphrase on this system too; the recovery key opens the keys, and the new seal works during the lockout: the storage key is exempt from the count.
- **The keys after a recovery wait in `unlock`** until the new passphrase is typed two times. They are erased at the end of the seal, whatever its result, and the window then ends: it cannot ask again for a passphrase that it has no keys to seal.
- **A new passphrase does not revoke the old one.** The old sealed object stays valid on this system: its parent is the storage key that the TPM derives again at each use, and its policy still holds. A writer of the disk who kept the old file puts it back, and the old passphrase opens the keys again. This matters when the old passphrase leaked, not when it was lost. Nothing on the disk or in the TPM pins the current file; a pin is the roadmap entry of the pinned form.
- **The recovery key never changes.** It opens the keys and sets a new passphrase alone, with no TPM, on any copy of the disk, old or new: a new seal keeps the same copy under it. Who holds the recovery key holds the principal until a new recovery key exists, which is not built.
- **The creation writes the file before the record goes to the root service.** The recovery key shows even when the root service does not take the record: the file holds the copy under it.
- **The test of the lockout depends on libtpms**: three tries, and no other failure counted. That is why the service sends `TPM2_Shutdown`: without it, each start of a machine of the test would count one more failure. Each machine of the test that types a wrong passphrase types the right one, or reaches the lockout, after it in the same run, so no start counts a failure of a stop.

## Built and left

Built: the authorization value of a sealed object in the TPM service, with `TPM2_PolicyPassword`, `noDA` clear, the check of the attributes, the codes of a counted failure and of the lockout, the retry, and `TPM2_Shutdown` after each use that is not a counted failure; the form `PRINCIPT` with host tests; the creation, the unlock, the recovery and the new passphrase in `unlock`; four machines of `modustool test principals`: the creation with the recovery key read off the screen, a counted wrong passphrase and the unlock, another system with the recovery and a new passphrase, and the lockout after three counted failures.

Left:

- **A lockout authorization value that the service sets**, and the count limits of the TPM on the log (see "The count holds only with a lockout authorization value").
- **The file of a named principal pinned in the TPM**, so a kept old file and its old passphrase are refused.
- **The machine passphrase and the TPM together** (see "The machine passphrase").
- **A recovery key for a named principal on a machine with no TPM.** The form `PRINCIPL` has no copy under a recovery key.
- **A change of the passphrase while the TPM still opens the keys**, and a new recovery key.
- **An encrypted session with the TPM** ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md)): the TPM secret and the value cross the bus encrypted.
