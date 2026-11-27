type: Added

**Software processor differential fuzzing and headless browser test part.** Added a native x86-64 differential fuzzer and instruction support probe for `software_machine` (fixing four hardware-semantics bugs in 32-bit `SHLD`/`SHRD` and IEEE-754 SSE flags), full boot-image instruction scanning across `console.image` and `boot.image`, and the `browser_machine` test part driving headless Chromium over a loopback HTTP server and WebSocket CDP client.
