type: Security

**The file of a named principal pinned in the TPM.** On a machine with the TPM service and Secure Boot on, an index of the TPM now holds the SHA-256 digest of the current file of each named principal, and `unlock` refuses a file that a writer of the disk put back after a change of the passphrase, so an older passphrase opens nothing: the log says "the file of principal 1 is not the file that the TPM pins".
