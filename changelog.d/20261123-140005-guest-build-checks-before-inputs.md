type: Changed

**A guest build checks its guest before its inputs.** A kernel or an initial archive that the store lacks gives `Cache_Miss`, and a guest larger than the budget of the service gives `Memory_Past_Bound`, before any input is read or packed. The memory of a guest build follows the budget of the service in place of a fixed 128 MiB.
