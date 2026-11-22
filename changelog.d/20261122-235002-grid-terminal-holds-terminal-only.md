type: Changed

**grid_terminal holds Terminal only.** In a console image with `grid_terminal`, the role Display has no holder, as with the two other renderers: a start or a connection of `display` is refused, and no caller reaches a module that does not fill the display contract. `grid_terminal` still gets the framebuffer and is the one screen writer.
