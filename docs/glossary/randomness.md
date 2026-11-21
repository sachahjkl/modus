## Randomness

### Random seed

A random seed is the 32 bytes from which a random generator starts.

Each process needs unpredictable bytes (keys, nonces, the secret of the TCP sequence numbers), and the kernel gives none. So its starter writes 32 bytes of its own random stream in the context of the process, and the process reads them once with `random.generator_from_context`, which erases them. The root service has no starter: it gathers the seed of the system from the sources of the processor, and every other seed descends from it. A child has no secret from its starter, which already chooses its code and its grants.

The design: `docs/RANDOMNESS.md`, "1. Where a process gets random bytes".

Do not use: entropy (for this), salt.

### Random generator

A random generator is a record of fixed size in the memory of a process that gives it random bytes, with no kernel entry and no call.

It is `random.Generator` (`src/library/modus/random`): ChaCha20 with fast key erasure, so a copy of its state after a draw does not give the bytes before it. `random.fill` draws bytes; `random.fill_for_a_key` draws a secret only above a least seed strength; `random.seed_for_a_child` seeds a child or a second thread. One generator belongs to one thread. It is not a kernel device and not a service: a kernel entry or a call for each draw costs too much on a hot path, and a shared pool is a shared state.

The design: `docs/RANDOMNESS.md`, "2. The generator".

Do not use: RNG, PRNG, CSPRNG (for this), /dev/urandom.

### Entropy report

The entropy report is the record of what the root service found when it gathered the seed of the system: which sources it read, how many of their values it took and refused, and the seed strength.

`random.Entropy_Report` holds the facts of `rdseed`, `rdrand` and the cycle counter. The root service writes it on the log, never the seed, and gives it to the process `randomness`, which shows it in its window. The report says what the sources gave. It does not estimate the entropy of the bytes: the system does not test the output of `rdseed` or `rdrand` for quality.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: entropy estimate.

### Seed strength

The seed strength is the strongest source that gave all its values to the seed of the system: `entropy` (rdseed), `processor` (rdrand) or `weak` (the cycle counter only).

The strength is what the system claims about its seed, and no more: `weak` claims 0 bits, because the system does not measure the jitter of the cycle counter. A child has the strength of its starter. A process states the least strength that it accepts with `random.fill_for_a_key`: QUIC and TLS ask for `processor`, so with a weak seed a handshake gives `Seed_Too_Weak`. The system never refuses for the process: each process still starts and draws. The entropy device adds bytes and no claim.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: security level.

### Entropy device

The entropy device is the random device of virtio that the machine can have (`virtio-rng-pci` in QEMU): one more source of the seed of the system, never the only one.

When the machine has it, the root service starts the entropy service and mixes its reads into its random generator with `random.device_bytes_mix`. The old key is always an input of the new one, so a hostile device cannot replace the bytes of the processor. A read that adds nothing counts as refused. The seed strength does not change. After the start, the root service reads it every 30 seconds for the fresh bytes refresh.

The design: `src/md/features/entropy_device.md`, and `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: RNG device, hardware RNG, /dev/random.

### Entropy service

The entropy service is the process `entropy`: the device service of the entropy device, with the root service as its one client.

It holds the registers, the interrupt and the queue of the device, and serves the entropy ring: one command `Read` gives a few bytes of the device. It does not test the bytes: the root service refuses a read that adds nothing. It is a process, not a part of the kernel, as each driver is.

The design: `src/md/features/entropy_device.md`.

Do not use: rng driver, entropy daemon.

### Entropy ring

The entropy ring is the ring between the entropy service and its one client, the root service: one command record is one read of the entropy device, and its completion record carries the bytes.

The root service makes it and gives it to the service in its context. The completion carries the bytes in its values, so the ring needs no region. An entropy ring is not a queue of the device: the device has its own queue, which only the entropy service sees.

The design: `src/md/features/entropy_device.md`.

Do not use: random ring.

### Fresh bytes page

The fresh bytes page is the page of one process, read-only at its fixed range, where the root service writes 32 bytes of its stream for that process alone after each fresh bytes refresh.

The random generator of the process reads the change count of the page at each refill and before a key or a child seed, and mixes a new change into its key once. A draw from the buffer reads no page. The page is not shared: a process that a reader took does not give the fresh bytes of the others. It is not a seed: the bytes only add to the key. A machine with no entropy device writes no page.

The design: `src/md/features/fresh_bytes.md`.

Do not use: entropy page, reseed page.

### Fresh bytes refresh

A fresh bytes refresh is one read of the entropy device that the root service mixes into its generator, then the write of the fresh bytes page of each process that has one.

The root service asks for one read every 30 seconds, with one read in flight at most. A read that adds nothing writes no page; after 3 in a row the root service asks for no more. A read that does not end by its deadline counts as refused, and the root service stops the entropy service (`RANDOMNESS.md`, "3. The seed of the system, and what is claimed"). A refresh wakes no process. It is not a reseed of each process at each draw: a process mixes the page at its next refill or key.

The design: `src/md/features/fresh_bytes.md`.

Do not use: reseed of a program, entropy refresh.

### Cryptography module

The cryptography module is the module `cryptography`: the cryptographic primitives that the system took from Odin's `core:crypto`, as exports that use the memory of the caller and give error records.

The system does not write cryptography from nothing: it takes proven code and changes only its shell, and `modustool cryptography-origin` proves each change. The module gives AEAD, SHA-256 with HMAC and HKDF, X25519, Ed25519, Argon2id and the masks of QUIC. It reads each byte of the caller once, erases its copies of a key, and draws no random byte: the caller passes each key and nonce. A module imports it by hash, and the console can call it.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: crypto library, libcrypto.

### Not authentic

Not authentic is the error kind of a sealed text whose tag does not verify, or of a message whose signature does not verify.

`Not_Authentic` (`src/library/modus/contract/errors`) tells a caller that the bytes are forged, damaged or from another key, and it is the one answer: the call says nothing about which byte was wrong. A failed open leaves no byte of the text in the result. A point of small order given to `x25519` is `Bad_Value`, not `Not_Authentic`: it shares no secret, but it is not a forged text.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: MAC failure, bad tag.

### Compatibility layer

The compatibility layer is the packages of `src/library/modus/cryptography` that give the code taken from Odin the helpers that it expects from its origin, over the primitives of this system.

The code of `core:crypto` imports helpers of the library of Odin. The system does not change that code: it changes only its import lines, so that they name the packages of the layer under the names of their origin. Those packages implement the helpers with the primitives of the system: the erase of a secret, for example, is one that the compiler cannot remove. A change of a file of the layer fails `modustool check` until its new hash is written.

The design: `docs/CRYPTOGRAPHY.md`, "3. The layout".

Do not use: shim, polyfill.
