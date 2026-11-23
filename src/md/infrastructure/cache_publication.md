# The publication of a release to an object cache

Each release puts its files and one signed realisation on the public object cache (`cache.modus.systems:5010`), so a machine or a reader takes them by hash. The terms Object cache, Realisation and Cache signing key are in [`docs/glossary/code.md`](../../../docs/glossary/code.md) and [`docs/glossary/trusted_boot.md`](../../../docs/glossary/trusted_boot.md); the protocol is [../features/recipes.md](../features/recipes.md), "The object cache and its protocol"; the server and its page are [public_object_cache.md](public_object_cache.md).

## Purpose

The public object cache ran empty: it accepts an upload only from a key of `--authorized-key`, and no key of the publisher existed for it. A release now fills it, and a test proves on loopback, with no network, that what one command puts, another command gets back and verifies.

## The chosen form

### The cache signing key

A key of its own, an Ed25519 key pair, separate from the signing key and from the release signing key.

- **Least authority.** A leaked cache signing key lets a thief upload objects and sign realisations. An object checks itself by its hash, so the thief adds bytes that nobody asks for. A realisation is trusted only by a principal whose substitution policy names the key, and only for a recipe. The thief cannot sign a system description (the signing key) or a checksum list of a release (the release signing key).
- **Its form** is the form of the signing key and of the keys of `cache-serve`: 64 hexadecimal digits for the seed, 64 for the public key. So the deployment passes the committed file to `--authorized-key` as it is.
- **Its files.** The seed is `cache_signing_key` in the key folder, readable by its owner only. Its public key is `resources/keys/cache_signing_key.public`, committed, so that the deployment authorises it and a substitution policy names it.
- **The secret of the workflow** is `CACHE_SIGNING_KEY`, in the environment `release` and in `secrets/production.yaml` (`secrets/README.md`). The workflow gives it to the tool as `CACHE_SIGNING_KEY_TEXT`; `CACHE_SIGNING_KEY` names the path of the key in the tool, as `SYSTEM_SIGNING_KEY` does.
- **The commands.** `key new <folder>` writes it with the other keys of a new folder. `key new cache <folder>` adds it alone to a folder that has the other keys. `key write cache <folder>` writes it from `CACHE_SIGNING_KEY_TEXT` and refuses a key whose public key is not the committed file: the upload would be refused at the server, after a whole build. `key show cache` prints the public key of the key that `CACHE_SIGNING_KEY` names, and says whether it is the committed one.
- **Refused: the signing key or the release signing key as the cache signing key.** A key that signs the realisations of a server on the internet sits in one more job and on one more path; its leak would then sign a system or a release.
- **Refused: a key for each machine of the publisher.** The publisher is one signer for a principal: one key to trust, one key to revoke. A machine of a principal signs its own builds with the key of the principal ([../features/recipes.md](../features/recipes.md), "The realisation").
- **Refused: `key write` of the release takes a fifth variable.** The job that builds holds the system keys and never the cache key, and the job that uploads holds the cache key alone.

### The client

`tools/modustool/cache_server/cache_client.odin` is the one client of the binary protocol: the commands use it, and the host tests of `cache-serve` drive the server through it.

- **One connection, one request at a time**, each send and each read bounded by the hang bound of the tool. The endpoint is `host:port` with the rule of `--endpoint` ([public_object_cache.md](public_object_cache.md), "One program"); the host name is resolved once.
- **The border of an answer.** The client reads the head of 12 bytes and refuses, before it allocates: a wrong magic, a version that is not 1, a kind or a status that names no member, a body past `MAX_RESPONSE_BODY_BYTES`. It then reads the body whole or refuses the answer as cut. An answer whose kind is not the kind of the request is refused.
- **The client trusts no server.** An object is kept only when its BLAKE3 hash (a blob) or its tree hash (a tree) is the hash that it asked for. A realisation is kept only when it names the recipe that it asked for, its signer is the key that the caller gave, and its signature verifies. A refusal names its cause: `Hash_Mismatch`, `Untrusted_Signer`, `Bad_Signature`, `Damaged_Answer`, `Unreachable`, or the status of the server (`Not_Found`, `Unauthorized`, ...).
- **Before a put,** the client refuses a payload past the bound of its kind, so no frame that the server must refuse leaves the host.

### What a release publishes

1. **Each file of the release boot image** (`build/boot_volume_release.image`, the signed image of the release volume): each module and each resource, as a blob, under the BLAKE3 hash that its entry states, the hash by which the loader finds it. The tool checks each hash against the bytes before any upload: a damaged image uploads nothing. The resources are published too: a machine that takes a system by its hashes needs the system description and the start list as much as the modules.
2. **The realisation of the cache test recipe**, its input and its output.

