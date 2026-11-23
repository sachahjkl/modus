## Trusted boot

### Signing key

The signing key is the Ed25519 key pair of the principal that signs the system: its private key signs the system description, and the boot program holds its public key.

The signing key answers one question at each start: is this the system that its signer built? The build signs the system description, which names each module and resource by its hash. The boot program verifies the signature before the kernel starts, then compares each file with the description. `modustool key new <folder>` makes the pair, and `SYSTEM_SIGNING_KEY` names it before a build; with no variable, the build signs with the test signing key. It is not a key of the TPM, and not the platform key of Secure Boot.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: owner key, master key, release key, platform key (PK is a term of Secure Boot).

### Test signing key

The test signing key is the signing key of the tests: a key pair whose private key is published, so that a system that it signs is never trusted.

The key pair is the one of RFC 8032, section 7.1, TEST 1, in `resources/keys/test_signing_key`. Each build with no `SYSTEM_SIGNING_KEY` uses it: the test builds and the pictures of the site do. Anyone can sign a system with it, so the system says so at each place: the trust record has the key kind `Test`, the boot display says it in red, the root service writes a warning on the log, and the tool writes a file `<volume>.signed_by` beside the boot volume.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: development key, demo key.

### Signed message

The signed message is the 64 bytes that the signing key signs for one system description: a fixed label padded with zero bytes to 32 bytes, then the BLAKE3 hash of the description.

The label `system description signature 1` (`SIGNATURE_LABEL` of `src/library/modus/contract/system_description`) binds the signature to this one use: a signature that the key makes for another purpose is never a valid description signature. The number in the label names the version of the form. `system_description.signed_message` builds the bytes. The measure puts the same 64 bytes in the event log of the firmware, so the log names the system by its BLAKE3 identity.

The design: `docs/TRUSTED_BOOT.md`, "1. The claims".

Do not use: payload, digest (for this).

### Description signature

The description signature is the Ed25519 signature, 64 bytes, of the signed message of a system description.

The boot image holds it as its last resource, `system_description_signature`, after the resource `system_description`. The description does not list these two resources, because a file cannot hold its own hash. Before the kernel starts, the boot program verifies it with the public key that it holds, and a signature that does not verify stops the start. It is not a certificate: it names no one and has no date. The signature of an older description verifies too: the version floor of the TPM refuses an older system, once a newer one started.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description".

Do not use: certificate, manifest signature.

### Trust record

The trust record is the record `boot_info.Boot_Trust` that the boot program writes to say what verified the system description, with which key, and what the TPM holds.

It holds the verifier (the boot program alone, or the firmware and the boot program when Secure Boot is on), the key kind and the public key, the hash of the system description, the state of the measure, and the numbers that it compared with the TPM floors. The kernel copies it into the boot record, and the boot display draws its line "trust" from it. It is not an attestation: a replaced boot program can write a false one. Only Secure Boot makes it come from a verified boot program.

The design: `docs/TRUSTED_BOOT.md`, "4. What a failure shows".

Do not use: attestation, security state.

### Measure

The measure is the extension of a register of the TPM with the SHA-256 hash of the system description, which the firmware does at the request of the boot program before the kernel starts.

A TPM register can only be extended, never set, so after the measure PCR 11 names the system that started, and no code that runs later can set it back. The TPM service seals the machine key to it, with PCR 7. The boot program asks the firmware, with the signed message as the data of the event, then reads PCR 11 back into the trust record. If the TPM refuses, the boot continues, and the trust record says `Refused`. The TPM measures and seals; it does not verify the description.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: attestation (for this), seal, measurement log (for this).

### Measure register

The measure register is PCR 11 of the TPM: the register that holds the measure.

The rules of the TCG for PC firmware leave PCR 8 to 15 to the operating system, and the conventions of Linux give PCR 11 to the whole system image that a boot stage measures before the kernel. `boot_info.MEASURE_REGISTER` is 11. The trust record keeps the value of the SHA-256 bank, and `modustool` computes the same value from the description and compares. The policy of a key sealed by the TPM names PCR 7 (the Secure Boot state) beside it.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: slot, PCR (alone, for this register).

### Start policy register

