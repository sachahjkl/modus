# Principals

A principal is a key pair and the root handles that the key unlocks (`PROPERTIES.md`, property 21; `GLOSSARY.md`, "Principal"). The kernel has no concept of who executes: a program acts with the handles that it holds. The root service holds the records of the principals, and names the principal of each program that it starts. Storage holds the data of a principal.

This guide says what is built, how it works, and what is not built.

## About this guide

**The idea in plain words.** Current systems ask "which user runs this program?" and give the program every right of that user. This system asks two other questions. *Who executes?* Always a program, with the handles that it holds: the kernel knows nothing more. *For whom does it run?* A principal: a key pair, and the stores and grants that its key unlocks. A program does not inherit a principal; it only runs in the session of one, and that fact is recorded, visible and limited to what the root service grants.

**For whom.** A reader who wants to know how the system separates the data of the machine from the data of a named principal, how the unlock works, and which program can see which store.

**Read before.** `PROPERTIES.md`, "21. Principals: who acts, without users" (the rule and its layers) and "20. No ambient access: the other holes to close". The terms principal, named principal, session, unlock, lock of a session, passphrase and acts for the principal are in `GLOSSARY.md`, group Access.

**The map of this guide.**

| Section | What it says |
|---|---|
| "1. The layers, and what is built" | The five layers of the design, and the state of each |
| "2. Principal 0: the machine" | The principal that the system programs belong to |
| "3. A named principal" | Its keys, its file, the key derivation and the passphrase |
| "4. The unlock and the lock" | How a session starts and ends |
| "5. The session" | Which principal each program runs for, and the grant of a connection |
| "6. The store of a principal" | How storage names and separates the stores of each principal |
| "7. The commands" | The commands of the root ring and of the console |
| "8. The tests", "9. Not built" | What the tests prove, and what remains |

**An example.** At the console, `principal_create("alice")` starts the program `unlock`, whose window asks for the passphrase two times. After it, `notes` started from the menu of the desktop runs in the session of alice, and the log says "root: started notes, in the session of principal 1 "alice"". Its store is `notes.principal.1`, which the console, acting for principal 0, cannot open.

![The window of unlock: the passphrase of a named principal, shown as dots](screenshots/principals_unlock.png)

## 1. The layers, and what is built

The design grows in five layers, from a machine with no principal to one principal on several machines. Each layer works alone, and each adds one capability to the layer below it. Layers 1 to 3 are built, in part; layers 4 and 5 are designs.

| Layer | What it is | State |
|---|---|---|
| 1 | No principal: the root service is the only source of grants. A caller acts for the principal or not (`acts_for_principal`) | Built |
| 2 | Principal 0 is the machine: its record holds the measure of the system | Built in part: the record, the measure, and the machine key sealed by the TPM with its recovery key. Its attestation key in the TPM is not built |
| 3 | One named principal: a passphrase unlocks its session, and the lock ends it | Built in part: the record, the unlock, the session, the stores, the lock, and the seal of its keys by the TPM with its passphrase, with a recovery key. Not built: the encryption of its stores, a recovery key on a machine with no TPM |
| 4 | Several named principals on one machine | Not built: design in section 9 |
| 5 | One principal on several machines; signed grants between principals | Not built: design in section 9 |

With no named principal, the system runs as principal 0 only, with no unlock: the behavior of layer 2.

## 2. Principal 0: the machine

The machine itself is a principal, number 0. The programs of the system run for it, and its data are the data of the system, such as the settings. It needs no unlock, and it is not an administrator: it cannot see the data of a named principal.

The root service makes the record of principal 0 at each boot, before the first program starts, from the trust record of the boot program (`TRUSTED_BOOT.md`). The record holds:

- the name `machine`;
- the measure of the system: the value of PCR 11, when the boot program measured the system description into the TPM;
- no key. The key of principal 0 is the attestation key of the TPM. It is not built.

Principal 0 can have a machine key, which signs the disk grant table of principal 0. A machine passphrase guards it (section 5, "Principal 0 and its machine passphrase"), or the TPM seals it to the measure of the system, with a recovery key (section 5, "The machine key sealed by the TPM"). Neither makes principal 0 a person.

The log says which: "root: principal 0 is the machine: the system is measured, PCR 11 = ..." or "root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built".

The programs of the system belong to principal 0: the services, the console, and each program that the console starts. The stores of the system (the settings, the line history of the console) are stores of principal 0, and keep their names.

The key that signs the system description is the key of a principal like any other: the principal that signs the system. It is not principal 0, and it is not in the TPM.

## 3. A named principal

A named principal is a principal with a name and keys of its own: two key pairs, kept on the disk sealed under a key that only its passphrase gives, and, on a machine with a TPM and Secure Boot on, that the TPM of this machine releases only to this system ("The keys sealed by the TPM"). Nothing of the passphrase is stored: a wrong passphrase simply fails to open the seal.

