type: Fixed

**A check of the share policy that the load of the host does not set.** `scheduler` now normalizes each process's accumulated ticks per virtual processor against that processor's busy ticks (`internal:scheduler/share_order`), so uneven host scheduling across cores does not skew the share-policy ordering check.
