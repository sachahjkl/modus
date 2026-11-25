type: Added

**Role-holder measurement, remote TPM attestation, and signed plans.** Added the freestanding contract `modus:contract/attestation` with canonical BLAKE3 measurement of principal 0's active role holders, little-endian remote attestation quote encoding and verification, and domain-separated Ed25519 signed plans with enrolled authority scope masks and monotonic generation checks, along with the `root_role_holders_measure` helper in the root service.
