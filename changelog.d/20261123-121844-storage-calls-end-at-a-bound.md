type: Changed

**Storage calls end at a bound**: a call of the storage service that gets no answer in 120 seconds, twice the bound of the disk, ends with the status `No_Answer`, where the caller waited for ever. The next call waits for the late answer first, and the connection serves again when it came.
