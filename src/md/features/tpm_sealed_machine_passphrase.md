# The machine passphrase and the TPM together

## Purpose

The record of a machine passphrase held the machine key under a key that Argon2id derives from the machine passphrase, and nothing else. A copy of the disk then allows tries of passphrases without limit, at the cost of one derivation each, and a changed system that knows the passphrase opens the key.

This design gives a machine with a TPM and a machine passphrase the form of the keys of a named principal ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)). The TPM seals a TPM secret to the measure of the system and to an authorization value that the machine passphrase gives. So a copy of the disk allows no try away from the TPM of the machine, the TPM counts each wrong machine passphrase, and a changed system opens nothing even with the right passphrase. A recovery key, shown one time when the passphrase is set, opens a copy of the machine key when the TPM refuses or when the passphrase is lost.

The guide is [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The machine passphrase with the TPM". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md): "Machine passphrase", "TPM secret", "Authorization value", "Recovery key".

## Constraints

- **The TPM and the passphrase together.** A seal by the TPM beside a seal under the passphrase, each enough alone, is refused ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "Refused forms"): an attacker with the disk tries passphrases against the second one.
- **A seal needs Secure Boot on** ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "Who may seal"). With Secure Boot off, a seal trusts a boot program that nothing verified.
- **A machine with a TPM and no passphrase keeps its form.** The machine key sealed by the TPM alone (`MACHINET`) needs no typing at a start. That form is not changed.
- **No new kernel operation, no new grant, no new command of the root ring.** `unlock` already holds the ring of the TPM service in each mode, and `Machine_Passphrase` already starts it.
- **No backward compatibility.** No record changes its form. A record under the machine passphrase alone stays in that form, as a file of a named principal does ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "Refused forms").

## The chosen form

### When the form is chosen

`machine_passphrase()` on a machine with no record starts `unlock` in the mode `MODE_SET_MACHINE_PASSPHRASE`, as before. The window asks for the passphrase two times. Then `unlock` chooses the form:

- With the TPM service and Secure Boot on: the third form of the record, `MACHINEP`, the machine key sealed by the TPM with the machine passphrase. The window then shows the recovery key until Enter.
- With no TPM service, or with Secure Boot off: the form `MACHINEK`, under the machine passphrase alone, with a line of the log that says why. It has no recovery key.

`machine_seal()` still makes the form `MACHINET`. One machine has one record, so the two commands still refuse each other.

### What the TPM seals

The TPM seals a TPM secret: 32 random bytes. The record keeps the machine key sealed with ChaCha20-Poly1305 under the seal key: keyed BLAKE2b of the TPM secret over the key of the passphrase and a text of its own. The key of the passphrase is Argon2id of the machine passphrase and the salt of the record.

The sealed object has an authorization value: keyed BLAKE2b of the key of the passphrase over a text of its own. Its policy is `TPM2_PolicyPCR` with PCR 7 and PCR 11, then `TPM2_PolicyPassword`. Its attribute `noDA` is clear: each wrong value is a failure that the TPM counts.

Each text differs from the texts of a named principal. So a value or a seal key of the machine is never a value or a seal key of a principal, also for the same passphrase.

The passphrase enters twice, for the reasons of a named principal: as the authorization value, so that the TPM checks and counts it; and in the seal key, so that a reader of the TPM secret on the bus still runs Argon2id for each guess.

### The record `MACHINEP`

The object `machine` of the store of `unlock` has three forms now, by its first 8 bytes: `MACHINEK` (the passphrase alone), `MACHINET` (the TPM alone), `MACHINEP` (the TPM with the passphrase). The form `MACHINEP` has the format 1. It holds, in this order:

- the magic, the format, the parameters of Argon2id, the salt;
- the PCRs of the policy;
- the four parts of the sealed object, in the form of the other records;
- the nonce and the machine key under the seal key;
- the nonce and the machine key under the key of the recovery key.

The additional data of the seal under the seal key is each byte before the PCRs. The additional data of the recovery seal stops before the salt, so a new passphrase, which has a new salt, keeps the copy under the recovery key.

