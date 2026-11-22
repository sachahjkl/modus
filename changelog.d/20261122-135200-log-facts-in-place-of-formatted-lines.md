type: Changed

**Log facts in place of formatted lines.** Every system service, demonstration, and output test module (including `root`, `wiring`, and the remaining output/wiring tests) now emits typed `log_fact` records verified by host fact-rendering tests, leaving raw text log calls only in tests that explicitly verify raw text log records.
