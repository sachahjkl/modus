# The machine key sealed by the TPM, and the recovery key

## Purpose

A machine with no machine passphrase keeps the disk grant table of principal 0 only until it stops: no key signs the table. This design gives such a machine a machine key that the TPM releases at each start with no typing, but only to the system whose measure the TPM holds. An older system, a changed system, or a copy of the disk on another machine opens nothing. A recovery key, shown one time, opens the machine key when the TPM refuses: after an update of the system, on another machine, or with no TPM.

The guide is [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "The machine key sealed by the TPM". The terms are in [`docs/glossary/trusted_boot.md`](../../../docs/glossary/trusted_boot.md): "TPM service", "Sealed by the TPM", "Recovery key".

## Constraints

- **The TPM is a device, and a device is a process** (property 17). After the start, a device service owns the TPM. The boot program talks to the TPM through the firmware only, and the firmware services end before the kernel starts.
- **No new kernel operation.** The TPM of the machine has the CRB interface at the fixed physical address `0xFED40000`. `Device_Create` of the kind `Memory` gives one page of its registers, mapped with no cache.
- **The measure is PCR 11** ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "6. The measure"). The firmware measures the state of Secure Boot into PCR 7.
- **No update path exists in the system.** A new system is a new boot volume that the tool writes. So the old system cannot know the measure of the next one before the update.
- **No administrator.** A lost key is lost data (property 21, "Cost"). So recovery comes with the first version of the seal.
- **The seal is tested on the real rule.** A seal needs Secure Boot, and the root service has one build: no test setting lets it seal without Secure Boot. So the machines of the test that seal run the firmware with Secure Boot and a TPM, on signed volumes ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "The machines of the TPM"). In the tool, the TPM device is an option of the machine, apart from the firmware.

## The chosen form

### The TPM service

The process `tpm` is the device service of the TPM. The root service starts it at boot, before `unlock`, only when the trust record says `Measured`: the TPM is there and PCR 11 holds the measure. It gives the process the page of the registers, a ring and a region of one page, and the measure ring below. The process has no other grant.

`unlock` is its client for the seal and the unseal; the root service is a second client, on the measure ring below, on which the service extends PCR 12. The root service gives the same ring and region to each run of `unlock` with the start grant `Tpm`. The ring has two commands:

| Command | The region before | The region after |
|---|---|---|
| `Seal` | 32 secret bytes | The public area and the private area of a sealed object |
| `Unseal` | The public area and the private area | The 32 secret bytes |

Each command can also carry an authorization value, for the keys of a named principal ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)) and for the machine key under a machine passphrase ([tpm_sealed_machine_passphrase.md](tpm_sealed_machine_passphrase.md)). The machine key of this form has none.

The root service has a second ring of its own, the measure ring, with one command, `Measure_Start_Policy`: the service extends PCR 12 with the digest of each start policy, twice at most in one start ([start_policy.md](start_policy.md), "The measure of the start policy"). The ring of `unlock` refuses that command, and the measure ring refuses `Seal` and `Unseal`. The seal selects PCR 7 and PCR 11 only, so PCR 12 changes no unseal.

The service builds each TPM command itself. No client sends a raw command: a client that sends `TPM2_PCR_Extend` changes the measure, and one that sends `TPM2_Clear` destroys every key of the TPM.

