# The TPM floors: no older system, no revoked key

## Purpose

Before this design, a signed system description stayed valid for ever. The boot program accepted each description that its key signed: an older one with a known flaw too. A stolen signing key signed systems that every machine accepted, until each machine got a new boot program by hand.

This design gives the TPM numbers that only rise, the TPM floors:

- the key floor: the lowest key number of a boot program that the boot program accepts;
- one version floor for each key number: the lowest security version of a system description that a boot program of that key number accepts.

A boot program raises the floors to its own numbers before it measures the system. After that start, the boot program of an older system, or of a revoked key, stops before the kernel starts.

The guide is [`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "10. The TPM floors". The terms are in [`docs/glossary/trusted_boot.md`](../../../docs/glossary/trusted_boot.md): "Security version", "Key number", "TPM floor".

## Constraints

- **The refusal comes before the kernel.** A refused system must run no code of its own: not its kernel, not its root service.
- **The refusal is the work of the old code.** The boot program of the old volume is the one that runs. The check works only because each boot program from this design on carries it.
- **The boot program has no TPM driver** (property 17). It talks to the TPM through the TCG2 protocol of the firmware, as for the measure.
- **"Only rises" must be the rule of the TPM**, not the rule of a process: a process of the old system would not keep it.
- **Only code that the firmware verified may raise a floor.** Else a kernel or a process, of a system that a stolen key signed or of a compromised system, raises a floor to its limit and locks out every image.
- **The owner hierarchy has no authorization value** on the machines of the system ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md)). So any code with the TPM can define, and remove, an index that the owner hierarchy defined. `TPMA_NV_POLICY_DELETE` needs the platform hierarchy, which the firmware keeps: the TPM refuses it for the owner (TPM 2.0 part 3, `TPM2_NV_DefineSpace`).
- **No update path exists in the system.** The old system does not know the number of the next one.
- **A principal must keep a way back** from a release whose fault is not a flaw of security.

## The chosen form

### Two numbers

**The security version** is a field of the header of the system description: a number from 1 to 64. The description signature covers it. The repository holds it as `system_description.SECURITY_VERSION`. The publisher of the system raises it in the commit that fixes a flaw that a rollback would bring back, and at no other release. So a principal can go back to the release before, as long as no flaw separates the two.

**The key number** is a number from 1 to 64 that the boot program holds beside the public key of the signing key. The file `resources/keys/key_numbers` lists each public key of the publisher with its number: the test signing key has 1, the signing key of the publisher 2. The build takes the number of the key that signs, and refuses a key with no line. A new key after a theft gets the next number. With Secure Boot on, the firmware verifies the boot program, so the thief of the signing key cannot change the key number of a boot program: the thief can sign any security version, but cannot sign a new boot program without the firmware signing key. The boot program has no setting for its key number: a test volume with a raised number holds a key file of its own, and a release refuses such a volume.

### The floors are bit fields of the TPM

Each floor is an index of the TPM of the type `TPM_NT_BITS`: 64 bits. `TPM2_NV_SetBits` adds bits and never clears one. So the TPM itself keeps the rule "only rises". The floor is the place of the highest set bit plus one, or 0 with no bit set. A raise to the number n sets bit n − 1.

| Floor | Index | Its number |
|---|---|---|
| The key floor | `0x01806D00` | The key number |
| The version floor of the key number n | `0x01806D00` + n | The security version |

The indices are in the range that the TCG registry of handles gives to the owner (`0x01800000` to `0x01BFFFFF`). `boot_info.KEY_FLOOR_INDEX` and `boot_info.version_floor_index` name them. A machine uses one version floor for each key number that started on it: two indices, or a few more after a change of key.

**One version floor for each key number.** A system that a stolen key n signed can carry any security version, 64 too, and its boot program raises the version floor of the key n to it. That floor then refuses nothing that matters: the key n is to be revoked. The next key starts its own version floor, which the thief never reached.

The attributes of each index are fixed (`tpm2.FLOOR_ATTRIBUTES`):

- `TPMA_NV_POLICYWRITE`: only a policy session writes it;
- `TPMA_NV_AUTHREAD` with an empty authorization value: the boot program reads it, and the boot program holds no secret;
- `TPMA_NV_NO_DA`: a read is no try of a passphrase, so it never counts for the lockout of the TPM.

**The policy of each index is `TPM2_PolicyPCR` of PCR 7 and PCR 11**: PCR 7 as it was at the definition, with Secure Boot on, and PCR 11 as it is before the measure, 32 zero bytes. PCR 7 holds the state of Secure Boot and the certificate that verified the boot program. So only a boot program that the certificate of the publisher verified, before it measures the system, satisfies the policy. After the measure, PCR 11 holds the hash of the description, and no kernel or process can raise a floor: not one of a system that a stolen key signed, not one of a compromised system. A system that a vendor certificate of `db` starts has another PCR 7, because the firmware measures into PCR 7 the certificate that verified the boot program. A machine with Secure Boot off has another PCR 7 too.

### The boot program reads, refuses, then raises

After the signature and the hashes, and before the measure, the boot program works through `SubmitCommand` of the firmware:

1. `TPM2_PCR_Read` of PCR 7. From it, the boot program computes the policy of a floor: SHA-256 of 32 zero bytes, the code of `TPM2_PolicyPCR`, the selection of PCR 7 and PCR 11, and SHA-256 of the value of PCR 7 then of 32 zero bytes.
2. `TPM2_NV_ReadPublic` of the key floor, and of the version floor of its key number. Package `tpm2` decides the state from the answer (`floor_state_of_public`):
   - no index (`TPM_RC_HANDLE`): `Absent`, the floor 0;
   - other attributes or another policy: `Foreign`, the floor 0;
   - the area of a floor that was never written: `Never_Written`, the floor 0;
   - the area of a floor that was written: its bytes are read.
3. `TPM2_NV_Read` of 8 bytes, with the empty password (`floor_state_of_read`): the bits give the floor (`Held`). A refusal of the authorization (`TPM_RC_BAD_AUTH`, `TPM_RC_AUTH_FAIL`, `TPM_RC_NV_AUTHORIZATION`) is `Read_Refused`, the floor 0. Any other failure is `Not_Read`, the floor 0.
4. The key number below the key floor stops the start: the key is revoked. Then the security version below the version floor stops the start. The key comes first: a description that a revoked key signed proves nothing, its security version included.
5. With Secure Boot on, the boot program raises both floors (`floor_step_of`). It removes an index of the state `Foreign`, `Never_Written` or `Read_Refused` with `TPM2_NV_UndefineSpace`, defines an absent or removed one with `TPM2_NV_DefineSpace`, and, when its number is above the floor, sets the bit of its number with `TPM2_NV_SetBits` in a policy session of `TPM2_PolicyPCR`. A `Not_Read` floor is left as it is. A step that fails writes one line, and the start goes on.
6. Then the measure extends PCR 11.

The trust record keeps the two numbers, the two floors that the boot program read, and their states (`boot_info.Floor_State`).

**Why an index that was never written is removed.** The boot program writes each floor that it defines at once. So an index with the area of a floor and no bit was planted by another system, or left by a start that stopped between the two commands. Its authorization value does not show in its area: a planted index can have one, and then, once written, each later read with the empty value fails. Its floor is 0 anyway, so its removal loses nothing. A written index with an authorization value cannot be planted: only the policy of this system writes it. The removal after a refused read covers it all the same.

**What an attacker gains who starts an older signed volume.** The old boot program runs up to its check. Before the check, it reads only the bytes of its own volume, and the signature covers them. No kernel, no process and no measure of the older system run.

**Boot programs from before this design.** They have no check. None was ever built with the production firmware signing key, so the firmware of a machine with the certificate of the publisher starts only boot programs that read the floors (`resources/keys/README.md`).

### When the floor rises

The floor rises at the first start of a new system, after its checks and before its measure. A new release with a raised security version that has a fault later in its start then already refuses the release before it. The way back is a new image of the publisher with the same security version: a fix of a fault that is not a flaw never raises the version.

### The recovery of a machine whose floor is above every image

1. An image of the publisher whose boot program has a key number at or above the key floor, and whose security version is at or above the version floor of that key number. The publisher signs one.
2. A clear of the TPM in the menu of the firmware. It removes every floor, and every key sealed by the TPM: the recovery keys open those keys.

### What the floors do not protect against

- **A clear of the TPM** removes every floor: the owner hierarchy defined them. Each signed system starts until the next start of a boot program with Secure Boot on, which defines them at its own numbers.
- **Any code with the TPM and the empty owner value**: another system on the machine, or the current system after a flaw gives an attacker the TPM (the kernel, the TPM service). It removes a floor with `TPM2_NV_UndefineSpace`, or puts its own index there, and then writes an older signed image with a known flaw to the boot volume. The boot program finds no index, or one that is not a floor that it can read, and takes the floor 0: the older system starts, and its boot program defines the floors at its own, lower, numbers. The flaw then stays across restarts. So the floors stop a rollback by anyone who can only choose which signed volume starts, not by code that runs with the TPM. Such code cannot raise a floor: the policy needs PCR 11 before the measure.
- **A change of PCR 7.** The policy names the value of PCR 7 at the definition. A change of `db`, or of `dbx`, or a firmware update that resets the variables, changes PCR 7. An update of `dbx` needs no principal at the machine: any system can apply one that a KEK of the firmware signed, and a KEK of a vendor signs such updates for every machine that holds it. At the next start each floor is foreign, so each older signed system passes; the first start with Secure Boot on then removes the floors and defines them at its own numbers. If that start is of an older system, its numbers become the floors.
- **A machine with no TPM**, or whose firmware stopped using it, reads no floor and refuses nothing. Such a machine also opens no key sealed by the TPM.
- **Secure Boot off**: PCR 7 differs, so each index looks foreign, and the floor is 0. The boot program changes no floor then. A boot program that nothing verified can skip the check anyway.
- **Another software at the two handles.** The range of the owner is shared by all the software of the machine. The boot program removes any index at a handle of a floor that is not a floor that it can read, also the counter or the secret of another process that chose the same handle. Leaving such an index would leave the floor at 0 for good, as a planted index does.

## Refused forms

- **An index of the type counter (`TPM_NT_COUNTER`).** A counter cannot be set to a number: its first increment gives the largest value that any counter of the TPM ever had (TPM 2.0 part 1, "NV Counter Index"). A compare with a security version then needs a second index that keeps the base, and two indices that must change together. A bit field starts at 0 and needs no base. Its cost is 64 numbers for each floor.
- **An ordinary index that the system writes with the number.** The TPM lets a writer with the policy write a lower number: "only rises" would be the rule of a process.
- **A policy of PCR 7 alone, with the raise in the TPM service.** It was the first form. Nothing extends PCR 7 after the boot program, so each kernel and each process of any accepted system satisfies it: a system that a stolen key signed raises the version floor to 64, and the next key, with a lower security version, is then refused as "an older system". A compromised current system raises either floor to 64 and locks out every image until a clear. With PCR 11 before the measure in the policy, only the boot program raises.
- **One version floor for all the keys.** A thief of the key n raises it to 64 with a description of its own, and blocks each later key. One version floor for each key number confines that to the stolen key.
- **The check in the root service or in the TPM service.** The kernel and the first processes of the older system would run before the refusal.
- **A raise after the whole start.** After the measure no code satisfies the policy, and a policy that code after the measure satisfies is the refused form above.
- **A raise by a command of a principal.** A principal forgets it, and the old system stays usable.
- **The security version raised at each release.** A principal could never go back from a release with a fault that is not a flaw.
- **A list of revoked public keys in the TPM.** It grows, and a writer with the policy removes an entry as easily as it adds one. A floor needs one index of 8 bytes, and it revokes each older key with the stolen one: the publisher replaced those keys anyway.
- **A list of revoked keys in the next system description.** The boot program of the old volume holds the stolen key, and never reads the list of a newer description: the thief starts the old boot program with a description of its own.
- **The revocation in the variable `dbx` of the firmware**, by the hash of each old boot program. It needs the private key of a KEK, it changes PCR 7, so each key sealed by the TPM asks for its recovery key and the floors are defined again, and a firmware has room for a few hundred entries. It is the answer when the firmware signing key leaks: a new certificate in `db`.
- **`TPMA_NV_POLICY_DELETE`.** The TPM refuses it for an index of the owner hierarchy.
- **A refusal when the floors cannot be read.** A TPM that the firmware stopped using would stop each start, with no way back but a change of the firmware. Such a machine opens no sealed key either.
- **Carrying the bits of a foreign index after a change of PCR 7.** The index looks like a floor with another policy; its bits could be kept in the new index. Another system could then plant high bits, and lock out every image until a clear.
- **Leaving a foreign index of another software.** It would leave the floor at 0 for good.
- **A setting of the boot program for a test key number.** A build that passed another value would ship a number that no line of the repository gives. A test volume holds a key file of its own instead.

## Subtle points

- **`TPMA_NV_WRITTEN` changes after the first `TPM2_NV_SetBits`.** The check of the area leaves that bit out; the state `Never_Written` reads it.
- **The answer of a read is big-endian**, as each number of the TPM.
- **The order:** the reads, the key check, the version check, then the raises, then the measure. The raises need PCR 11 before the measure; the checks must come before any raise, so that a refused boot program changes nothing.
- **The response of the firmware is longer than the answer.** The boot program takes the size of the answer from its header before it reads it.
- **The policy session of a raise has no key**, as the sessions of the seal: its HMAC is empty. The boot program computes the policy of a definition itself, with no trial session: the value of PCR 11 before the measure is known.
- **A machine whose owner hierarchy has an authorization value** refuses `TPM2_NV_DefineSpace` and `TPM2_NV_UndefineSpace` with the empty one (`TPM_RC_BAD_AUTH`). The boot program writes the code, and the floors stay as they are: absent on such a machine. The seal of the machine key is refused there for the same reason.
- **The decisions are in package `tpm2`** (`floor_state_of_public`, `floor_state_of_read`, `floor_step_of`), so the host tests check them; the boot program only sends the commands.

## Built and left

Built: the security version in the header of the description (format 2); the key number in the boot program from `resources/keys/key_numbers`, with the key of the publisher; the read and the check of the key floor and of the version floor of the key number in the boot program, with its refusal; the removal of a foreign, planted or unreadable index, the definition, and the raise in the boot program before the measure, with Secure Boot on; the encodings of the commands of the indices, the checks of their answers and the decisions, with host tests of hostile answers; six machines of `modustool test trusted_boot` with one software TPM: a newer system defines and raises the floors; swtpm alone plants an index with an authorization value and a foreign index, and the next start removes both and puts the floors back; the older system is then refused; a newer key raises the key floor and starts the version floor of its key; the older key is then refused; with Secure Boot off, so another PCR 7, each floor is foreign and the older system starts.

Left:

- **A remote attestation of the measure** (`TPM2_Quote`): the freestanding `TPMS_ATTEST` quote parser and verifier covering PCR 7, PCR 11, and PCR 12 is built in `modus:contract/tpm_attestation`; the endorsement attestation key, network transport, and verifier service remain.
- **The floors kept against code with the TPM:** an authorization value of the owner hierarchy. It would keep the pins of the record of the machine key and of the files of the principals too ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "The pin of the record"). The roadmap entry says what it leaves open: a compromise of the code that holds that value, and a change of PCR 7. The wire form of `TPM2_HierarchyChangeAuth` for any hierarchy, with the current value in a password session, and the read of its answer are built in `modus:contract/tpm_attestation`, with the step `hierarchy_authorization_change` in the TPM service; no command of the service sends it. Three things wait before one does: the boot program defines and removes the floors with the empty owner value, so after the change it can no longer define a floor that a change of PCR 7 made foreign; each seal and each unseal makes the storage key under the owner hierarchy, so each would need the value; and the value needs a place to live that opens before the machine key, which itself needs the storage key.
- **A seal of the machine key to a signed policy**, with `TPM2_PolicyNV` on the version floor: the freestanding monotonic counter and `TPM2_PolicyAuthorize` floor verifier is built in `modus:contract/tpm_attestation`, with the wire form of `TPM2_PolicyAuthorize` and the read of its answer, and a host test that a newer signed version passes across a change of PCR 7 with the same authorized digest, while a forged signature, a version below the floor and a revoked key are refused and change no floor. The TPM service has the step `signed_policy_authorize`: it checks the signed statement against the floors, sends the command, and keeps the raised floors only when the TPM took it. No command of the service runs the step: `TPM2_PolicyAuthorize` needs a ticket of `TPM2_VerifySignature` with a key of the publisher that the TPM verifies (RSA or ECDSA), and the publisher signs with Ed25519 ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), "Refused forms"). The key of the publisher for the TPM, `TPM2_PolicyNV`, the boot program and the machine tests remain.

## State

Built: boot-program NV bit-field key and version floors with Secure Boot machine tests, plus the freestanding `modus:contract/tpm_attestation` contract for `TPMS_ATTEST` quote verification, monotonic disk-grant-table counters, `TPM2_PolicyAuthorize` floor checks, the wire forms of `TPM2_PolicyAuthorize` and `TPM2_HierarchyChangeAuth` with the read of their answers, and their steps in the TPM service, with host tests of hostile arguments and answers. Left: end-to-end attestation service, a command of the TPM service that sets the owner authorization value, `TPM2_PolicyNV` on the version floor, and the machine tests of a signed policy.
