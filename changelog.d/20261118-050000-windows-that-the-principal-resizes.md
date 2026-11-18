type: Added

**Windows that the principal resizes.** A program declares its window resizable with its least and largest size (`display.resizable_set`). The principal drags an edge or a corner, with the resize pointer shapes and an outline of the new frame. At the release the program gets the event `Resized`, makes the surface of the new size with its own budget (`display.surface_resize`) and draws its next frame in it; the compositor shows the old surface until that frame. A budget that cannot pay gives `No_Budget` and keeps the old size, with one line. `clock` is the first resizable window.