A named principal has the number 1. The root service holds two records: principal 0 and one named principal.

### The keys

| Key | Algorithm | Use |
|---|---|---|
| The signing key | Ed25519 | Signs the grants of the principal. No signed grant is built yet |
| The unlock key | X25519 | Unlocks the documents of the principal. No store is encrypted yet |

The program `unlock` makes the two secret keys from its random generator, which the root service seeded from the sources of the processor (`RANDOMNESS.md`). A seed weaker than the generator of the processor is refused, and no principal is made.

### The file of the principal

The program `unlock` keeps the record in its private store (a store of principal 0), as the object `principal`. Its format is in `src/library/support/principals`. Each number is little-endian. The object has one of two forms, by its first 8 bytes: `PRINCIPL`, under the passphrase alone, below, or `PRINCIPT`, sealed by the TPM ("The keys sealed by the TPM").

| Offset | Bytes | Field |
|---|---|---|
| 0 | 8 | `PRINCIPL` |
| 8 | 4 | The format: 1 |
| 12 | 4 | The KiB of Argon2id: 19456 |
| 16 | 4 | The passes of Argon2id: 2 |
| 20 | 1 | The bytes of the name: 1 to 23 |
| 21 | 23 | The name: letters, digits, `-`, `_`, `.`; zero bytes after it |
| 44 | 32 | The public signing key |
| 76 | 32 | The public unlock key |
| 108 | 16 | The salt of Argon2id |
| 124 | 12 | The nonce of the seal |
| 136 | 80 | The two secret keys (64 bytes) sealed with ChaCha20-Poly1305, and the tag |

The additional data of the seal is each byte before the sealed keys. So a change of the name, of a public key, of the salt or of a parameter makes the open fail.

The file is data from the disk. `file_decode` copies it once and checks the copy: the size, the magic, the format, the name, and the zero bytes after it. A file with other parameters of Argon2id is refused: a file cannot ask for a cheaper derivation, or for more memory than the program has.

### The key derivation

The key of the seal is Argon2id (RFC 9106) of the passphrase and the salt: 19456 KiB (19 MiB) of blocks, 2 passes, 1 lane, a key of 32 bytes. These are the first parameters of the OWASP password storage cheat sheet. The code is the Argon2id of Odin's `core:crypto`, taken by the rule of the cryptography (`CRYPTOGRAPHY.md`), and the module `cryptography` exports it as `argon2id`. The caller supplies the blocks: `unlock` holds them in one memory object of 4864 pages.

A wrong passphrase gives another key, and the open of the seal fails with `Not_Authentic`. No passphrase and no hash of a passphrase is kept or compared.

**The strength.** In the form `PRINCIPL`, the strength of the record is the strength of the passphrase against Argon2id with 19 MiB and 2 passes, for an attacker with a copy of the disk. A passphrase of 8 bytes is the least that `unlock` accepts; it is not a strong passphrase. In the form `PRINCIPT`, a copy of the disk allows no try away from the TPM of the machine, and the TPM counts each wrong passphrase; the count limits the rate of the tries only while the lockout hierarchy of the TPM has an authorization value that the attacker does not know ("The keys sealed by the TPM").

### The passphrase

A passphrase has 8 to 128 bytes of UTF-8 with no control character: é of the layout of France is two bytes. Its bytes are not normalized: the keys give one form of each character, so the same keys give the same passphrase (`src/md/data/text_encoding.md`). The same keys under another layout give another passphrase. It is typed in the window of `unlock` only, and shows as dots. It is never a text of the console: the console keeps each line in its history and in its store.

### The keys sealed by the TPM

On a machine with the TPM service and Secure Boot on, the TPM seals the keys of a new named principal to the measure of the system and to its passphrase together. A copy of the disk allows no try away from the TPM of the machine. The TPM counts each wrong passphrase and then limits the rate of the tries, but only while its lockout hierarchy has an authorization value that the attacker does not know; modus does not set one yet ("What it protects, and what it does not"). A recovery key, shown one time at the creation, opens a copy of the keys when the TPM refuses or when the passphrase is lost. The design is `src/md/features/tpm_sealed_principal_keys.md`.

**How the keys are sealed.** The TPM seals a TPM secret, 32 random bytes, to PCR 7 and PCR 11 ("The machine key sealed by the TPM"), with an authorization value: keyed BLAKE2b of the key that Argon2id derives from the passphrase. The two secret keys are sealed with ChaCha20-Poly1305 under keyed BLAKE2b of the TPM secret over the key of the passphrase. So the keys need the TPM of this machine, this system and the passphrase. A reader of the bus of a hardware TPM, which sees the TPM secret and the value in clear, still runs Argon2id for each guess.

