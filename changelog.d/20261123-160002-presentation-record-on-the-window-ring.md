type: Changed

**The presentation record on the window ring.** A window no longer maps the settings page of the machine: the compositor sends it the font, the order of the stripes, the grid fit, the appearance in force, the scale, the time zone and its first language in the display event `Presentation`, which replaces `Settings_Changed`, and the window keeps them on a page of its own. The pointer theme, the layout of the keyboard and the rest of the language list stay with the holders that use them.
