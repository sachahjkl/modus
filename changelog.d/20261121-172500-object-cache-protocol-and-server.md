type: Added

**Object cache wire protocol, signed realisations, substitution policy, and host cache server.** Added the freestanding contract package `modus:contract/object_cache` with strict binary framing, domain-separated Ed25519 signing payloads for realisations and uploads, and pure `substitution_check` verification (hash-only trust for blobs and canonical trees, explicit trusted-signer verification for realisations), together with the content-addressed host server and `modustool cache-serve` command in `tools/modustool/cache_server`.