**The count of the TPM.** The sealed object has the attribute `noDA` clear: each wrong passphrase is a failure that the TPM counts. After too many (three on the software TPM of the test machines), the TPM refuses each try for a time (1000 seconds of the time of the TPM there), even the right passphrase; the recovery key still opens the keys. After the lockout the TPM forgives one failure for each 1000 seconds there: about 86 tries a day while the machine runs. The TPM service sends `TPM2_Shutdown` after each use of the passphrase that is not a counted failure: the system has no orderly stop, and with no `TPM2_Shutdown` the TPM counts one failure at each start that follows an unlock. After a counted failure it sends none, so a cut of the power cannot lose a failure that the TPM kept in its RAM; a stop of the machine after a wrong passphrase then counts one more failure at the next start.

**The creation.** `principal_create("alice")` asks for the passphrase two times. With the TPM service and Secure Boot on, the window then shows the recovery key until Enter, and the session starts:

```
tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ... bytes and a private area of ... bytes, with its creation data and its ticket
unlock: principal 1 "alice" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time
```

With no TPM service, or with Secure Boot off, the file has the form `PRINCIPL`, under the passphrase alone, and no recovery key: "unlock: no TPM service: the keys of the new principal are sealed under its passphrase alone, with no recovery key".

**The unlock.** The passphrase opens the keys with no other step. A wrong one is refused and counted:

```
tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code 0x98E)
unlock: the passphrase of principal 1 "alice" is wrong: the TPM refuses it and counts it, nothing is unlocked (1 in all)
unlock: the TPM releases the keys of principal 1 "alice" to its passphrase: the system is the system of the seal; the root service receives the key of its disk grant table only, and the secret keys are erased
```

**When the TPM refuses.** On another system, on another machine, with no TPM service, after a lockout, or with a sealed object that this TPM did not make, the window asks for the recovery key of the principal. On another system the TPM checks the PCRs before the passphrase: it counts nothing, and does not say whether the passphrase was right. Enter with nothing goes back to the passphrase while the TPM service runs. The recovery key opens the copy; with Secure Boot on, the window then asks for a passphrase two times, new or the same, and the TPM seals the keys again to it and to the system that runs. So the recovery key also replaces a lost passphrase:

```
unlock: the keys of principal 1 "alice" wait for their recovery key: the TPM does not release them
unlock: the recovery key of principal 1 "alice" opens its keys
unlock: the keys of principal 1 "alice" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key
```

**The file `PRINCIPT`.** Each number is little-endian.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 124 | As the form `PRINCIPL`, to the salt, with `PRINCIPT` and the format 1 |
| 124 | 4 | The PCRs of the policy: `0x880`, PCR 7 and PCR 11 |
| 128 | 8 | The bytes of the public area, of the private area, of the creation data and of the creation ticket, 2 bytes each |
| 136 | 128 | The public area of the sealed object |
| 264 | 256 | The private area |
| 520 | 256 | The creation data |
| 776 | 72 | The creation ticket |
| 848 | 12 | The nonce of the seal under the seal key |
| 860 | 80 | The two secret keys sealed under the seal key, and the tag |
| 940 | 12 | The nonce of the recovery seal |
| 952 | 80 | The two secret keys sealed under keyed BLAKE2b of the recovery key, and the tag |

Each part of the sealed object has zero bytes after it. The additional data of the seal under the seal key is the first 124 bytes. The additional data of the recovery seal is the first 108 bytes, before the salt, so a new passphrase keeps the copy valid. `principal_tpm_file_decode` refuses other parameters of Argon2id, other PCRs, a name that is not a name, and a part of the sealed object that is not whole.

**What it protects, and what it does not.**

- A copy of the disk opens nothing on another machine or another system without the recovery key.
- The TPM counts the tries on this machine, and limits their rate, only while its lockout hierarchy has an authorization value that the attacker does not know. A new or cleared TPM has an empty one, and modus sets none yet. With an empty one, an attacker with the machine starts another system, changes the count limits of the TPM or resets the count (`TPM2_DictionaryAttackParameters`, `TPM2_DictionaryAttackLockReset`, which do not depend on the PCRs), and starts this system again: each guess in the window of `unlock` then costs one derivation of Argon2id only, as for the form `PRINCIPL`. On the test TPM the rate is three tries, then one for each 1000 seconds of the time of the TPM.
- A new passphrase after a recovery does not revoke the old one: a writer of the disk who kept the old file puts it back, and the old passphrase opens the keys again. Nothing pins the current file.
- Who holds the recovery key holds the principal, on any copy of the disk, old or new, with no TPM: the recovery key never changes, and a new one is not built.
- The TPM secret and the authorization value cross the bus of the TPM in clear: no session encrypts them. A reader of the bus still runs Argon2id for each guess of the passphrase.
- The machine passphrase is not sealed by the TPM: its record keeps the form under Argon2id alone.
- With no TPM, the file `PRINCIPL` has no recovery key.

## 4. The unlock and the lock

A session of a named principal starts when its passphrase opens its file, and ends with a lock. One program, `unlock`, handles the passphrase and the keys; it tells the root service the result and stops.