At its start, before it serves the ring, the service reads the count limits of the TPM and writes them on the log. Before the first request with an authorization value, it sets a random lockout authorization value, which nobody keeps, when the TPM has an empty one. No client asks for it, and a boot that seals only the machine key leaves the lockout hierarchy as it found it. The design is in [tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "The lockout authorization value": the count of the wrong passphrases of a named principal needs it.

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

The record is the object `machine` of the store of `unlock`, as the record of the machine passphrase is. One object has one of three forms, by its first 8 bytes: `MACHINEK` (the machine passphrase alone), `MACHINET` (sealed by the TPM) or `MACHINEP` (sealed by the TPM with the machine passphrase, [tpm_sealed_machine_passphrase.md](tpm_sealed_machine_passphrase.md)). A machine has one machine key, so it has one record.

The form `MACHINET` holds:

- the PCRs of the policy;
- the public area and the private area of the sealed object, as the TPM gave them;
- its creation data and its creation ticket, the proof of the creation (format 2: format 1 had no proof);
- the machine key sealed with ChaCha20-Poly1305 under the key of the recovery key;
- the key check: keyed BLAKE2b of the machine key over a fixed text.

**The recovery key.** 20 random bytes (160 bits) from the generator of `unlock`, shown as 32 characters of base32 (RFC 4648) in 8 groups of 4. The key of its seal is keyed BLAKE2b of the 20 bytes over a fixed text. The recovery key has 160 bits, so no slow derivation is needed: a guess costs the attacker the same as a guess of the key itself.

**The key check.** After an unseal, `unlock` compares the key check of the key that it received with the check of the record. A record whose two areas come from another record, or a service that gives another key, gives a key that does not pass. The check reveals nothing of the key: keyed BLAKE2b is a pseudorandom function.

The additional data of the recovery seal is the magic and the format only. A new seal by the TPM changes the four parts of the sealed object and keeps the recovery seal: the recovery key is not kept, so the copy under it cannot be sealed again.

### The pin of the record

The first 8 bytes of the record choose its form, and the disk alone cannot say which record is current. On a machine with the TPM service, the TPM pins the record: an index of the TPM holds its form and its digest. `unlock` refuses a record that the pin does not name, so a writer of the disk cannot swap the record for one under a passphrase of its own, remove it, or put back an older record.

**The index.** An ordinary index of the owner hierarchy at `0x01806E00` (`tpm2.MACHINE_KEY_PIN_INDEX`), after the TPM floors. Anyone reads it with the empty password (`TPMA_NV_AUTHREAD`). Only a policy session of `TPM2_PolicyPCR` of PCR 7 and PCR 11 with the values of its definition writes it (`TPMA_NV_POLICYWRITE`): this system, after its measure, with the same state of Secure Boot. The TPM service reads, defines and writes it with two commands of the TPM ring, `Pin_Read` and `Pin_Write`; `unlock` decides (`tpm_service.machine_record_pin_verdict`).

**The payload** (format 2, 116 bytes): the magic `MODUSMKP`, the format, the form (1 `MACHINET`, 2 `MACHINEP`, 3 `MACHINEK`), a reserved zero byte, an epoch of 64 bits, SHA-256 of the record, SHA-256 of the announced record (zeros when none is), and SHA-256 of a text of its own and the bytes before it. The checksum finds a damaged index; the policy of the index decides who writes it. Format 1 held the form and the epoch only: an older record of the same form passed it.

**The rules** (`modus:contract/tpm_attestation`):

- a machine with no pin takes any form; after that the form stays, as a record keeps its form for its life ([tpm_sealed_machine_passphrase.md](tpm_sealed_machine_passphrase.md), "Refused forms"); a form with the TPM that becomes `MACHINEK` is a downgrade;
- the epoch rises at each write of the pin, so the service never writes an older pin back (`tpm_service.pin_write_refusal`);
- the record of the disk must have the form of the pin and its digest, or the announced digest. A pin with no record on the disk refuses the absence too.

**A refusal.** `unlock` writes "the record of the machine key is not the record that the TPM pins", with the rule that failed, and takes the record as unreadable: the disk grants of principal 0 stay absent, no new record is written over it, and no other record is tried in its place.

**The write of a record**, at a creation, a new seal after a recovery, or a new machine passphrase, has three steps (`machine_key_pin_announce`, `machine_key_pin_settle`):

1. The pin announces the new record: the same current digest, the digest of the new record as the announced one, the next epoch.
2. The store writes the record.
3. The pin names what the store kept, with nothing announced.

A stop between two steps leaves a record that the pin names, the old one or the announced one. The next start that finds either settles the pin on it at once, when a seal is allowed: from then on the other record is refused, so a writer of the disk cannot bring back the record of before the crash at a later start. A pin that refuses the new record, or a TPM that does not take the announce, writes nothing.

**No announce over an announce.** A pin that names two records, after a settle that failed, never announces a third: a stop before the write of the third would leave the announced record on the disk, refused. `unlock` settles the pin on the record of the store first, and refuses the write when the pin stays unsettled; the service refuses such a pin too (`Announce_Pending`).

**The first pin.** A machine with no pin takes the record that it finds and pins it at once: the first start with this version, or the start after a clear of the TPM. A writer of the disk before that start is not seen.

**Who writes a pin.** Only a run where a seal is allowed, with Secure Boot on (see "Who may seal"): the policy of the index names PCR 7. With Secure Boot off, a pinned record is not written, as the next start would refuse it.

**An update of the system.** A new system has another PCR 11, so the policy of the index is not the policy of now: the state `Held_Other_Policy`. The payload is still read and checked: only a writer of the TPM wrote it. At its next write, the service removes the index and defines it again with the policy of now; the rules of the epoch run against the payload of before. A stop between the removal and the write leaves no pin: the next start pins the record that it finds, as a first pin does.

**A pin that cannot be read refuses.** When the root service gave the TPM and the read of the pin fails (the service stopped, a fault of the interface, an answer of the wrong state or size), `unlock` refuses the record and writes none: a fault of the TPM service must not let a swapped record pass. A machine to which the root service gives no TPM reads and writes no pin: it works as before.

**The order of a write in the service.** The service reads the index and checks the whole change against the stored pin before any command that changes the TPM (`tpm2.pin_write_plan`): an index of an older policy is removed only for a pin that goes forward. When the definition or the write fails after a removal, the service writes a warning: no pin holds until the next write.

**What the pin does not protect against.** The owner hierarchy has no authorization value. Code with the TPM (another system on the machine, or this system after a flaw) removes the index with `TPM2_NV_UndefineSpace`, or puts an index of another shape there, which pins nothing (`Foreign`); the next start then takes the record that it finds. So the pin stops a writer of the disk, not code with the TPM: that needs the authorization value of the owner hierarchy (`ROADMAP.md`, "The TPM floors kept against code with the TPM"). A payload that does not decode refuses each record, the record of the owner too: only a clear of the TPM in the menu of the firmware ends it, and the recovery key then opens the key.

### Who may seal

A seal and a new seal after a recovery run only when the firmware verified the boot program (the trust record says `Firmware_And_Boot_Program`). With Secure Boot off, PCR 7 says "off", and a replaced boot program can extend PCR 11 with the hash of a correct description: a seal then trusts a boot program that nothing verified. The rule matters most after a recovery: an attacker who turns Secure Boot off makes the TPM refuse, as an update does, and a new seal after the recovery would bind the key to "Secure Boot off". The root service refuses `machine_seal()` then, and gives `unlock` the context value `VALUE_SEAL_ALLOWED`; `unlock` skips the new seal with a line of the log. An unseal stays allowed: it opens only a seal that was made with Secure Boot on. The rule has no exception, in a test either.

### One client, and a client that learns a stop

The root service starts `unlock` only from its own procedure `unlock_start`, and one at a time: two runs would share the rings, and one would read the answers of the other. `unlock` holds the TPM service with the right Read: the stop of the service is an event of `unlock`, which ends a wait at once. The service ends each request at its own bound, below the bound of `unlock`, so it never writes a secret after its client stopped waiting.

### The life of the record

**The creation.** `machine_seal()` in the console asks the root service (`Machine_Seal`). The root service starts `unlock` in the mode `Unlock_Mode.Seal_Machine_Key` only on a machine with no record and with the TPM service. `unlock` makes the machine key and the recovery key, asks the TPM service for the seal, and seals the copy under the recovery key, in a record that waits in memory. Then its window shows the recovery key until Enter. After Enter it writes the record, and gives the root service the key of the table with the origin "new". A stop before Enter, a lock of the session whose console asked included, leaves no record, so a recovery key that nobody wrote down never becomes the key of a record ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "No window of `unlock` outlives a lock"). The write reads the record back when the store does not answer it, and a record that may be on the disk keeps its recovery key on the screen ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md), "The write at Enter, and its read back").