The start policy register is PCR 12 of the TPM: the register that the root service extends with each start policy that starts, before it runs.

The value of one extend is SHA-256 of the hash of the module and the hash of its list, 32 zero bytes for a chosen start policy. A rescue after a failure is a second extend, and the TPM service takes two at most in one start. No seal reads this register, so a new choice of a start policy changes no unseal; an attestation reads it to learn which start policy ran.

The design: `docs/TRUSTED_BOOT.md`, "PCR 12: the start policy".

Do not use: configuration register, measure register (for this one).

### Measure ring

The measure ring is the ring from the root service to the TPM service on which the root service alone sends `Measure_Start_Policy`.

The root service makes it and holds its one writer side; the TPM service serves it beside the TPM ring of `unlock`, one request at a time. The TPM ring refuses that command with `Bad_Command`, and the measure ring refuses `Seal` and `Unseal`, so no process but the root service extends the start policy register. It has no region: the digest is in the record.

Do not use: root TPM ring, extend ring.

### TPM service

The TPM service is the process `tpm`: the device service of the TPM of the machine, which seals 32 secret bytes to the values of PCR 7 and PCR 11 and unseals them only while those registers hold the same values.

The root service starts it at boot, before `unlock`, only when the trust record says `Measured`. `unlock` reaches it with the start grant `Tpm`, through a ring of two commands, `Seal` and `Unseal` (`src/library/modus/contract/tpm_service`); the root service, through the measure ring. The service builds each command of TPM 2.0 itself, so no client extends a register or clears the TPM. It is not a driver in the kernel, and the boot program does not use it: the boot program talks to the TPM through the firmware, before the kernel starts.

The design: `src/md/features/tpm_sealed_machine_key.md`.

Do not use: TPM driver (for the program), TPM daemon, resource manager.

### Wait report

A wait report is the fact that the TPM service or `unlock` writes each 30 s of a long wait for the TPM, and names what the wait waits for.

The bounds of the path of a key are long, so that a slow TPM that works does not fail. A wait report makes such a wait readable before its bound: the TPM service names the step of the interface, the TPM command, the locality and the request (`tpm_device_service.Wait_Passed`); `unlock` names its request (`unlock.Tpm_Wait_Passed`). A reader reads it; no test fails on it. It is not a stall (`docs/glossary/project.md`): nothing counts progress.

The design: `src/md/features/tpm_sealed_machine_key.md`, "A wait that is long".

Do not use: progress report, stall report, heartbeat, keepalive.

### Sealed by the TPM

A secret is sealed by the TPM when the TPM holds it in a sealed object whose policy is the values of PCR 7 and PCR 11 at the seal: the TPM gives it back only to the same system, measured by the boot program, with the same state of Secure Boot.

A seal needs Secure Boot on. An older system, a changed system, a machine whose Secure Boot was turned off, or a copy of the disk on another machine opens nothing. Two secrets are sealed so: the machine key (`machine_seal()`), and a TPM secret, whose sealed object also has an authorization value. For the machine key of `machine_seal()`, no passphrase is typed: the strength is the TPM, not a derivation. For a TPM secret, the TPM and the passphrase are needed together.

The design: `docs/PRINCIPALS.md`, "The keys sealed by the TPM".

Do not use: bound to the TPM, TPM-encrypted, locked (for this).

### Recovery key

A recovery key is a key of 20 random bytes, shown one time as 32 characters of base32 in 8 groups of 4, that opens a copy of the machine key, or of the keys of a named principal, when the TPM does not release them.

The window of `unlock` shows it once, after a seal by the TPM, or after `recovery_key_change()`. It is never kept on the disk or written on the log. When the TPM refuses (an update of the system, another machine, no TPM, a lockout), the window asks for it; at a passphrase prompt, Ctrl+R asks for it at once. After a recovery, `unlock` seals the key again to the system that runs, and asks for a new passphrase when one was lost. Its 160 random bits need no slow derivation.

Example: `MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YTB`.

The design: `src/md/features/tpm_sealed_principal_keys.md`.

Do not use: backup key, reset key, PIN, recovery password.

### Authorization value

An authorization value is the secret that a sealed object needs beside its policy: the TPM compares it at each unseal, counts each wrong one, and refuses each try for a time after too many.

