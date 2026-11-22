type: Changed

**Resize grip rendered above resizable surfaces, live debugger replay checkpoints, and `tree_hash` console command.** Moved the bottom-right resize triangle grip into an overlay draw part above resizable client surfaces in `compositor`, wired `input_history` recording and reverse-step checkpoint lookup into `debugger`, and added the canonical `tree_hash(name, content)` built-in command to `console`.
