# Role measurement, remote TPM attestation, and signed plans

## Purpose

A fleet controller or a remote principal needs two capabilities on a running machine of `modus`:

- **Cryptographic proof of machine state.** A remote verifier must know which signed boot description started, which TPM PCR state held, which plan of principal 0 is active, and which role holders run.
- **Scoped remote administration.** Principal 0 can enroll an organization Ed25519 authority key once at provisioning so fleet tools apply signed plans remotely within explicit field scopes, without local keyboard consent for each change.

This design covers three connected contracts in `modus:contract/attestation`: canonical measurement of principal 0's active role-holder set at start, remote TPM attestation quote payloads, and signed plan envelopes. It builds on the role model ([roles_and_contracts.md](roles_and_contracts.md)), the plan of principal 0 at the start ([declarations.md](declarations.md)), the start policy measurement ([start_policy.md](start_policy.md)), and the TPM sealing and quote layer ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md), [rollback_floors.md](rollback_floors.md)).

## Constraints

- **Freestanding and zero allocation.** The contract package imports `modus:contract/*` and `base:*` only. It allocates no memory, calls no kernel operation, and holds no mutable global state.
- **Closed sets and explicit borders.** Every refusal reason, role identifier, and plan field scope crosses borders through explicit values checked with `enum_word.member_of_word` or a strict bit mask check. Unknown words and unknown scope bits are refused.
- **Canonical wire forms.** Every hashed or signed message uses little-endian integers, explicit length prefixes, and a fixed domain separator so no two structures collide under BLAKE3 or Ed25519.
- **Fail closed.** Zero hashes, zero nonces, zero public keys, zero signatures, stale plan generations, duplicate roles, empty scopes, and out-of-scope fields are refused before any state changes.

## Chosen form

### 1. Canonical measurement of principal 0's active role holders

Before the start policy runs, the root service knows every active role holder of principal 0: the defaults of the signed boot image merged with any overrides that `plans` installed via `Plan_Roles` ([declarations.md](declarations.md)).

Each active role holder becomes a `Measured_Role_Holder` carrying three values:

- `role_word`: the explicit `u64` contract value of `role_contract.Role` (refusing `.None` and every unknown word).
- `module_name`: the printable ASCII module name (1 to 64 bytes).
- `module_hash`: the 32-byte BLAKE3 hash of the verified module file.

`measure_role_holders` validates every entry, copies the slice into a fixed stack array bounded by `ROLE_HOLDER_CAPACITY` (32, computed from the 23 closed system roles), sorts ascending by `role_word`, refuses duplicate roles, encodes `[count: u32] || ([role_word: u64][name_len: u32][name_bytes][module_hash: 32])*` in little-endian order, and computes `blake3.derive_key("modus role holders v1", bytes)`.

The root service helper `root_role_holders_measure` walks `role_contract.Role`, resolves each active holder with `role_holder_name`, verifies each present boot-image module entry through `image_entry_give`, and computes the canonical digest. That digest feeds TPM PCR extension before the start policy starts, so an attestation quote binds both the signed image and the active role-holder map.

### 2. Remote TPM attestation payload

`Attestation_Payload` carries the machine state that a remote verifier checks against a fresh challenge:

