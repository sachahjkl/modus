type: Added

**Live compositor notifications, viewport magnifier zoom, supervision generation tracking, and console `roles()` command.** `compositor` now renders active desktop notification banners in the top-right corner, applies live 1.5x-8x viewport magnification inside `screen_copy`, and exports `notify(title, body)` and `magnifier(zoom_eighths)`; `root` advances role supervision generations when role holders stop; `console` adds the `roles()` built-in table command.
