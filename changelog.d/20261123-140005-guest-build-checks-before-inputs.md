type: Changed

**A guest build fits the budget of the service.** Each guest build sizes its buffers from its spec and from the memory that the budget of the service has left, so a smaller machine runs the guest builds that fit it; a build whose guest does not fit, or whose kernel or initial archive the store lacks, is refused before any input is read.
