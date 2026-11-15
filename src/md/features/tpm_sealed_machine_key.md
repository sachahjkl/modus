# The machine key sealed by the TPM, and the recovery key

## Purpose

A machine with no machine passphrase keeps the disk grant table of principal 0 only until it stops: no key signs the table. This design gives such a machine a machine key that the TPM releases at each start with no typing, but only to the system whose measure the TPM holds. An older system, a changed system, or a copy of the disk on another machine opens nothing. A recovery key, shown one time, opens the machine key when the TPM refuses: after an update of the system, on another machine, or with no TPM.

The guide is [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The machine key sealed by the TPM". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md): "TPM service", "Sealed by the TPM", "Recovery key".

## Constraints

- **The TPM is a device, and a device is a program** (property 17). After the start, a device service owns the TPM. The boot program talks to the TPM through the firmware only, and the firmware services end before the kernel starts.
- **No new kernel operation.** The TPM of the machine has the CRB interface at the fixed physical address `0xFED40000`. `Device_Create` of the kind `Memory` gives one page of its registers, mapped with no cache.
- **The measure is PCR 11** ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "6. The measure"). The firmware measures the state of Secure Boot into PCR 7.
- **No update path exists in the system.** A new system is a new boot volume that the tool writes. So the old system cannot know the measure of the next one before the update.
- **No administrator.** A lost key is lost data (property 21, "Cost"). So recovery comes with the first version of the seal.
- **No test machine has Secure Boot and a TPM.** The machines of the TPM use the firmware without Secure Boot; the machines of Secure Boot have no TPM device. The firmware with Secure Boot lost an answer of the software TPM at each start on the QEMU that waits through io_uring, most likely the same fault of QEMU that the machines of the TPM had; it has not run with a TPM since the fix ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "The machines of the TPM"). A seal needs Secure Boot. So the seal is proven on a test system: a boot image whose root service is built with the setting `SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST`, which also takes a boot program that only the boot program verified. That service writes a line at boot that names it a test system; only its two volumes hold it, and the tool fails each other machine that prints the line. A release publishes no volume, and the main volume holds the root service with no setting, so the rule holds on each real machine; a machine of the test on the main volume checks it.

## The chosen form

### The TPM service

The program `tpm` is the device service of the TPM. The root service starts it at boot, before `unlock`, only when the trust record says `Measured`: the TPM is there and PCR 11 holds the measure. It gives the program the page of the registers, a ring and a region of one page. The program has no other grant.

`unlock` is its one client. The root service gives the same ring and region to each run of `unlock` with the start grant `Tpm`. The ring has two commands:

| Command | The region before | The region after |
|---|---|---|
| `Seal` | 32 secret bytes | The public area and the private area of a sealed object |
| `Unseal` | The public area and the private area | The 32 secret bytes |

Each command can also carry an authorization value, for the keys of a named principal ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)). The machine key has none.

The service builds each TPM command itself. No client sends a raw command: a client that sends `TPM2_PCR_Extend` changes the measure, and one that sends `TPM2_Clear` destroys every key of the TPM.

### The seal

`Seal` runs these commands of TPM 2.0:

1. `TPM2_CreatePrimary` under the owner hierarchy, with the template of an ECC P-256 storage key. The template is fixed, so the TPM gives the same key at each start, and no key is kept in the TPM.
2. `TPM2_StartAuthSession` of the kind trial, then `TPM2_PolicyPCR` with PCR 7 and PCR 11 of the SHA-256 bank and no digest, then `TPM2_PolicyGetDigest`. The TPM computes the policy from the values of the PCRs now.
3. `TPM2_Create`: a keyed-hash object that holds the 32 bytes, with that policy as its policy, `userWithAuth` clear and `adminWithPolicy` set. Only a policy session that satisfies the policy unseals it, or changes it. Its creation data names PCR 7 and PCR 11: the TPM writes their digest at the creation, and gives a creation ticket.
4. `TPM2_FlushContext` of the session and of the storage key.

`Unseal` runs `TPM2_CreatePrimary`, `TPM2_Load` of the two areas, `TPM2_CertifyCreation`, a policy session with `TPM2_PolicyPCR`, `TPM2_Unseal`, and the flushes. A system with another description has another PCR 11: the TPM answers `TPM_RC_POLICY_FAIL`, and the service gives that response code.

### The proof of the creation

