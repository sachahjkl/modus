type: Security

**The TPM service checks the lockout hierarchy again after a failed read**: one silent read of the state of the TPM no longer leaves an empty lockout authorization value for the whole run, so the count of wrong passphrases keeps its limit.
