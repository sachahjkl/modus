type: Added

**Module settings, with the browser.** A module that holds no role has settings in the same form as `settings` and the compositor, kept in its private store: `browser.set(home = "http://example.org/")` chooses the address that the browser opens at its start, 1 to 160 bytes that its address field takes, and `monitor.set(sample_interval = 1000)` the time between two pictures of the monitor, 250 ms to 5000 ms. Each has a getter, `reset` and `settings_state`, and a plan can give the default of the monitor or lock it.
