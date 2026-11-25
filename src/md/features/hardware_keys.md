# FIDO2 and smartcard hardware keys

## Purpose

A principal uses a hardware security token (a CTAP2/FIDO2 security key or a PIV/OpenPGP smartcard) to prove identity without exposing private keys to the operating system. Four actions of `modus` accept hardware-key proof:

- **Unlock.** Open a session of a principal ([tpm_sealed_machine_key.md](tpm_sealed_machine_key.md)).
- **Wide-grant approval.** Prove consent for a wide grant ([wide_grants.md](wide_grants.md)).
- **Realisation signing.** Sign a built recipe output for an object cache ([recipes.md](recipes.md)).
- **Browser WebAuthn.** Sign a Relying Party challenge for an isolated browser origin.

An isolated hardware-key device service owns the USB HID or CCID device ([device_services.md](device_services.md)). Callers never touch raw USB packets, and private keys never leave the hardware token.

## Constraints

- **Private keys stay inside the token.** The device service sends a challenge and receives a signed assertion. No command exports a private key.
- **Explicit purpose binding.** Every signature covers the closed `Hardware_Key_Purpose`, `Hardware_Key_Protocol`, caller scope (RP ID or action identifier), fresh 32-byte challenge, user presence and user verification flags, and monotonic signature counter. A browser WebAuthn assertion cannot replay as an unlock or wide-grant proof.
- **Freestanding zero-allocation contract.** `modus:contract/hardware_keys` imports `modus:contract/*` and `base:*` only so device services, `unlock`, `recipes`, and browser origins share one verification border.
- **Closed enums and strict flag masks.** Unknown protocol words, unknown purpose words, and unknown flag bits are refused at the border.

## Chosen form

### Protocols and purposes

`Hardware_Key_Protocol` is the closed set `Ctap2_Fido2`, `Smartcard_Piv`, and `Smartcard_OpenPGP`. `Hardware_Key_Purpose` is the closed set `Unlock`, `Approve_Wide_Grant`, `Sign_Realisation`, and `Browser_WebAuthn`.

### Challenges and assertions

A caller constructs a `Hardware_Key_Challenge` carrying the expected protocol, purpose, fresh 32-byte random challenge, printable ASCII scope string (1 to 128 bytes, such as `"modus.unlock"` or a Relying Party hostname), and explicit requirements for `require_user_presence` (physical touch) and `require_user_verification` (PIN or biometric check on the token).

The device service returns a `Hardware_Key_Assertion` encoded in canonical little-endian wire form prefixed by `"MODHWK01"`:

- `version` (`u32`, fixed to `1`), `protocol` (`u8`), `purpose` (`u8`), `flags` (`u8`: `User_Present`, `User_Verified`), and a reserved zero byte.
- `sign_count` (`u32`, monotonic counter reported by the token to detect cloned authenticators).
- `challenge` (32 bytes), `public_key` (32 bytes), `scope_length` (`u32`), `scope_bytes` (`scope_length` bytes), and `signature` (64 bytes).

Signing covers `"modus hardware key assertion v1"` concatenated with the canonical unsigned wire prefix. `hardware_key_assertion_verify` checks structure, constant-time equality of public key and challenge, exact protocol, purpose, and scope match, required `User_Present` and `User_Verified` bits, monotonic `sign_count` (refusing rollback when `last_sign_count > 0` and `assertion.sign_count <= last_sign_count`), and the Ed25519 signature callback.

## Refused forms

- **Signing a raw 32-byte challenge with no purpose tag.** A compromised browser page can present a challenge identical to an unlock challenge and obtain a signature usable for another purpose. Domain separation and explicit `Hardware_Key_Purpose` binding block cross-purpose replay.
- **Accepting assertions without `User_Present` or `User_Verified` when required.** Silent background signing defeats physical consent for unlock and wide grants.
- **Exporting raw token private keys into `unlock` or `recipes`.** Keeping private keys inside the hardware token guarantees that a memory disclosure in a service cannot steal the credential.
- **Passing raw USB HID or APDU frames to application processes.** Raw transport access lets any caller reset the token, change PINs, or query credentials belonging to other origins.

## Subtle points and hazards

- **Sign counter zero.** Some authenticators do not implement a monotonic signature counter and report `sign_count == 0`. `hardware_key_assertion_verify` checks rollback only when `last_sign_count > 0`; once a non-zero counter is observed, any equal or lower counter is refused as `.Sign_Count_Rollback`.
- **Constant-time challenge and key checks.** Public key and challenge comparisons run in constant time without early exit.
- **Exact wire lengths.** `hardware_key_assertion_decode` computes the exact expected byte length from `scope_length` and refuses trailing garbage or truncated bytes.

## State

Built: the freestanding contract package `modus:contract/hardware_keys` (`Hardware_Key_Protocol`, `Hardware_Key_Purpose`, `Hardware_Key_Flags`, `Hardware_Key_Challenge`, `Hardware_Key_Assertion`, canonical encode/decode, and assertion verification with adversarial unit tests).

Left: the USB HID / CCID hardware-key device service module, enrollment in `unlock`, and integration with `recipes` and `wide_grants`.
