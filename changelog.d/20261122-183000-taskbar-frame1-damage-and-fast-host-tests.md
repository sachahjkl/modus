type: Changed

**Frame-1 taskbar plate redraw and faster multi-threaded tool host tests.** `compositor` now damages the bar immediately when a window opens or closes so its taskbar plate renders on frame 1, and `modustool` runs the heavy tool test suites (`build`, `site`, `machine`, `checks`) with 8 test threads (cutting `site` from 116 s to 32 s and `build` from 159 s to 103 s).
