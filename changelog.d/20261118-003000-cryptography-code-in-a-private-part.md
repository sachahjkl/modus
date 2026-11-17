type: Changed

**The code of the module cryptography is a private part of the library**: `modus:private/cryptography/cryptography_primitives` holds the code of each export but `argon2id`, and the module exports it with the same names, signatures and error records. The QUIC peers of the tool and the host tests of QUIC import that part, and the check of the imports refuses a relative import that lands in the folder of a module, from `src/` and from `tools/`.
