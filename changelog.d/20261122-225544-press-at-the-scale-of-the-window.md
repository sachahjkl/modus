type: Fixed

**A press reaches the element under the pointer in every window**: the windows of `settings`, `address_space`, `interface_font` and `vector_glyphs` drew their frames with no scale while each press came in logical pixels, so at the scale 1.25 a press on `+15 min` in `settings` chose `dark`, and its content filled four fifths of its window. Each frame now takes the scale of its window, and `interface.window_frame_start` refuses at compile time a frame with no window.
