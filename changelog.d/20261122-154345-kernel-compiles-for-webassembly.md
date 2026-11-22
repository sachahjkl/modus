type: Added

**The kernel compiles for WebAssembly.** The kernel builds for `freestanding_wasm64p32` from the same source as for x86-64: an architecture layer gives the instructions, the entries and the return to a process on the software processor, and its only imports are the procedures of the page. It is the base of a browser machine; it does not run modus in a page yet.