- `version` (`u32`, fixed to `1`) and a 4-byte reserved field that must be `0`.
- `boot_description_hash` (32-byte BLAKE3 hash of the signed system description).
- `pcr_digest` (32-byte composite PCR digest from the TPM quote).
- `active_plan_hash` (32-byte BLAKE3 hash of principal 0's active plan, or all zeros when no stored plan is active).
- `roles_digest` (32-byte canonical digest from `measure_role_holders`).
- `nonce` (32-byte fresh verifier challenge).
- `signer_public_key` (32-byte Ed25519 attestation key) and `signature` (64-byte Ed25519 signature).

Wire encoding (`attestation_encode` and `attestation_decode`) uses a fixed 272-byte little-endian format prefixed by the 8-byte magic `"MODATT01"`. Signing covers `"modus tpm attestation v1"` concatenated with the 208-byte unsigned wire prefix (magic through `signer_public_key`). `attestation_verify` refuses missing verifiers, wrong versions, zero fields (except `active_plan_hash` when `expected_plan_hash` is also zero), constant-time mismatches against the expected trusted signer key, nonce, boot hash, plan hash, and roles digest, and bad signatures.

### 3. Signed plans from an enrolled authority key

Principal 0 enrolls one `Enrolled_Authority` record binding an organization Ed25519 `public_key`, the target `machine_id`, and a closed `Plan_Field_Scope` bit set of permitted fields (`Role_Holders`, `Plan_Values`, `Signer_Policy`, `Grant_Caps`, `Script_Fonts`, `Start_Policy`).

A remote fleet update arrives as a `Signed_Plan_Envelope` carrying `version` (`1`), `authority_public_key`, `target_machine_id`, monotonic `generation`, `scope_mask`, `plan_hash`, and an Ed25519 `signature`. Signing covers `"modus signed plan v1"` concatenated with the little-endian header fields and `plan_hash` (136 bytes total).

`signed_plan_verify` enforces six checks in order before accepting an update:

1. Structural validity: version `1`, non-zero keys, machine identifiers, plan hash, signature, and generation, and valid non-empty scopes with zero unknown bits.
2. Signer match: constant-time equality between `envelope.authority_public_key` and `authority.public_key`.
3. Target match: constant-time equality between `envelope.target_machine_id` and `authority.machine_id` so an envelope signed for one machine cannot replay on another.
4. Anti-rollback: `envelope.generation > current_generation`.
5. Scope containment: `envelope.scope_mask` is a subset of `authority.allowed_scope`, and `requested_scope` is a subset of `envelope.scope_mask`. Any field outside the enrolled scope is refused.
6. Signature verification through the caller-supplied Ed25519 callback.

## Refused forms

- **Hashing role holders in table iteration order without sorting.** Any caller-supplied ordering difference produces a different digest for the same role set. Sorting by `role_word` makes the digest invariant to input order.
- **Allowing unknown scope bits to be masked out.** Silently ignoring reserved bits lets a newer controller send restrictions that an older verifier drops. The border refuses every bit outside `ALL_PLAN_FIELDS`.
- **Single-key signing without a target machine identifier.** Without `target_machine_id`, an attacker with network access can replay a valid signed plan from one machine onto another machine enrolled under the same authority.
- **Unbounded variable-length attestation envelopes.** Fixed-size 272-byte wire encoding removes parser state machines, heap buffers, and length-confusion attacks from the attestation border.
- **Calling `modus:cryptography/ed25519` directly from the contract package.** Contract packages must stay free of support-package imports so the boot program, kernel, services, and host tools share one pure verification border while supplying their own Ed25519 implementation.

## Subtle points and hazards

- **Constant-time comparisons.** All digest, nonce, machine identifier, and public key comparisons run without early exit so verification timing reveals no prefix bytes.
- **Zero `active_plan_hash`.** A freshly booted machine with no stored plan has an all-zero `active_plan_hash`. `attestation_verify` accepts an all-zero `active_plan_hash` only when `expected_plan_hash` is also all-zero; any mismatch is refused.
- **Minimal boot images.** Some test or console boot images omit optional default role modules (such as `remote_display`). `root_role_holders_measure` skips modules absent from the boot image, while failing closed if a present module fails its hash verification.

## State

Built: the freestanding contract package `modus:contract/attestation` (role-holder measurement, attestation payload wire encoding and verification, and signed plan verification with host unit tests) and `root_role_holders_measure` in `src/modules/system/root/role_measurement.odin`.

Left: wiring `root_role_holders_measure` into the TPM PCR extend call at start before `start_policy` runs, exposing signed-plan enrollment in `plans`, and adding a multi-machine QEMU attestation test.
