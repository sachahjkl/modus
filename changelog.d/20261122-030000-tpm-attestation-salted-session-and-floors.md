type: Added

**TPM 2.0 salted session, remote quote verifier, and rollback floor contracts.** Added freestanding `modus:contract/tpm_attestation` with `KDFa`/HMAC-SHA-256 salted session parameter encryption (constant-time AES-128-CFB and XOR stream), strict `TPMS_ATTEST` quote verification over PCR 7, 11, and 12, and monotonic grant-table counters with `TPM2_PolicyAuthorize` floor enforcement.
