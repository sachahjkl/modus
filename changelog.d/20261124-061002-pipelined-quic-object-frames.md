type: Added

**Several frames of an object in flight.** The QUIC object cache client and `cache-serve` keep up to four 1 MiB object frame requests in flight on concurrent bidirectional QUIC streams, verifying every frame's Bao inclusion proof regardless of arrival order and committing atomically only once every frame verifies.
