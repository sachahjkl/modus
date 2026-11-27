type: Fixed

**Opening a window while recorded no longer races the compositor.** `display.open` now waits for the compositor to map the client display ring before mapping it in the client, so a recorded window process never blocks the compositor from opening its ring.
