type: Changed

**The machines of Secure Boot with a TPM.** The machines of `modustool test principals` that seal the machine key and the keys of a named principal now run the firmware with Secure Boot on and a software TPM, on signed volumes, so the seal is tested on the rule of a real machine. The test build of the root service that sealed with Secure Boot off, and its two boot volumes, are gone. One machine starts the same system with Secure Boot off: only PCR 7 differs, the TPM refuses, and no new seal is made.
