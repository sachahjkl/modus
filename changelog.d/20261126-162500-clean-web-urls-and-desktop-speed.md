type: Changed

**Clean `/console/` and `/desktop/` URLs and faster Web Desktop rendering.** The Web Console and Web Desktop now live at `/console/` and `/desktop/` instead of `.html` filenames. The WebAssembly worker now yields immediately on kernel idle with instant wake on input, coalesces high-frequency pointer moves without saturating PS/2 packets, and transfers only worker-converted dirty rectangles (`frame_seq` + damage bounds in `MODVRES1`) instead of scanning and swapping the full framebuffer on the UI thread.
