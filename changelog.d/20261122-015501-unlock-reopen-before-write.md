type: Security

**A new file under the passphrase alone is opened again before its write.** During a passphrase change or recovery reseal of a `PRINCIPL` file, `unlock` now re-derives the passphrase key and decrypts and verifies the newly built record against the sealed keys and public keys before replacing the stored file, keeping the old file intact on any fault.
