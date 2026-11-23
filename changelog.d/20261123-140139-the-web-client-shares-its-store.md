type: Changed

**The cookies and the cache of the web client are shared between principals.** When their memory is full, each principal has a share of the entries and of the bytes of the bodies: a principal under its share takes the room of the one that holds the most, so no principal keeps the whole store while others ask for room. A caller can set a quota of bytes of bodies for each principal.
