type: Fixed

**One drawer at a time in the private glyph cache.** An atomic single-drawer guard in `text_rendering` refuses a second thread that draws or mutates the private glyph cache while another thread holds it, keeping the cache lists intact and writing one warning line on the log at the next frame.
