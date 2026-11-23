type: Changed

**A stroke in paint no longer copies the whole picture, and a large undo no longer stalls the window.** The copy of a picture before a change takes the tiles of 64 × 64 pixels that the change writes, at their first write, in place of the whole picture at each press. The undo, the redo and the clear of a large picture run on the worker of the changes, with their progress in the status line, and Escape cancels them with the picture as before.
