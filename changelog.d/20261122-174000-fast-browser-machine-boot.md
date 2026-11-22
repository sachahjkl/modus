type: Changed

**Browser machine fast boot (15.6x faster in Node 24 WebAssembly).** Added a 256-entry direct-mapped TLB, chunked page copy, instruction-fetch page cache, and bulk `rep movs`/`rep stos` fast paths in `software_machine`, plus a slim 7.9 MiB desktop `boot.image` in `modustool browser-machine`.