**At each start.** `unlock` reads the record. With `MACHINET` it tells the root service that a key is awaited, and asks the TPM service to unseal. When the key passes its check, `unlock` gives the key of the table with the origin "opened". Nothing is typed.

**A refusal of the TPM.** The TPM refuses after an update of the system, on another machine, or after a change of Secure Boot. With no TPM service, the same path runs. The window of `unlock` asks for the recovery key; Enter with nothing skips it, as for the machine passphrase. A recovery key that opens the copy, and whose key passes the check, gives the key of the table with the origin "opened".

**The new seal after a recovery.** When the TPM service runs, `unlock` asks it for a new seal of the same machine key, to the PCRs of the system that runs now. It writes the record with the new areas and the same recovery seal. The next start of this system then needs no recovery key. The disk grant table keeps its tag: the machine key did not change.

**An update of the system.** The old system cannot seal the key to the next measure, because no process of the system knows the next description before the update. So the first start of a new system asks for the recovery key one time, and seals the key again.

### A machine with no TPM

The root service starts no TPM service when the trust record does not say `Measured`: no TPM, a TPM that refused the measure, or a PCR that the boot program did not read. `unlock` then has no ring of the TPM. A new machine passphrase gets the form `MACHINEK`, under the passphrase alone. `machine_seal()` is refused with a sentence. A record `MACHINET` or `MACHINEP` asks for its recovery key.