The root service starts `unlock` at boot, after the boot pass of `settings`.

- With no file, `unlock` stops at once: "unlock: no named principal: the machine runs as principal 0, with no unlock".
- With a file, `unlock` gives the public part of the record to the root service (`Principal_Record`), opens its window, and asks for the passphrase.
- When the seal opens, `unlock` checks that the two secret keys give the two public keys of the file, erases them, tells the root service (`Principal_Unlock`), and stops. The root service starts the session.

**The keys are not kept after the unlock.** `unlock` gives the root service one key, derived from the unlock key: the key of the tag of the disk grant table of the principal (section 5, "The disk grant table of a named principal"). Then it erases the secret keys: no store is encrypted, and no grant is signed. A key that is held with no use is only a target. When storage encrypts the stores of a principal, the unlock gives the unlock key to the storage service, and the lock erases it there.

**The lock** (`lock()` in the console): the root service stops each program of the session and its terminals, marks the principal locked, and starts `unlock` again. The programs stop; they are not frozen: a frozen program needs a kernel operation that does not exist. A program that keeps its state in its store at each change (`notes`) loses nothing.

**The creation** (`principal_create("name")` in the console): the root service checks the name, and starts `unlock` with it. The passphrase is typed two times. `unlock` makes the keys, derives the key of the seal, seals the secret keys, writes the file, gives the record to the root service, and starts the session. With the TPM service and Secure Boot on, the TPM seals the keys with the passphrase, and the window shows the recovery key ("The keys sealed by the TPM").

The root service trusts `unlock` for the record and for the unlock, as the one program with the grant `Principals`, as it trusts `settings` as the one writer of the settings page. No other program can send these two commands.

## 5. The session

Each program runs for one principal, and the root service decides which when it starts the program. A service learns the principal of each caller from the grant of its connection, never from the caller itself.

The root service records, for each program that it starts, the principal whose session the program belongs to:

| Who asks for the start | The principal of the program |
|---|---|
| The root service itself (the services, the console, the boot passes) | 0, the machine |
| A service that starts on demand (`storage`, `sample`) | 0 |
| The desktop: the menu or the palette of the compositor | The named principal that is unlocked, else 0 |
| A program, through its ring to the root service (`start("name")` in the console) | The principal of the program that asks |
| The terminal of a program | The principal of that program |

So a program that the console starts belongs to principal 0, and a program that the desktop starts during a session belongs to the named principal. The log says it: "root: started notes, in the session of principal 1 "alice"".

**The grant of a connection.** The root service gives each caller of a service a grant, in the Connect and Grant commands of the service ring (`src/library/contract/isolated`, values[6]):

| Bits | Field |
|---|---|
| 0 to 46 (`CALLER_AMOUNT_MASK`) | An amount: the limit of blocks of a store |
| 47 (`CALLER_READS_ONLY`) | The connection reads only: the storage service refuses each change on it (`MODULE_CONTRACT.md`, "The debug object of a disk program") |
| 48 to 62 (`CALLER_PRINCIPAL_MASK`) | The number of the principal of the session of the caller |
| 63 (`CALLER_ACTS_FOR_PRINCIPAL`) | The caller acts for that principal |

A caller acts for the principal when its role has the grant `acts_for_principal` (the console, `remote`) and the grant was not revoked. It acts for the principal of its own session only. So the console, started at boot, acts for principal 0, never for principal 1: "root: connected console to the service storage, acting for principal 0". A console that the desktop starts during the session of alice belongs to that session: it acts for principal 1, never for principal 0.

**The grant records name the principal.** `grants("notes")` in the console gives the grants of a program, then "notes runs for principal 1 "alice"". `revoke` works on a program of a session as on any other program.

### Principal 0 and its machine passphrase

Principal 0 stays the machine. A machine passphrase is optional: it guards the machine key, and it opens no session. With no machine passphrase, nothing is typed, and the disk grant table of principal 0 lasts until the machine stops (`MODULE_CONTRACT.md`, "The grants of a disk program").

**The record.** `unlock` keeps it in its store, as the object `machine`. Its format is in `src/library/support/principals`. Each number is little-endian.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 8 | `MACHINEK` |
| 8 | 4 | The format: 1 |
| 12 | 4 | The KiB of Argon2id: 19456 |
| 16 | 4 | The passes of Argon2id: 2 |
| 20 | 16 | The salt of Argon2id |
| 36 | 12 | The nonce of the seal |
| 48 | 48 | The machine key (32 random bytes) sealed with ChaCha20-Poly1305, and the tag |

The additional data of the seal is each byte before the sealed key. The key derivation and the passphrase have the rules of a named principal (section 3).

