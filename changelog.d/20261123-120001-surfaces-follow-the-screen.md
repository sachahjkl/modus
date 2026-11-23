type: Changed

**A window follows the screen, not a side of 2048 logical pixels**: a window can be up to 8192 logical pixels on a side, and the compositor bounds each surface by the screen in force, at twice its longest side and never less than 4096 pixels of the screen. On a screen of 5120 × 2880 at the scale 1 a window wider than 2048 opens, and a surface past the screen is refused as `Past_Screen`.