`TPM2_Create` takes any policy in its template, whatever the PCRs hold. The owner hierarchy has no authorization value, and the storage key comes from a fixed template. So another system on the same machine (a system that a vendor certificate of `db` starts, or any system with Secure Boot off) can make an object under the same storage key, with the policy of this system, that holds a key of its own choice. With write access to the disk, it then writes a record with that object and a disk grant table that its key signs. At the next start of this system, the PCRs match the policy, and the TPM gives that key.

So the record keeps the creation data and the creation ticket of the object, and `Unseal` proves the creation before it unseals:

1. **The ticket.** `TPM2_CertifyCreation` with the handle NULL as the signing key: the TPM checks that the ticket is its own HMAC, under a proof value that never leaves the TPM, over the creation hash and the name of the loaded object. The service computes the creation hash from the creation data of the record. A ticket that the TPM did not give for this object and this creation data answers `TPM_RC_TICKET`. The handle NULL signs nothing, so no signing key is needed.
2. **The creation data.** It must name PCR 7 and PCR 11 of SHA-256, with a digest.
3. **The public area.** Its attributes are exactly those of a sealed object (`fixedTPM`, `fixedParent`, `adminWithPolicy`, `noDA`, no `userWithAuth`), and its policy is the policy of `TPM2_PolicyPCR` over the digest of the creation data: SHA-256 of 32 zero bytes, the code of the command, the selection, and the digest.

The name of the object covers its public area, and the ticket covers the name and the creation data. So the policy of the object is the policy of the PCR values that the TPM saw when it made the object. The unseal then succeeds only while the PCRs hold those values. An object that another system made names the PCRs of that system in its creation data: its policy is not the policy of its creation data, and the service refuses it with `Not_Authentic`. `unlock` then asks for the recovery key; the recovery key of this machine does not open the copy that the other system wrote.

**Why PCR 7 too.** PCR 11 alone trusts the boot program: a replaced boot program can extend PCR 11 with the hash of a correct description, then run other code ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "Layer 2: the measure"). PCR 7 holds the state of Secure Boot and the certificates of `db`. With Secure Boot on, a boot program that the firmware did not verify does not start. With PCR 7 in the policy, a machine whose Secure Boot is turned off after the seal opens nothing.

### The record of the machine key

The record is the object `machine` of the store of `unlock`, as the record of the machine passphrase is. One object has one of two forms, by its first 8 bytes: `MACHINEK` (the machine passphrase) or `MACHINET` (sealed by the TPM). A machine has one machine key, so it has one record.

The form `MACHINET` holds:

- the PCRs of the policy;
- the public area and the private area of the sealed object, as the TPM gave them;
- its creation data and its creation ticket, the proof of the creation (format 2: format 1 had no proof);
- the machine key sealed with ChaCha20-Poly1305 under the key of the recovery key;
- the key check: keyed BLAKE2b of the machine key over a fixed text.

**The recovery key.** 20 random bytes (160 bits) from the generator of `unlock`, shown as 32 characters of base32 (RFC 4648) in 8 groups of 4. The key of its seal is keyed BLAKE2b of the 20 bytes over a fixed text. The recovery key has 160 bits, so no slow derivation is needed: a guess costs the attacker the same as a guess of the key itself.

**The key check.** After an unseal, `unlock` compares the key check of the key that it received with the check of the record. A record whose two areas come from another record, or a service that gives another key, gives a key that does not pass. The check reveals nothing of the key: keyed BLAKE2b is a pseudorandom function.

The additional data of the recovery seal is the magic and the format only. A new seal by the TPM changes the four parts of the sealed object and keeps the recovery seal: the recovery key is not kept, so the copy under it cannot be sealed again.

### The form of the record is not pinned

The first 8 bytes of the record choose its form, and no state outside the disk says which form a machine uses. With the proof of the creation, a replaced record gives no silent grant: a record sealed by the TPM that this system did not make is refused, and the window asks for a recovery key that does not open it; a record under a passphrase that the owner did not set asks for that passphrase; a removed record gives no grant. Each one is a denial that the owner sees at the next start, not a table of another key that the root service takes.

A pin would be a value that the TPM keeps, such as an index of its memory that says "this machine has a record sealed by the TPM". It is not built: the owner hierarchy has no authorization value, so another system on the machine can remove such an index. A pin needs an index whose removal and write need the policy of this system (`TPM2_PolicyPCR` on the index, `TPMA_NV_POLICY_DELETE`), or an authorization value of the owner hierarchy that the system keeps. It is a roadmap entry.