The record has no key check. The machine key of `MACHINET` comes from the TPM with no seal of its own, so a key check proves it. Here each copy of the machine key opens only under ChaCha20-Poly1305 with its tag: a record whose sealed object comes from another record gives another TPM secret, and the seal does not open.

### The life of the record

**The setting.** `unlock` makes the machine key and the recovery key, seals the copy under the recovery key, has the TPM seal a new TPM secret with the authorization value, seals the machine key under the seal key, writes the record, and gives the root service the key of the tag of the table with the origin "new". Its window then shows the recovery key until Enter. A root service that does not take the key changes nothing of that: the record holds the copy under the recovery key.

**At each start.** `unlock` reads the record, tells the root service that the key is awaited, and asks for the machine passphrase, as for `MACHINEK`. Enter with nothing skips it. With no TPM service it asks for the recovery key at once.

**A lost passphrase.** The prompt of the machine passphrase has an item of its action bar, Ctrl+R "recovery key", that asks for the recovery key at once. An owner who lost the passphrase then types no wrong try: each one would count in the TPM, against a named principal too, and nothing in the system resets the count.

**A passphrase.** The passphrase gives the value; the TPM gives the secret; the two give the seal key, which opens the machine key. Then `unlock` gives the root service the key of the table with the origin "opened". A wrong passphrase: the TPM answers `TPM_RC_AUTH_FAIL`, counts it, and the window says so.

**A refusal of the TPM.** Another system, another state of Secure Boot, another machine, a lockout, a record that the TPM did not make, or no answer: the window asks for the recovery key. The right passphrase on another system is never checked: the TPM checks the policy first. Enter with nothing at the recovery key goes back to the machine passphrase while the TPM service runs, as for a named principal: after a lockout the owner can wait for the TPM. Enter with nothing at the passphrase then skips the machine key.

**The recovery.** The recovery key opens the copy, and `unlock` gives the key of the table at once. With the TPM service and Secure Boot on, the window then asks for a machine passphrase two times, and the TPM seals the key again to it and to the system that runs: a new salt, a new TPM secret, new parts. So the recovery also replaces a lost machine passphrase. Enter with nothing skips the new seal: the disk grants are there already, and the recovery key opens the key at the next start too. With Secure Boot off, or with no TPM service, nothing is sealed again. A new seal that fails, or a record that the store does not keep, ends on a screen of the window with its sentence until Enter: an owner who believed that the new passphrase opens the key would type it at the next start, and the TPM would count it. After the write of the new seal, `unlock` erases the versions of the record ([version_erase.md](version_erase.md)): the record of before holds a seal that the old passphrase opens.

### The count

The TPM has one count for all the objects whose `noDA` is clear. A wrong machine passphrase counts against a named principal too, and a lockout refuses the machine passphrase and the passphrase of the principal together. The recovery keys open the keys during a lockout: the storage key is exempt from the count.

The first request with an authorization value in a run has the TPM service set the lockout authorization value when the TPM has an empty one ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "The lockout authorization value"). A machine passphrase is such a request now. So a machine with a machine passphrase and no named principal also closes the lockout hierarchy at its first use of the passphrase.

The service sends `TPM2_Shutdown` after each use of the value that is not a counted failure, as for a named principal: each start with the machine passphrase would else count one failure.

## Refused forms

