type: Added

**A removal of an object larger than 1 GiB.** The storage service frees the blocks of a state too large for one commit in steps, through the removal queue of its store, so a principal removes a video of several GiB in one call; a loss of power loses no step.