### The machines of the test

The test needs two systems with the same PCR 7 and two values of PCR 11, and one system with two values of PCR 7 and the same PCR 11.

- **Secure Boot on.** The machines that seal run the firmware with Secure Boot, the enrolled variable store and a software TPM. The first system is the signed main volume (`boot_volume_secure_boot`). The second is the volume of the other system of the trusted boot (`boot_volume_other_system`): one byte of a module changed before its description was made and signed, so another PCR 11. Its boot program is signed for Secure Boot too. A signature of the boot program changes no byte of the boot image, so it changes no PCR 11.
- **Secure Boot off.** One machine starts the same other system on the firmware with a TPM driver and no Secure Boot. That firmware starts a signed boot program too. Its PCR 11 is the PCR 11 of the last seal, and only PCR 7 differs: the TPM refuses because of PCR 7 alone, and the rule refuses the new seal.
- **The TPM device is an option of the machine.** The firmware decides the driver and Secure Boot. The device decides if a TPM answers. Each firmware of the test that has a TPM driver can take the device.

## Refused forms

- **A raw command from the client.** The client could extend PCR 11 or clear the TPM. The service builds each command, and a command has two forms only.
- **The TPM driver in `unlock`.** A process with a window and the passphrase would also hold a device. Property 17 gives the TPM to a device service, and a later client (a counter of the disk grant table, an attestation) reaches the same service.
- **The TPM service as a service with described exports.** A device service with a ring and a region is the form of the block service and of the frame service. The client needs no file of the service and no connection through the root service; the root service gives the ring at the start of `unlock`.
- **A signed policy (`TPM2_PolicyAuthorize`)** in place of exact PCR values. Property 17 names it as the standard form against the cost of an update. It needs a key of the publisher of the system that the TPM verifies: the TPM verifies RSA and ECDSA, not Ed25519. It also lets each older system that the key signed unseal the key, unless the policy also checks the version floor of the TPM ([rollback_floors.md](rollback_floors.md)). Exact values keep "an older system opens nothing" now; a signed policy with the version floor is the later form.
- **A seal at each start with no command.** The recovery key would show at a start that nobody watches, and a key with no recovery is lost at the first update.
- **A seal by the TPM and a seal under the machine passphrase in one record, each enough alone.** An attacker with a copy of the disk tries passphrases against Argon2id, and the TPM adds nothing. The TPM and the passphrase together is the form of the keys of a named principal ([tpm_sealed_principal_keys.md](tpm_sealed_principal_keys.md)) and of the record `MACHINEP` ([tpm_sealed_machine_passphrase.md](tpm_sealed_machine_passphrase.md)): the passphrase gives the authorization value of the sealed object, and the TPM counts the wrong tries.
- **The recovery key through Argon2id.** 160 random bits need no slow derivation. A recovery key that a principal chooses would need one, and it is weaker.
- **The recovery key on the log, or kept in a store.** The log is read by processes and by the host. A key kept on the disk opens the copy for a reader of the disk.
- **The recovery key typed in the console.** The console keeps each line in its history and in its store.
- **The two areas in the additional data of the recovery seal.** A new seal by the TPM would then need the recovery key again.
- **A stop of the start when the TPM refuses.** The machine runs, and the disk grants of principal 0 stay absent until the recovery key is typed, as for a machine passphrase that is not typed.
- **A new machine key when the TPM refuses.** The table that the old key signed would be lost, and an older system that still opens the old record would lose its key.
- **Parameter encryption of the sessions, now.** The machine key crosses the interface of the TPM in clear at the seal and at the unseal. On a discrete TPM, a reader of its bus gets the key. Encryption needs a salted session with the storage key, AES-CFB on the parameters of `TPM2_Unseal`, and a check of the HMAC of the answer; a software TPM on the host sees the key anyway. It is a roadmap entry, to build before a machine with a hardware TPM.
- **A seal with no proof of its creation.** Another system on the machine can make an object with the policy of this system (see "The proof of the creation").
- **The check of the current PCR values by a read of the PCRs.** The unseal already needs the PCRs to hold the values of the policy, and the policy is checked against the creation data: a read adds a command and proves nothing more.
- **A pin with no policy of its write.** Any code with the TPM writes it with the empty authorization of the owner. The policy of PCR 7 and PCR 11 keeps the writes to this system; the removal stays open to code with the TPM (see "The pin of the record").
- **A pin of the form alone.** It was format 1. A writer of the disk who kept an older record of the same form, under an older seal or an older passphrase, put it back, and the pin took it.
- **A pin written once, after the write of the record.** A cut of the power between the write of the disk and the write of the TPM leaves a record that the pin does not name, and the owner is refused with no way back. The announce keeps both records named during the write.
- **A pin of another policy taken as no pin.** Each update of the system would then drop the pin, and a writer of the disk would put back an older record at the first start of the new system.
- **A fall back to the record of before when the pin refuses a record.** The record of before is what a rollback puts back: the refusal keeps the key closed, and the window says why.
- **A seal with Secure Boot off.** It trusts a boot program that nothing verified.
- **A build of the root service for a test that seals with Secure Boot off.** It was the form of the test while no machine of the test had Secure Boot and a TPM together. The test then did not run the rule that a real machine runs, and a boot image of a test held a root service that a release must never hold. With a software TPM on the firmware with Secure Boot, the test needs no such build.
- **A second signed volume for the other system.** The signature does not change PCR 11, so the volume of the other system of the trusted boot serves the machines of the measure and of the seal. A second volume adds a build and proves nothing more.
- **The firmware that decides the TPM device.** The firmware with Secure Boot has a TPM driver. When the firmware decided the device, a machine could not have Secure Boot and a TPM together.

