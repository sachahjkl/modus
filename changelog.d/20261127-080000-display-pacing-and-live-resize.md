type: Changed

**Display-driven frame pacing and live window resize.** The compositor, terminal, and `plasma` no longer cap frames to hardcoded 16 ms or 33 ms timers; the compositor paces output by display readiness and VirtIO-GPU scanout completion, and dragging any window edge or corner resizes the window live with an enlarged grab zone (8 logical pixels outside each border, 16 pixels at each corner, and the top border outside titlebar buttons).
