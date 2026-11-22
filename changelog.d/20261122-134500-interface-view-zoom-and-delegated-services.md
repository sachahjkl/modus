type: Added

**Built-in per-view zoom in `modus:interface` and live delegated service supervision in `root` and `console`.** `frame_begin` in `modus:interface` now handles independent per-view `Ctrl++`, `Ctrl+-`, and `Ctrl+0` zoom automatically; `root` tracks and supervises all 8 delegated services (`disk_processes`, `principals`, `devices`, `settings`, `powerbox`, `plans`, `recipes`, `projects`) on stop; and `console` adds the `delegated_services()` table command.
