type: Added

**Per-view independent zoom in `scale_factor`.** Added `View_Zoom` (`0.5x` to `4.0x` in eighths), `view_zoom_step`, `view_screen_pixel`, and `view_logical_pixel` to compose per-view zoom with the desktop scale factor in one exact rounding step, and recorded the design in `src/md/features/desktop_to_browser.md`.
