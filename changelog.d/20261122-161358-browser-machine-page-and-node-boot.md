type: Added

**The kernel of a browser machine starts its root service from a page**: `modustool browser-machine` builds the kernel for WebAssembly, refuses a file whose imports and exports are not the border of the page, and writes a page that runs it in a worker, with the serial port, the PS/2 keyboard and mouse, the clock and a canvas of 1280 × 800. `modustool browser-machine boot` starts the same host in Node 24 and prints the serial port: the kernel reaches `kernel: ok` and runs the first thread of the root service on the software processor.
