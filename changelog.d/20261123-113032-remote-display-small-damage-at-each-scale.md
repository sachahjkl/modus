type: Fixed

**The measure of a small damage of the remote display at each scale.** `remote_display` and the machine test count a viewer frame as a small damage when it holds at most 1/64 of the screen. The bound was 64 by 64 pixels: at the scale 1.25 the clock of the bar gives viewer frames of 4824 pixels, so no frame counted, the service never wrote its measure line, and the test part `remote_display` failed at `small frames` while the viewer received one frame each second.