- **The form `MACHINET` with a passphrase field.** One magic for two forms that a start opens differently (no typing, or a typed passphrase) makes the form a field that the code must read in each path. Three magics keep one decode for each form, as `PRINCIPL` and `PRINCIPT` do.
- **A new format of `MACHINEK` that holds the TPM parts when a TPM exists.** A machine with no TPM then has a record whose format depends on the machine. A new form is a new magic.
- **A migration of a record `MACHINEK` to `MACHINEP`.** It needs the passphrase, so a window that asks at a start for something else than an unlock. The old record would also stay a version that the passphrase alone opens until its erase. No backward compatibility: a record keeps its form, and only a machine with no record gets the new form.
- **The machine key sealed by the TPM directly, with the authorization value.** A reader of the bus at one unseal gets the key with no guess. The TPM secret with the passphrase in the seal key costs that reader one Argon2id for each guess.
- **A key check in `MACHINEP`.** Both copies open under an authenticated seal, so a key check proves nothing more.
- **A new passphrase that must be typed after a recovery.** The disk grants come at the recovery; a window that cannot be left at a start makes the machine wait for nothing. Enter with nothing skips the new seal.
- **`MACHINEK` refused on a machine with a TPM and Secure Boot off.** The machine passphrase stays possible there, with its known strength: the log says why the TPM does not seal it.

## Subtle points

- **A wrong passphrase on another system is not counted, and not known as wrong.** The policy fails first, and the window asks for the recovery key.
- **The right passphrase on another system opens nothing.** That is the point of the form: a changed system needs the recovery key, as for `MACHINET`.
- **The key reaches the root service before the new seal after a recovery.** The disk grants do not wait for a new passphrase. The opened key waits in `unlock` until the new seal, and is erased at its end, whatever its result, or at Enter with nothing.
- **The machine passphrase and the passphrase of a named principal share the count.** On a machine with both, wrong tries of either, to the limit of the TPM, lock both until its recovery time.
- **A skip after a wrong passphrase costs one more failure.** The TPM service sends no `TPM2_Shutdown` after a counted failure, so that a cut of the power does not lose it. When a wrong machine passphrase is followed by Enter with nothing, and no right passphrase comes in the run, the next start counts one more failure. At the machine prompt, a mistype then a skip is a normal action: on the test TPM, with a limit of three, a mistype, a skip and one more mistype at the next start lock the TPM. The rule of the shutdown stays: the count of a guess must survive a cut of the power.
- **No trial open before the erase of the versions.** After the new seal, the new record is not opened again before the versions go, as the change of a file under a passphrase alone does. The new record keeps the copy under the recovery key byte for byte, and that copy opened in the same run: a fault of the new seal costs one recovery, not the key. A trial unseal would also be one more use that the TPM counts.
- **A new machine passphrase does not revoke the old one.** The old sealed object stays valid on this system. The erase of the versions of the record removes the record of before from what the storage service reads; a copy of the disk made before still opens with the old passphrase on this TPM and system, or with the recovery key anywhere.

## Built and left

Built: the form `MACHINEP` with host tests (its offsets, its two additional data, its hostile forms, its texts); the choice of the form at `machine_passphrase()`; the unseal with the passphrase at each start; the counted wrong passphrase; the lockout and the refusal of the TPM that ask for the recovery key; Ctrl+R for the recovery key with no try; Enter with nothing at the recovery key back to the passphrase; the recovery and the new seal to a new passphrase, with the erase of the versions of the record, and the screen of a failed new seal. In `modustool test principals`, four machines with Secure Boot on, on a disk of their own and a new state of the software TPM: the setting with the recovery key read off the screen; a wrong passphrase counted and the right one; on another system, the right passphrase refused, the recovery key that opens the key, and a new seal to a new passphrase; on that system again, Ctrl+R and Enter with nothing back to the passphrase, the passphrase before the new seal refused and counted, and the new one that opens the key. No machine reaches the lockout of the machine passphrase, opens the record with no TPM service, or fails a new seal: those paths of the machine passphrase have no machine test yet.

Left:

- **A change and a removal of the machine passphrase, and a change of the recovery key**, as for a named principal.
- **The recovery key of a named principal with no wrong try.** Its prompt has no Ctrl+R yet: a principal who lost the passphrase types wrong tries until the TPM refuses.
- **Machine tests of the lockout of the machine passphrase, of its record with no TPM service, and of a failed new seal.**
- **The state of the lockout hierarchy in the window**, as for the creation of a named principal.
- **A pin of the form of the record in the TPM** ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "The form of the record is not pinned").