The keys of a named principal and the machine key under a machine passphrase use it. The value is keyed BLAKE2b of the key that Argon2id derives from the passphrase, so a reader of the bus of the TPM still runs Argon2id for each guess. After a lockout, the window of `unlock` asks for the recovery key. The count limits the rate of the tries only while the lockout authorization value is secret. It is not the passphrase, and nothing of it is on the disk.

The design: `docs/PRINCIPALS.md`, "The keys sealed by the TPM".

Do not use: PIN, password (for this), TPM password.

### Lockout authorization value

The lockout authorization value is the authorization value of the lockout hierarchy of the TPM: the one secret that resets the count of the wrong authorization values, changes its limits, or clears the TPM through that hierarchy.

A new or cleared TPM has an empty one, and then any system on the machine can reset the count. Before the first use of a passphrase, the TPM service sets 32 random bytes when the value is empty, and erases them: nothing in the system can reset the count. A value that is set already stays. The first system of the machine that sets the value owns the reset of the one count of the TPM. It is not the authorization value of a sealed object, and nobody types it.

The design: `src/md/features/tpm_sealed_principal_keys.md`, "The lockout authorization value".

Do not use: lockout password, lockout PIN.

### TPM secret

The TPM secret is the 32 random bytes that the TPM seals with an authorization value, for a named principal or for the machine passphrase: with the key of the passphrase it gives the seal key of the secret keys of the principal, or of the machine key.

The seal key is keyed BLAKE2b of the TPM secret over the key of the passphrase and a text of its use. So the keys need the TPM, the measure of the system and the passphrase together, and a reader of the TPM secret still runs Argon2id for each guess. A new passphrase, after a recovery or a change of the passphrase, gives a new TPM secret.

It is not the machine key, and not a key of the principal: it signs and opens nothing alone.

The design: `src/md/features/tpm_sealed_principal_keys.md`, `src/md/features/tpm_sealed_machine_passphrase.md`.

Do not use: TPM key, sealed key (for this).

### Key check

The key check is keyed BLAKE2b of the machine key over a fixed text, which the record sealed by the TPM keeps beside the seals.

After an unseal or a recovery, `unlock` compares the check of the key that it received with the check of the record, and gives the root service nothing when they differ. A record whose areas come from another record, or a TPM service that gives another key, then has no effect but a request for the recovery key. Keyed BLAKE2b is a pseudorandom function: the check reveals nothing of the key.

The design: `src/md/features/tpm_sealed_machine_key.md`.

Do not use: fingerprint, hash of the key.

### Firmware signing key

The firmware signing key is the RSA-2048 key and its self-signed X.509 certificate with which the principal that signs the system signs the boot program for Secure Boot.

UEFI Secure Boot verifies Authenticode signatures with RSA keys and X.509 certificates, and cannot verify Ed25519. So a second key closes the gap of the first: without Secure Boot, anyone who can write the boot volume can replace the boot program, its public key and its checks. `modustool key new` makes the pair beside the signing key, and the build signs the boot program with it. A principal present at the machine enrols the certificate in the variable `db` of the firmware. With Secure Boot on, the trust record says `Firmware_And_Boot_Program`.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: db key (for the pair), Secure Boot key.

### Test firmware signing key

The test firmware signing key is the firmware signing key of the tests, whose private key is published, so that a boot program that it signed is never trusted.

The pair is `resources/keys/test_firmware_signing_key.pem` and `.crt`; `modustool key test-firmware-new` wrote it once. The variable store of the test machines of Secure Boot has its certificate as PK, KEK and the one entry of `db`. `modustool test trusted_boot` checks with it that the signed boot program starts, and that a boot program with one byte changed, or unsigned, does not. The machines of the keys sealed by the TPM in `modustool test principals` start from the same variable store, with a software TPM.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: development certificate.

### Key folder

The key folder is the folder outside the repository that holds the keys of the publisher of the system: the signing key, the firmware signing key and its certificate, and the release signing key.

`modustool key new <folder>` makes it, each private file readable by its owner only, in a folder that only its owner can open. `modustool key write <folder>` makes the same folder from the four secrets of the workflow of a release. `SYSTEM_SIGNING_KEY` names the signing key in it, and the tool finds the other keys beside it.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: keyring, key store, vault.

