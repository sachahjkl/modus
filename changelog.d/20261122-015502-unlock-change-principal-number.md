type: Security

**The number of the principal in the start of a change.** The root service now passes the requesting principal number in `unlock`'s start context for passphrase and recovery key changes, and `unlock` refuses any stored principal file belonging to another principal.
