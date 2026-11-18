type: Fixed

**A disk that stops to answer.** A block request that the disk does not answer in 60 s fails, the block service stops with its line, and the storage service writes "storage: the disk does not answer" and refuses each call that needs the disk at once, so the console, `settings` and `unlock` get a refusal or `Gone` in place of a wait with no end.
