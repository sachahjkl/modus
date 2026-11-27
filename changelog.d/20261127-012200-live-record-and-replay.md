type: Added

**Live machine record and replay of the console, a window, and `rdrand`.** Test part `record_replay` records and replays a window process (`hall_of_fame`), a test-only planted `rdrand` module (`replay_rdrand_probe`) to its exact argument divergence, and the real `console` module with a typed line, exporting each kernel input history from guest memory and verifying it through `modustool replay`.
