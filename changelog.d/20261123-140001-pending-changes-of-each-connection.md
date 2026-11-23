type: Changed

**Pending changes of each connection**: each connection that writes ranges has its own pool of pending changes, bounded by the limit of blocks of its store, in place of 1024 blocks and 16 objects shared by every connection; a connection that writes a large range takes no room of another, and its commit writes all of its changes in one commit, of any size. The new export `storage.drop_pending(place, name)` drops the pending changes of one object and keeps the others of the connection.