### Release signing key

The release signing key is the Ed25519 key pair of the publisher of the system whose private key signs the checksum list of the files of a release.

It answers one question: do these downloaded files come from the publisher of the system? It signs no system: the signing key does. No machine holds it, so a new release signing key changes no machine. Its seed is `release_signing_key` in the key folder; its public key is `resources/keys/release_signing_key.public`, and the site publishes it. A key text is 32 bytes in base64url with no padding, the form of the package `signing` of gui_toolkit. `modustool release image` refuses a release signing key whose public key is not the file of the repository.

The design: `src/md/infrastructure/release_image.md`.

Do not use: release key, download key, GPG key.

### Cache signing key

The cache signing key is the Ed25519 key pair of the publisher of the system whose private key signs its uploads and its realisations on an object cache.

It answers one question: did the publisher of the system put this realisation on the object cache? It signs no system and no release, so its leak lets a thief put objects and realisations, which a principal trusts only when its substitution policy names the key. Its seed is `cache_signing_key` in the key folder, 64 hexadecimal digits; its public key is `resources/keys/cache_signing_key.public`, which the public object cache authorises. It is a secret of the GitHub environment `cache` alone, and only the job `cache` of the release workflow holds it.

The design: `src/md/infrastructure/cache_publication.md`.

Do not use: cache key, upload key, the release signing key for an object cache.

### Checksum list

The checksum list is the file `SHA256SUMS.txt` of a release: one line for each published file, its SHA-256 in 64 lowercase hexadecimal digits, two spaces and its name.

It has the form that `sha256sum -c` reads. Its line names the compressed image, the file that a principal downloads. The release signature covers it, so the image needs no signature of its own. Example: `3f0c...e1  modus-0.93.0-x86_64.img.zst`.

The design: `src/md/infrastructure/release_image.md`.

Do not use: manifest, hash file, digest list.

### Release signature

The release signature is the Ed25519 signature, by the release signing key, of the release signature context and the checksum list: the file `SHA256SUMS.txt.sig`, in base64url with no padding.

The release signature context is the bytes `modus release checksums 1` and an end of line. It binds the signature to this one use: a signature that the key makes for another message is never a release signature, and a signature of the checksum list alone does not verify. `modustool verify` checks it before it reads a line of the list; OpenSSL 3 checks it with no tool (`docs/INSTALL.md`, "2. Verify the files").

It is not a description signature: that one signs a system description, with the signing key.

The design: `src/md/infrastructure/release_image.md`.

Do not use: detached signature (for this), checksum signature.

### Release volume

The release volume is the boot volume that a release publishes: the main boot image, the kernel of the tests, and the boot program signed with the firmware signing key, signed with the keys of the publisher of the system.

Only `modustool release image` builds it, as `build/boot_volume_release.img`, after a whole build: it is not in the list of the volumes of the build, and no test boots it. Its form is the form of the volume of the machine of Secure Boot of the tests, with other keys.

The design: `src/md/infrastructure/release_image.md`.

Do not use: production volume, installer.

### Release image

The release image is the disk image that a release publishes: a GPT disk whose one partition, the EFI system partition, is the release volume, compressed with zstd.

A principal writes it to a USB key with `dd` (`docs/INSTALL.md`, "3. Write the USB key"). The boot volume of the tests has no partition table; the release image has one, because the firmware of a real machine reads a GPT disk. The GUIDs of the disk come from the hash of the volume, so one volume gives one disk. Its only pointer theme is the theme of the system: a release image never holds the Posy theme. File: `modus-<release number>-x86_64.img.zst`.

The design: `src/md/infrastructure/release_image.md`.

Do not use: ISO, installer, live image.

### Security version

The security version is the number from 1 to 64 in the header of a system description that the version floor of the TPM compares: the boot program refuses a description whose security version is below the floor.

The description signature covers it. The repository holds it as `system_description.SECURITY_VERSION`, and the build writes it into each description. It rises only with the fix of a flaw that a return to an older system brings back, so after a release with no such fix a principal can go back to the release before. Example: the version 2 fixes a flaw of the version 1; after a start of the version 2, the machine refuses the version 1. It is not the version of the format of the description, and not a release number.

