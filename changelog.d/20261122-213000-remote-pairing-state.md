type: Added

**Pairing state in the remote service**: `remote` now holds the state of pairing by a one-use code (CPace over Ristretto255, bound to the connection and to both machine identity keys), a bounded table of paired machines, the newest signed machine list with removal of each machine that a newer list drops, the check of signed grants (one day at most without a revocation list), and a store that keeps an object from a paired machine only when its bytes hash to the requested hash. The messages that carry a pairing between two machines are not built yet.
