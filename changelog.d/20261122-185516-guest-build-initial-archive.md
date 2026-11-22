type: Added

**An initial archive in the spec of a guest build.** The spec of a guest build names a cpio initial archive by its BLAKE3 hash and its size, and the export `build` of `guest_builder` takes its bytes: the builder copies them to their place in the memory of the guest, checks the hash on that copy before the boot, and refuses a tampered, cut or oversized archive before the guest runs. A build can now run the `init` of its recipe with a kernel of Nixpkgs that carries none. The wire of the spec is version 2, 3240 bytes.
