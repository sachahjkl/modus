type: Fixed

**A record that each reader refused counts as discarded, not as written**: when each reader of a record output had a full ring of the pace `Never_Holds_Writer`, the writer counted the record as `written` in `stream_counts`, though no reader received it. It now counts as `discarded`, as a record with no reader; each of those readers still reads a gap record with the count of the records that it missed.