**The setting.** `machine_passphrase()` in the console starts `unlock`, whose window asks for the passphrase two times. `unlock` makes the machine key from its generator, seals it, writes the record, and gives the root service the key of the tag of the table. A machine with a machine passphrase refuses a second one. `unlock` writes one record in a run at most: when the root service does not take the key in time, `unlock` stops, and the passphrase opens that record at the next start.

**A record that cannot be read.** `unlock` reads the record as absent, present, or unreadable: the store gave an error, or the record does not decode. Only an absent record lets a passphrase be set. An unreadable record gives no key: the disk programs of principal 0 start with no grant, and a change of the table and `machine_passphrase()` are refused, each with a line of the log:

```
root: refused a machine passphrase: the record of the machine passphrase cannot be read, and a new one would replace a key that can be good
```

**The keys.** `unlock` gives the root service one key: the key of the tag of the disk grant table, keyed BLAKE2b of the machine key over a fixed text. It erases the key of the seal and the machine key, and stops. The root service holds the key of the tag until the machine stops; it cannot open the record with it.

**At the start.** The root service starts `unlock` at boot, as before. With a record of the machine, `unlock` asks for the machine passphrase first, then for the passphrase of a named principal if a file of one exists. The window says which one it asks for. Until the machine passphrase is typed, the machine runs, the disk programs of principal 0 start with no grant, and a change of the table of principal 0 is refused. Enter with no passphrase skips it until the next start of `unlock`. After a lock, the root service tells `unlock` that it holds the key, and `unlock` does not ask again.

The log says each step: "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", "unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only", "root: read the disk grant table of principal 0 from the store programs: 1 rows, with the tag of the machine key".

### The machine key sealed by the TPM

A machine with no machine passphrase can keep its disk grants across a restart with no typing: the TPM releases the machine key at each start, but only to the system whose measure it holds. A recovery key, shown one time, opens the key when the TPM refuses. The design is `src/md/features/tpm_sealed_machine_key.md`.

**The TPM service.** The program `tpm` is the device service of the TPM. The root service starts it at boot when the trust record says `Measured` (`TRUSTED_BOOT.md`, "6. The measure"); with no TPM, or with a refused measure, it does not run. It seals 32 bytes to the values of PCR 7 (the state of Secure Boot) and PCR 11 (the measure of the system description), and unseals them only while those registers hold the same values. `unlock` is its one client.

**The setting.** `machine_seal()` in the console asks the root service (`Machine_Seal`), which starts `unlock`. It needs Secure Boot on: the trust record says that the firmware verified the boot program. With Secure Boot off, a replaced boot program can extend PCR 11 with the hash of a correct description, so the root service refuses: "root: refused a machine key sealed by the TPM: the firmware did not verify the boot program (Secure Boot is off), so a seal would trust a boot program that nothing verified". `unlock` makes the machine key and a recovery key from its generator, asks the TPM service for the seal, seals a copy of the key under the recovery key, writes the record, and gives the root service the key of the tag of the table. Its window then shows the recovery key until Enter:

```
recovery key  MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YTB
```

Write it down: it is shown one time, and it is never on the disk or on the log. A machine with a record of its machine key, in either form, refuses `machine_seal()` and `machine_passphrase()`: a change is not built. A machine with no TPM service refuses `machine_seal()`.

**The record.** The object `machine` of the store of `unlock`, as the record of the machine passphrase. Its first 8 bytes say its form. Each number is little-endian.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 8 | `MACHINET` |
| 8 | 4 | The format: 2 |
| 12 | 4 | The PCRs of the policy, bit n for PCR n: `0x880`, PCR 7 and PCR 11 |
| 16 | 2 | The bytes of the public area |
| 18 | 2 | The bytes of the private area |
| 20 | 2 | The bytes of the creation data |
| 22 | 2 | The bytes of the creation ticket |
| 24 | 128 | The public area of the sealed object, with its size field; zero bytes after it |
| 152 | 256 | The private area of the sealed object, with its size field; zero bytes after it |
| 408 | 256 | The creation data of the sealed object, with its size field: the digest of PCR 7 and PCR 11 when the TPM made it; zero bytes after it |
| 664 | 72 | The creation ticket of the sealed object: its tag, its hierarchy, and a digest of up to 64 bytes (swtpm gives one of SHA-512); zero bytes after it |
| 736 | 12 | The nonce of the recovery seal |
| 748 | 48 | The machine key sealed with ChaCha20-Poly1305 under keyed BLAKE2b of the recovery key, and the tag |
| 796 | 32 | The key check: keyed BLAKE2b of the machine key |

The additional data of the recovery seal is the first 12 bytes only, so a new seal by the TPM keeps the copy valid. `machine_tpm_file_decode` refuses a record with other PCRs, a part that is not whole within its limit, a creation data that does not name PCR 7 and PCR 11, or a byte after a part that is not zero.

