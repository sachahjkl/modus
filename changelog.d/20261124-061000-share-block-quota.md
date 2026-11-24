type: Added

**A limit of blocks for each share.** `storage.share` accepts a per-share block quota for writable shares that caps the share's own tree blocks and pending range buffers without thinning versions of the parent store, and `recipes` sets this quota on every builder's `"out"` share before starting the builder.