### Who may seal

A seal and a new seal after a recovery run only when the firmware verified the boot program (the trust record says `Firmware_And_Boot_Program`). With Secure Boot off, PCR 7 says "off", and a replaced boot program can extend PCR 11 with the hash of a correct description: a seal then trusts a boot program that nothing verified. The rule matters most after a recovery: an attacker who turns Secure Boot off makes the TPM refuse, as an update does, and a new seal after the recovery would bind the key to "Secure Boot off". The root service refuses `machine_seal()` then, and gives `unlock` the context value `VALUE_SEAL_ALLOWED`; `unlock` skips the new seal with a line of the log. An unseal stays allowed: it opens only a seal that was made with Secure Boot on. The one exception is a build of the test: the root service of `boot_seal_test.image` takes a boot program that only the boot program verified (see "Constraints").

### One client, and a client that learns a stop

The root service starts `unlock` only from its own procedure `unlock_start`, and one at a time: two runs would share the rings, and one would read the answers of the other. `unlock` holds the TPM service with the right Read: the stop of the service is an event of `unlock`, which ends a wait at once. The service ends each request at its own bound, below the bound of `unlock`, so it never writes a secret after its client stopped waiting.

### The life of the record

**The creation.** `machine_seal()` in the console asks the root service (`Machine_Seal`). The root service starts `unlock` in the mode `MODE_SEAL_MACHINE_KEY` only on a machine with no record and with the TPM service. `unlock` makes the machine key and the recovery key, asks the TPM service for the seal, seals the copy under the recovery key, writes the record, and gives the root service the key of the table with the origin "new". Then its window shows the recovery key until Enter.

**At each start.** `unlock` reads the record. With `MACHINET` it tells the root service that a key is awaited, and asks the TPM service to unseal. When the key passes its check, `unlock` gives the key of the table with the origin "opened". Nothing is typed.

**A refusal of the TPM.** The TPM refuses after an update of the system, on another machine, or after a change of Secure Boot. With no TPM service, the same path runs. The window of `unlock` asks for the recovery key; Enter with nothing skips it, as for the machine passphrase. A recovery key that opens the copy, and whose key passes the check, gives the key of the table with the origin "opened".

**The new seal after a recovery.** When the TPM service runs, `unlock` asks it for a new seal of the same machine key, to the PCRs of the system that runs now. It writes the record with the new areas and the same recovery seal. The next start of this system then needs no recovery key. The disk grant table keeps its tag: the machine key did not change.

**An update of the system.** The old system cannot seal the key to the next measure, because no program of the system knows the next description before the update. So the first start of a new system asks for the recovery key one time, and seals the key again.

### A machine with no TPM

The root service starts no TPM service when the trust record does not say `Measured`: no TPM, a TPM that refused the measure, or a PCR that the boot program did not read. `unlock` then has no ring of the TPM. A machine passphrase works as before. `machine_seal()` is refused with a sentence. A record `MACHINET` asks for its recovery key.

## Refused forms

