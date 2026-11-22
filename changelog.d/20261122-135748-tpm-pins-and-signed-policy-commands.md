type: Added

**TPM pins and signed-policy commands, ahead of their indices**: the TPM attestation contract now holds the payloads that pin the form of the record of the machine key and the current file of each named principal, refusing a downgrade from a sealed form to `MACHINEK`, an older epoch or generation, a zero or mismatched digest and a damaged payload, and the exact commands `TPM2_PolicyAuthorize` and `TPM2_HierarchyChangeAuth` with a strict read of their answers. The TPM service has the steps that use them; no command runs them yet.