**The proof of the creation.** Before each unseal, the TPM service has the TPM check the creation ticket (`TPM2_CertifyCreation`), and checks that the policy of the object is the policy of the PCR values of its creation data, with the attributes of a sealed object. So the TPM releases a key only from an object that it made itself while PCR 7 and PCR 11 held the values of the policy. A record that another system on this machine wrote, with an object that it made with the policy of this system, is refused:

```
tpm: refused the unseal: the policy of the object is not the policy of the PCR values of its creation, or its attributes are not the attributes of a sealed object
unlock: the TPM service refuses the unseal: this TPM did not make the sealed object of the record under the PCR values of its policy; the record was written by another system, and only its recovery key opens it
```

**At the start.** `unlock` reads the record and asks the TPM service to unseal. When the key passes its key check, `unlock` gives the root service the key of the table, and nothing is typed:

```
tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal
unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only
root: read the disk grant table of principal 0 from the store programs: 0 rows, with the tag of the machine key
```

**When the TPM refuses.** After an update of the system, on another machine, after a change of Secure Boot, or with no TPM service, the TPM does not release the key. The window of `unlock` asks for the recovery key; it takes upper or lower case, with or without `-`. Enter with nothing skips it: the machine runs, and the disk grants of principal 0 stay absent. A wrong recovery key opens nothing. The right one gives the key, and with Secure Boot on `unlock` seals it again to the system that runs, so the next start of this system needs no recovery key. With Secure Boot off it does not seal it again: an attacker who turns Secure Boot off makes the TPM refuse as an update does, and a new seal would bind the key to a boot program that nothing verified:

```
unlock: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal: another system, another state of Secure Boot, or another machine
unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only
unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs: its next start needs no recovery key
```

**What it protects, and what it does not.**

- A copy of the disk opens no table on another machine, and an older or a changed system opens none on this machine, without the recovery key.
- Another system on this machine that writes the disk cannot make this system take a table of its own key: the proof of the creation refuses its object.
- The form of the record is not pinned: the disk alone says whether the machine key is sealed by the TPM or under a passphrase. A system that writes the disk can replace or remove the record. This system then takes no table of another key, but the disk grants of principal 0 stay absent, and the window asks for a recovery key or a passphrase that the owner does not have. A pin in the TPM is not built (`ROADMAP.md`).
- A replaced boot program that extends PCR 11 with a correct hash could open a key sealed with Secure Boot off; so no key is sealed with Secure Boot off.
- The key crosses the interface of the TPM in clear at each seal and unseal: no session encrypts it. A reader of the bus of a hardware TPM gets it.
- Each update of the system asks for the recovery key one time: no program of the system knows the measure of the next system before the update.

### The disk grant table of a named principal

A named principal grants a disk program from its own session, and its grants last across a restart of the machine (`MODULE_CONTRACT.md`, "The grants of a disk program").

**Who changes it.** A program of the session that acts for the principal: a console that the desktop starts during the session, from the menu of the programs. Its `allow`, `disallow`, `nickname_move` and `disk_persistence` change the table of principal 1. The console that the machine starts at boot changes the table of principal 0 only.

**Where it is.** The object `grant_table` of the store `programs.principal.1`: the store of the module files of the principal, which the disk programs of its session start from.

**Its key.** When the passphrase opens the seal, `unlock` derives the key of the tag from the secret unlock key: keyed BLAKE2b over the text `modus disk grant table of a named principal`. It gives this key with `Principal_Unlock`, and erases the secret keys. The root service keeps the key until the machine stops; after a lock, the next unlock must give the same key.

**The read and the write.** The first unlock of a run reads the table, before any program of the session can change it. Then each change writes it. The rules are the rules of the table of principal 0:

- A table whose tag verifies gives its rows.
- A table that does not verify gives no grant. At the creation of the principal it is written over: no key of this principal signed it. The root service takes a key "of a new principal" only for a record that a creation made since the machine started. At any other unlock the table is kept, and each change is refused until the machine starts again.
- A read that failed starts again at the next unlock.
- A write that fails is tried again at once, 3 tries at most.
- While the read runs, or while the session is locked, a change is refused.

The log says each step: "root: read the disk grant table of principal 1 from the store programs: 1 rows, with the tag of the key of the principal", "root: the disk grant table of principal 1 is written in the store programs: 1 rows, with the tag of the key of the principal".

## 6. The store of a principal

One program run for two principals has two stores, so the data of each principal stay apart. The name of a store carries its principal, and one procedure of the storage service decides from it which stores a caller is allowed to name.

The storage service names a store by the name that the root service gives to the connection. The root service builds that name in one procedure, `principals.store_name_write`, from the principal and the name of the program:

| Principal | Program | Store |
|---|---|---|
| 0 | `notes` | `notes` |
| 0 | `console`, its line history | `console.history` |
| 1 | `notes` | `notes.principal.1` |
| 1 | `console`, its line history | `console.history.principal.1` |
| 0 | The disk program of the nickname `visitor`, with the grant `store` | `disk-visitor` |
| 1 | The disk program of the nickname `visitor`, with the grant `store` | `disk-visitor.principal.1` |
| 1 | The module files of its disk programs, and its disk grant table | `programs.principal.1` |

