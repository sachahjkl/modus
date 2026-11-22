type: Added

**The audit spaces of the collector in its store.** The collector writes each record of an audit space into its private store, as audit segments of 16 records chained by their BLAKE3 hash, before it keeps or forwards that record; a record that the store refuses is neither kept nor forwarded. A start of the collector reads each audit space back, checks each audit segment and the chain between them, goes on with the next serial, and refuses each step with `Store_Damaged` when one byte of the store changed.
