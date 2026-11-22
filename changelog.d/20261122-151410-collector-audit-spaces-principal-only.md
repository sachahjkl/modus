type: Added

**The audit spaces of the collector, served to the principal only.** The collector refuses each view of a space to its source: the source cannot read its records, read its state with the new `space_stats`, find it in `spaces` or set its terms. `records_read` takes a limit of 1 to 64 records after a serial, and the new `act_records_read` gives the act records of a wide grant by grant and by a range of sequences. The counts and the chain check of the act records now refuse a caller that does not act for the principal.
