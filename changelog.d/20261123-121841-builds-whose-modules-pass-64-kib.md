type: Changed

**Builds whose modules pass 64 KiB**: the service `recipes` keeps each output in its private store by its hash, of up to 16 MiB, and removes its oldest realisations when its outputs would pass three quarters of its store. A C build makes the memory of its text and of its module of the size that the build needs, and the console reads a source by ranges, so `build` of a program of the size of Lua or SQLite gives its module.
