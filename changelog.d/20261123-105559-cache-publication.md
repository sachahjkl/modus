type: Added

**Each release on the public object cache.** A release puts each file of its boot image, by its BLAKE3 hash, and one realisation signed with a new cache signing key on `cache.modus.systems:5010`; `modustool cache-put` and `cache-get` put and take objects and realisations on any object cache, and `cache-get` refuses a byte that does not have its hash and a realisation that the trusted signer did not sign.
