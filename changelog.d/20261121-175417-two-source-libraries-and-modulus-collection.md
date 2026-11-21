type: Changed

**The two source libraries: the public library and the internal parts.** The repository now separates the public library `modus:` (`src/library/modus`, including `contract/` and `modus:cryptography_primitives`), the internal parts `internal:` (`src/library/internal`, refused by the compiler in the kernel and in outside modules), and the kernel source library `modulus:` (`src/modulus`), so each source library name matches its folder name.