## Subtle points

- **The policy uses the values of now.** `TPM2_PolicyPCR` with no digest takes the values of the PCRs at the command. So a seal on a system that runs binds the key to that system, and a seal of a later system needs that system to run.
- **The data buffer of the interface holds the key.** After a command, the service writes zeros over the buffer of the interface and over its own copies, and the client writes zeros over the region after it reads the key.
- **A ring that a stopped client left.** `unlock` stops after each run, and the next run gets the same ring. A completion of the earlier run can wait there. The client reads and drops each completion before its first command, and each command has a new tag.
- **A session that fails stays in the TPM.** A failed command does not end its session. The service flushes the session and the storage key after each command, in the order of the handles that it holds.
- **The owner hierarchy has no authorization value on the test machines.** A machine whose owner set one refuses `TPM2_CreatePrimary` with `TPM_RC_BAD_AUTH`: the service gives that code, and the seal is refused.
- **The empty HMAC.** A policy session with no `TPM2_PolicyAuthValue`, no salt and no bind has an empty session key. The TPM then takes an empty HMAC, and gives one.
- **The key check before the key leaves `unlock`.** A key that fails the check is erased, and the root service receives nothing: a wrong key would make the root service refuse the table and keep it, with no sign of the cause.

## Built and left

Built: the TPM service with the CRB interface, its ring and its two commands; the encoding of the TPM commands and of their answers, with host tests; the proof of the creation (the ticket, the creation data, the public area), with host tests of a forged object; the record `MACHINET` of format 2, the recovery key and the key check, with host tests; `machine_seal()` with Secure Boot on only; the unseal at each start; the recovery key in the window of `unlock`; the new seal after a recovery, with Secure Boot on only; one `unlock` at a time; the test in `modustool test principals`, part of each full check, on six machines with one software TPM: five with Secure Boot on, on signed volumes, in which the tool reads the recovery key off the screen, and one machine finds a record whose creation ticket has one byte changed and the TPM refuses it; one with Secure Boot off, where the TPM refuses for PCR 7 alone and the new seal is refused. No machine test makes a forged object with the policy of this system: it needs a second system that makes objects on the same TPM; the host tests refuse one.