The design: `src/md/features/rollback_floors.md`.

Do not use: generation, epoch, rollback counter, release number (for this).

### Key number

The key number is the number from 1 to 64 that the boot program holds beside the public key of the signing key, which the key floor of the TPM compares.

`resources/keys/key_numbers` gives each public key of the publisher of the system its number; the test signing key has 1, and the build refuses a key with no line. A new key after a theft or a loss gets the next number. The first start of a system of the new key raises the key floor: each boot program with a lower number then refuses to start on that machine. It is not a part of the key, and the description signature does not cover it: Secure Boot covers the boot program that holds it.

The design: `src/md/features/rollback_floors.md`.

Do not use: key generation, key version, key index.

### TPM floor

A TPM floor is an index of the TPM, a field of 64 bits that only gains bits, whose highest set bit plus one is the lowest number that the boot program accepts.

The key floor is compared with the key number of the boot program; one version floor for each key number is compared with the security version. The TPM keeps the rule "only rises": no command clears a bit. Only a boot program that the certificate of the publisher verified can raise a floor, before its measure. The boot program reads both floors, stops the start for a number below a floor, then raises both to its numbers. A clear of the TPM removes every floor. It is not a counter of the TPM, and not a PCR.

The design: `src/md/features/rollback_floors.md`.

Do not use: rollback counter, monotonic counter, anti-rollback index.

### TPM pin

A TPM pin is an index of the TPM, which only this system writes, that names the current record of the machine key or the current file of a named principal by its digest.

`unlock` refuses a record or a file that its pin does not name: another form, an older one, a removed one. A write announces the new digest in the pin first, then writes the store, then settles the pin. Anyone reads the index; only a policy of PCR 7 and PCR 11 writes it. Code with the TPM can still remove it while the owner hierarchy has no authorization value. It is not a pin of a declaration input, and not a TPM floor.

The design: `src/md/features/tpm_sealed_machine_key.md`, "The pin of the record".

Do not use: record lock, anchor, seal of the record.

### Start request

The start request is the field of the boot record that says which start policy the root service starts at this start: `Chosen`, the zero value, or `Rescue`.

The boot program writes it, with its source: the key R or the boot entry "modus (rescue)". The kernel copies both words into the boot record and reads neither. The root service reads them through one border, `boot_info.start_request_of_words`, which refuses a word that names no member and a pair that disagrees; a refused pair starts the rescue start policy, with its line. The request holds for one start: nothing changes on the disk.

The design: `src/md/features/start_policy.md`, "The rescue key".

Do not use: boot flag, boot mode, kernel command line.

### Rescue key

The rescue key is the key R, held while the machine starts: it asks for the rescue start policy at that start.

The boot program reads the keys that the firmware holds, with no wait, at its start and again before the end of the firmware services; a held key repeats, so it waits in the buffer of the firmware at both reads. The firmware reads the keyboard, so a USB keyboard works before the system has a driver for it. The key gives no new authority: it reaches the rescue list, which is signed with the system.

Do not use: magic key, recovery key (that term is a key of the TPM), hotkey.

### Rescue boot entry

The rescue boot entry is the boot option "modus (rescue)" of the firmware, whose load options ask for the rescue start policy.

The boot program writes it at a start where it is absent, and puts its number at the end of `BootOrder`, with one line. Its load options are one record of 16 bytes: the tag `MODUSOPT`, the version 1, and the word of a start request. Load options with no tag are a normal start; a tagged record that is wrong stops the boot program, with its cause on the boot display. A machine with no keyboard, or a remote console, reaches the rescue through it.

Do not use: recovery entry, rescue partition, boot flag.

### Publisher

A publisher is a key pair whose private key signs release pointers and realisations, and which a principal can name as a key that it trusts.

The publisher of the system is one publisher. A key that a principal trusts is valid for that principal only: the system plan trusts the publisher of the system alone. The bytes that a publisher signs come from any source; the trust comes from its key. A publisher is not a server of authority, and not a principal.

The design: `src/md/features/declarations.md`, and `src/md/features/recipes.md`.

Do not use: vendor, maintainer, authority.
