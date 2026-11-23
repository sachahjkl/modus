type: Changed

**A version reads in pieces**: `storage.version(place, name, generation, offset)` gives the bytes of a version from an offset, so a version larger than the call region reads whole, piece by piece; the client procedure `storage.version` reads all the pieces into its result.