So two principals that run one program have two stores, and the stores of the system keep their names. The inverse, `principals.store_name_principal`, gives the principal of a store from its name.

**Which stores a caller names.** The storage service applies one rule, in one procedure (`may_name_store`; `STORAGE.md`, "No way up"), from bits 48 to 62 of the grant of each connection:

- A caller that acts for principal N sees the stores of principal N only: `stores()` lists them, and `open_store` gives a place on one of them; another store is refused with `No_Grant`, unit `Acts_For_Principal`.
- Principal 0 sees the stores of principal 0 only. It does not see the stores of a named principal: the machine is not an administrator.
- A caller that does not act for a principal, and a share of a store, see their own store only. A name that does not fit in 31 bytes is refused, never cut: a cut name can be the name of another store. The identity of the package of a program (the key of the principal that signs the package, and its name) enters in the same procedure when storage attaches data to it.

## 7. The commands

**The root ring** (`src/library/support/system`, `Root_Command`):

| Command | Who sends it | What it does |
|---|---|---|
| `Principal_Create` | A program with the grant `Root_Ring` | Starts `unlock` to create the principal with the name of values[0..4] |
| `Principal_Lock` | A program with the grant `Root_Ring` | Ends the session that runs; values[0] of the completion is the count of the programs stopped |
| `Principals` | A program with the grant `Root_Ring` | Reads the record of the principal values[4]: its state, its name, the first 8 bytes of its public key; for principal 0 the first 8 bytes of the measure |
| `Principal_Record` | `unlock` only | Gives the public key (values[0..3]) and the name (values[4..6]) of the named principal; the completion has its number |
| `Principal_Unlock` | `unlock` only | Starts the session of the principal values[4]; values[0..3] is the key of the tag of its disk grant table, values[5] its origin: 1 from the open of the file, 2 from the creation |
| `Grants` | A program with the grant `Root_Ring` | Also gives the number (values[2]) and the name (values[3..6]) of the principal of the program |
| `Machine_Passphrase` | A program with the grant `Root_Ring` | Starts `unlock` to set the machine passphrase |
| `Machine_Key` | `unlock` only | values[4] 1: the machine has a record of its machine key, not opened yet (values[5] 1: sealed by the TPM; 0: under a passphrase); 4: its record cannot be read; 2 or 3: values[0..3] is the key of the tag of the disk grant table of principal 0, from the open of the record (2) or from a new record (3) |
| `Machine_Seal` | A program with the grant `Root_Ring` | Starts `unlock` to make a machine key sealed by the TPM, with a recovery key; refused with Secure Boot off (`Refused`) |

A refusal is an error record with the unit `Principals`: a second named principal ("no free place: the table has its 1 named principals"), a lock with no session, a number with no record, a second record of the machine key (`Exists`), a machine key sealed by the TPM on a machine with no TPM service (`Unsupported`).

**The console:** `principal_create("name")`, `lock()`, `principals()`, `grants("name")`, `machine_passphrase()`, and `machine_seal()`.

## 8. The tests