The cache test recipe is a recipe of the inputs tree builder with one input: the blob `cache_test`, a fixed text of the tool ("modus object cache test v1"). Its output is a tree of one entry. The realisation says "this recipe gave this tree", signed with the cache signing key.

- **Why this recipe.** The inputs tree builder is the one builder that a machine of `modus` realises today (`recipes.build`), and its output is a function of the input table: any reader computes the tree again and checks the claim with no trust in the signer. Its input is a constant, so its recipe hash is a constant: a check of the public cache needs no file of a release.
- **Refused: the recipe of the `collatz` project.** Its builder is a module that only a sandbox starts, and no machine starts it yet (`Builder_Needs_Sandbox`): its realisation would be a signed claim that no reader can check.
- **Refused: a recipe over the modules of the release.** An input table holds 32 inputs at most, and the release image holds about 150 files; and its recipe hash changes at each release, so the check of the public cache would need the image.

Each put is preceded by `Has`, 64 hashes at a time: a second run of the publication uploads nothing that the cache holds, and a cache that holds a release costs three requests of `Has` for it.

### The commands

| Command | What it does |
|---|---|
| `cache-put <host:port> --key <seed file> blob <file>...` | Puts each file as a blob, and prints its hash |
| `cache-put <host:port> --key <seed file> release [<boot image>]` | The publication of a release: the files of the image, then the cache test recipe |
| `cache-get <host:port> blob <hash> [<output file>]` | Gets a blob and checks its hash |
| `cache-get <host:port> realisation <recipe hash> --signer <public key file>` | Gets a realisation and checks its recipe, its signer and its signature |
| `cache-get <host:port> release [<boot image>] [--signer <public key file>]` | Checks each file of the image and the cache test recipe on the cache |
| `cache-get <host:port> test-recipe [--signer <public key file>]` | Checks the cache test recipe alone: its realisation, its tree computed again, and its input |

The default signer is `resources/keys/cache_signing_key.public`.

### The step of the release workflow

The job `cache` of `.github/workflows/release.yml` comes after the job `publish`. It downloads the release boot image, which the job `build` gives as a second artifact, writes the cache signing key from its secret (`key write cache`), and runs `cache-put cache.modus.systems:5010 --key <file> release`.

- **It holds no logic of its own**: one tool command after the key.
- **It holds the cache signing key alone.** The job `build` never sees the cache key; this job never sees the system keys.
- **After `publish`.** The cache holds only the files of a release that GitHub published. A failure of the upload leaves the release published: the release is the files and their signature, and a machine never needs the cache to install it. The job `cache` fails, and the run of the workflow is red, with the refusal of the client in its log. A new run of that job alone uploads what is missing.
- **Refused: the upload inside the job `build`.** That job holds the system keys; one more key and one connection to the internet in it widen what a fault there can reach.

### The proofs

- **On loopback, in the host tests** (`cache_publish_test.odin`): a server on `127.0.0.1` with a throwaway key authorised; the publication of a small boot image; then `cache-get release` and `test-recipe` verify each object and the realisation. The same tests give the refused inputs first: an unauthorised key, a damaged image, a wrong signer, a server that answers a wrong hash, another recipe, a bad signature, a cut frame, an oversize head, an unknown kind or status, a payload past its bound. No test uses the network or a real key.
- **On the public cache, by hand:** `modustool cache-get cache.modus.systems:5010 test-recipe`, and `cache-get cache.modus.systems:5010 release <image>`. They need the network, so no check runs them.

## Subtle points

- **The signer key is given by the caller, not taken from the answer.** A realisation carries the public key of its signer; a client that trusted that field would trust any key.
- **`Has` tells the cache which files the publisher holds.** The publisher publishes them in the next request anyway.
- **A put of an object that the cache holds is not an error**: the server writes it again with the same bytes. The `Has` before it saves the bytes, not a fault.
- **The key in the job.** `key write cache` writes the seed in `$RUNNER_TEMP`, readable by its owner only, on a hosted runner that is discarded after the job.

## State

Built: the client, `cache-put`, `cache-get`, the cache test recipe, `key new cache`, `key write cache`, `key show cache`, the job `cache` of the release workflow, and the host tests on loopback.

Left: the cache signing key of the publisher, its public key in `resources/keys`, its secret in the environment `release`, and its `--authorized-key` in the deployment. Until the file is committed, `key write cache` refuses and the job `cache` fails, with the release published.
