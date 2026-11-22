type: Changed

**Browser machine fast paths, `rep movs/stos` word forms, and slim desktop image.** Added a fetch page cache, chunked `mmu_read_bytes`/`mmu_write_bytes`, `rep movsw/d/q` and `rep stosw/d/q`, shadow stack reset on unwind, and a slim 14 MiB desktop `boot.image` in `modustool browser-machine`, reducing Node 24 WebAssembly boot from 56.1 s to 42.1 s (desktop) and 64.6 s to 46.7 s (`help()` via PS/2 IRQ 1 with 1,024,000/1,024,000 pixels drawn).
