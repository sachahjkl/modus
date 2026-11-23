type: Changed

**A fill and a large step of undo in paint no longer stall the window.** The fill paints runs of a row in one pass, with a stack of runs that grows in the budget, in place of a fill of pixels: a sky of 22.8 million pixels fills in about 19 ms, 69 ms before. A fill, and the step of undo of a change larger than 262 144 pixels, run on a worker thread: the status line gives their progress, the window stays responsive, and Escape cancels them and puts the picture back.