- `odin test src/library/support/principals`: the names of the stores, a name that does not fit, the names and the passphrases, a round trip of the file, and ten hostile files; a round trip of the record of the machine, and its hostile forms; a round trip of the record sealed by the TPM, its offsets and its hostile forms; a round trip of the file `PRINCIPT`, its offsets, its two additional data and its hostile forms; the recovery key in base32 (the vector "fooba" of RFC 4648) and its parse; the key of the recovery seal and the key check; the authorization value, the seal key and the recovery seal key of a named principal, each with its own text.
- `odin test src/library/support/tpm2`: each command of TPM 2.0 that the TPM service sends, byte for byte, with and without an authorization value, `TPM2_PolicyPassword` and `TPM2_Shutdown`, and the read of the answers with their checks; the policy of PCR 7 and PCR 11, the same policy followed by `TPM2_PolicyPassword`, and the creation hash against digests of SHA-256 computed outside; a forged sealed object (the policy of this system, the creation data of another one), other attributes, a creation data and a ticket of another form, each refused; an object of a named principal with `noDA` set, or with the policy of the PCRs alone, refused; the codes of a counted failure, of a failure that is not counted, of the lockout and of a retry.
- `modustool test principals`, after its two machines below: ten machines with one software TPM and the firmware with no Secure Boot, as the machines of Secure Boot have no TPM device (`TRUSTED_BOOT.md`, "The machines of the TPM"). The first five start the test system whose root service seals with no Secure Boot, a setting of a build of the test only ("root: this system seals with no Secure Boot: a test system, never a release"; `TRUSTED_BOOT.md`, "The machines of the TPM"). The first one: `machine_seal()` seals the machine key, and the tool reads the recovery key off the screen; a second `machine_seal()` is refused. The second one, the same system: the TPM proves the creation and releases the key with no typing, and the table that the first one wrote verifies. The third one, another system (another PCR 11): the TPM refuses, a wrong recovery key opens nothing, the recovery key opens the key, and `unlock` seals it again. The fourth one, that other system again: the TPM releases the key with no typing. The fifth one, that other system on a disk that the tool writes with the record of the fourth one and one byte of its creation ticket changed: the TPM refuses the ticket (`TPM_RC_TICKET`), nothing is unsealed, and the window asks for the recovery key. The sixth one, on the disk of the first four, starts the main volume, whose root service has the rule (another PCR 11): the recovery key opens the key, `unlock` does not seal it again, and `machine_seal()` is refused. No machine test makes a forged object with the policy of this system: it needs a second system that makes objects on the same TPM; the host tests of `tpm2` refuse one. Then four machines on a disk of their own and the same TPM, for the keys of a named principal: the seventh, on the test system, creates alice, the TPM seals her keys with her passphrase, and the tool reads her recovery key off the screen; the eighth, the same system: a wrong passphrase, refused and counted by the TPM (`TPM_RC_AUTH_FAIL`), then the right one opens the session; the ninth, the other system: the TPM refuses the passphrase, a wrong recovery key opens nothing, the recovery key opens the keys, and a new passphrase seals them again; the tenth, the other system again: two wrong passphrases, each counted, make three with the one of the eighth machine, the TPM refuses the right passphrase (`TPM_RC_LOCKOUT`), and the recovery key opens the keys.
- `modustool test disk_programs`: the machine passphrase is set in the window of `unlock`, a table that another key signed is refused, and at the next start the passphrase gives back the grants of principal 0; a table that does not verify under the opened key is refused and kept, with no write. Then the principal alice is created: the table in her store that another key signed is refused and written over; a console of her session grants the store to the nickname `visitor`; at the next start her passphrase gives the grant back, and `visitor` finds its visit in the store of its nickname (`TOOLS.md`, "The disk of the disk programs").
- `odin test src/library/support/cryptography/vectors`: BLAKE2b of RFC 7693 and Argon2id of RFC 9106, section 5.3; the blocks are erased after the derivation, and a supply of blocks that is too small gives `Out_Of_Memory`.
- `modustool test principals`: two machines on one data disk, then the ten machines of the TPM above. The first one: no named principal; a note of `notes` started by the console belongs to principal 0; the creation of `alice` in the window of `unlock`; `notes` from the menu has a new store, `notes.principal.1`; the grants name the principal; the console connects acting for principal 0: `storage.open_store("notes.principal.1")` is refused with `No_Grant`, and `storage.stores()` does not list that store; the lock stops `notes`; a wrong passphrase opens nothing; the right one starts the session again and `notes` finds the note and the count of alice; a revocation of the store of `notes`. The second machine, on the same disk: the passphrase starts the session, and the note of alice is there. Picture: `principals_unlock`.

## 9. Not built

- **A recovery key for a named principal on a machine with no TPM.** The file `PRINCIPL` has no copy under a recovery key: there a lost passphrase is a lost principal. Property 21 asks for recovery from the first version of layer 3.
- **A change of the passphrase of a named principal** while the TPM still opens its keys, and a new recovery key. Today a new passphrase comes only after a recovery.
- **A lockout authorization value that the TPM service sets.** The service sets a random one when it finds an empty one, and reads the count limits of the TPM, so another system cannot change or reset the count of the wrong passphrases.
- **The file of a named principal pinned in the TPM**, so a kept old file, with its old passphrase, is refused.
- **The key of principal 0**: the attestation key of the TPM.
- **The TPM and the machine passphrase together.** The machine passphrase as the authorization value of the sealed machine key, so that the TPM counts the wrong tries.
- **A seal to the measure of the next system.** A signed policy of the publisher of the system, with a counter of the TPM that refuses an older system: an update then needs no recovery key.
- **A change and a removal of the machine passphrase, and a change of the recovery key.**
- **The encryption of the stores of a principal** with its unlock key. Today the data of a principal is on the disk in clear, as each store.
- **The desktop while locked.** The desktop stays: programs of principal 0 run and can be started. A desktop that shows only `unlock` while a named principal is locked is not built.
- **Several named principals (layer 4).** The design: one record for each principal in the root service; one file for each in the store of `unlock`; one session at a time on the desktop, or one desktop for each session. Each principal has disjoint stores by the name of the store, and disjoint grants by the principal of each program. No kernel change.
- **One principal on several machines (layer 5).** The design: the signing key of the principal signs the key of each machine (principal 0 of that machine, its attestation key); a grant to another principal is a record that names its public key and that the signing key signs, with a short lifetime or a revocation list; a store of the principal on another machine is opened with its unlock key, given to that machine through a grant.
