type: Changed

**Fresh bytes pages for device services, TPM, input, and terminals.** The root service now maps a fresh-bytes entropy page into device services, the TPM service (also resolved by `Role.Tpm`), `input`, and every `terminal`, and `date.zone_offset_seconds_read` uses `.Acquire` load ordering.
