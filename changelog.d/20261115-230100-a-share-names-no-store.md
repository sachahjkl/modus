type: Security

**A share of a tree no longer reaches the root of its store.** The holder of a share of one tree could call `storage.open_store` with the name of the store of its maker, get a place on the root of that store, and read and change the whole store. A share now names no store: `open_store` refuses it with `No_Grant`, unit `Acts_For_Principal`, as for any other store.