Built: the pin of the record (see "The pin of the record"): the payload of format 2 with the digest of the record and the announced digest, its rules, the index with its policy in `modus:tpm2`, the commands `Pin_Read` and `Pin_Write` of the TPM service, and the check, the announce and the settle in `unlock`, with host tests of a swapped, removed, older and changed record, of a damaged pin, of a pin of another shape and of another policy, and of the bytes of each command and answer.

Left:

- **A machine test of the pin of the record**: a machine with a software TPM and Secure Boot whose record is replaced, removed or rolled back on the host between two starts, and refused. Today only the host tests prove the rules and the commands.
- **An encrypted session with the TPM.** The freestanding salted-session contract (`modus:contract/tpm_attestation`) implements `KDFa`, AES-128-CFB and XOR-stream parameter encryption, `cpHash`/`rpHash` HMACs, and nonce rolling; wiring it into the TPM service remains.
- **A seal to the measure of the next system.** The `TPM2_PolicyAuthorize` floor verification contract is built in `modus:contract/tpm_attestation`; wiring `TPM2_PolicyNV` into the TPM service remains ([rollback_floors.md](rollback_floors.md)).
- **A change of the recovery key**, and a new one when the old one is lost while the TPM still opens the key.

## State

Built: CRB TPM service, format 2 sealed records with creation proof, recovery key flow, the pin of the record in an index of the TPM with its commands and its check in `unlock`, and the freestanding `modus:contract/tpm_attestation` contract for salted-session parameter encryption and `TPM2_PolicyAuthorize` floor checks, with the wire forms of `TPM2_PolicyAuthorize` and `TPM2_HierarchyChangeAuth`; the TPM service has their steps, which no command runs. Left: wiring salted sessions into the TPM service, a command that runs the signed policy, and the machine tests of the pin.
