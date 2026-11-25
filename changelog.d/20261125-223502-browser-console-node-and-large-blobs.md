type: Added

**Console image Node boot test on COM2 and chunked large blobs in the browser machine.** `modustool browser-machine console-boot` boots `console.image` on `modulus_kernel.wasm` in Node, sends a Lex command on COM2 once `dom_terminal` is ready, and verifies the JSON answer; `ObjectCacheBridge` now streams blobs past 16 MiB in aligned 1 MiB HTTP Range frames verified with BLAKE3 Bao proofs without buffering more than one frame in memory.
