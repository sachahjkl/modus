type: Added

**Data evolution contract package (`data_evolution`).** A freestanding, zero-allocation contract package provides canonical stored type descriptions with reader-computed domain-separated BLAKE3 description hashes, the `MODTYPE1` self-describing typed object format with strict border validation, derived forward and backward migration planning and fail-closed execution, stated-loss accounting, and pre-flight rollback checks for 1.0 store evolution without forcing pre-1.0 stores into migrations yet.