- **A raw command from the client.** The client could extend PCR 11 or clear the TPM. The service builds each command, and a command has two forms only.
- **The TPM driver in `unlock`.** A program with a window and the passphrase would also hold a device. Property 17 gives the TPM to a device service, and a later client (a counter of the disk grant table, an attestation) reaches the same service.
- **The TPM service as a service with described exports.** A device service with a ring and a region is the form of the block service and of the frame service. The client needs no file of the service and no connection through the root service; the root service gives the ring at the start of `unlock`.
- **A signed policy (`TPM2_PolicyAuthorize`)** in place of exact PCR values. Property 17 names it as the standard form against the cost of an update. It needs a key of the publisher of the system that the TPM verifies: the TPM verifies RSA and ECDSA, not Ed25519. It also lets each older system that the key signed unseal the key, until a counter of the TPM refuses an older system. Exact values keep "an older system opens nothing" now; a signed policy with a counter is the later form.
- **A seal at each start with no command.** The recovery key would show at a start that nobody watches, and a key with no recovery is lost at the first update.
- **A seal by the TPM and a seal under the machine passphrase in one record, each enough alone.** An attacker with a copy of the disk tries passphrases against Argon2id, and the TPM adds nothing. The TPM and the passphrase together is the form of the keys of a named principal ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)): the passphrase gives the authorization value of the sealed object, and the TPM counts the wrong tries.
- **The recovery key through Argon2id.** 160 random bits need no slow derivation. A recovery key that a principal chooses would need one, and it is weaker.
- **The recovery key on the log, or kept in a store.** The log is read by programs and by the host. A key kept on the disk opens the copy for a reader of the disk.
- **The recovery key typed in the console.** The console keeps each line in its history and in its store.
- **The two areas in the additional data of the recovery seal.** A new seal by the TPM would then need the recovery key again.
- **A stop of the start when the TPM refuses.** The machine runs, and the disk grants of principal 0 stay absent until the recovery key is typed, as for a machine passphrase that is not typed.
- **A new machine key when the TPM refuses.** The table that the old key signed would be lost, and an older system that still opens the old record would lose its key.
- **Parameter encryption of the sessions, now.** The machine key crosses the interface of the TPM in clear at the seal and at the unseal. On a discrete TPM, a reader of its bus gets the key. Encryption needs a salted session with the storage key, AES-CFB on the parameters of `TPM2_Unseal`, and a check of the HMAC of the answer; a software TPM on the host sees the key anyway. It is a roadmap entry, to build before a machine with a hardware TPM.
- **A seal with no proof of its creation.** Another system on the machine can make an object with the policy of this system (see "The proof of the creation").
- **The check of the current PCR values by a read of the PCRs.** The unseal already needs the PCRs to hold the values of the policy, and the policy is checked against the creation data: a read adds a command and proves nothing more.
- **A pin of the form in the memory of the TPM with no policy.** Another system removes it with the empty authorization of the owner.
- **A seal with Secure Boot off.** It trusts a boot program that nothing verified.

## Subtle points

- **The policy uses the values of now.** `TPM2_PolicyPCR` with no digest takes the values of the PCRs at the command. So a seal on a system that runs binds the key to that system, and a seal of a later system needs that system to run.
- **The data buffer of the interface holds the key.** After a command, the service writes zeros over the buffer of the interface and over its own copies, and the client writes zeros over the region after it reads the key.
- **A ring that a stopped client left.** `unlock` stops after each run, and the next run gets the same ring. A completion of the earlier run can wait there. The client reads and drops each completion before its first command, and each command has a new tag.
- **A session that fails stays in the TPM.** A failed command does not end its session. The service flushes the session and the storage key after each command, in the order of the handles that it holds.
- **The owner hierarchy has no authorization value on the test machines.** A machine whose owner set one refuses `TPM2_CreatePrimary` with `TPM_RC_BAD_AUTH`: the service gives that code, and the seal is refused.
- **The empty HMAC.** A policy session with no `TPM2_PolicyAuthValue`, no salt and no bind has an empty session key. The TPM then takes an empty HMAC, and gives one.
- **The key check before the key leaves `unlock`.** A key that fails the check is erased, and the root service receives nothing: a wrong key would make the root service refuse the table and keep it, with no sign of the cause.

## Built and left

Built: the TPM service with the CRB interface, its ring and its two commands; the encoding of the TPM commands and of their answers, with host tests; the proof of the creation (the ticket, the creation data, the public area), with host tests of a forged object; the record `MACHINET` of format 2, the recovery key and the key check, with host tests; `machine_seal()` with Secure Boot on only; the unseal at each start; the recovery key in the window of `unlock`; the new seal after a recovery, with Secure Boot on only; one `unlock` at a time; the test in `modustool test principals`, part of each full check, on six machines with one software TPM and no Secure Boot, five of them on the test system that seals with no Secure Boot and one on the main volume, where the seal is refused, in which the tool reads the recovery key off the screen, and one machine finds a record whose creation ticket has one byte changed and the TPM refuses it. No machine test makes a forged object with the policy of this system: it needs a second system that makes objects on the same TPM; the host tests refuse one.

Left:

- **A pin of the form of the record in the TPM** (see "The form of the record is not pinned").
- **An encrypted session with the TPM.** The key crosses the bus of a hardware TPM encrypted.
- **The machine passphrase and the TPM together.** The machine passphrase as the authorization value of the sealed object, so the TPM counts the wrong tries. The keys of a named principal have this form ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)); the TPM service already seals with an authorization value.
- **A seal to the measure of the next system.** A signed policy of the publisher of the system, with a counter of the TPM that refuses an older system.
- **A change of the recovery key**, and a new one when the old one is lost while the TPM still opens the key.
- **The seal tested with Secure Boot on.** A machine of Secure Boot with a TPM tests the seal on the real rule, with no test volume.
