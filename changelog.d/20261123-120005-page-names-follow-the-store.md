type: Changed

**A page of the server has a name of up to 64 bytes**: the name of a page is the name of its object in the store, so `server.put` takes the 64 bytes of a name of the store, in place of 39.
