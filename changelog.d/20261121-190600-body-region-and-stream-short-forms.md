type: Added

**Body region contract and record stream short-form expansion**: added the fixed-layout `Body_Region_Header` and `Body_Reference` ring-buffer contract (`body_region_write`, `body_region_read`) in `modus:contract/output` with border validation for bounds, alignment, wrap generations, zero length, and serials; added pure wiring-list expansion and validation for `audit`, `audited`, `keep`, `merge`, and `collector.verify` in `internal:console/console_stream`; and refused `collector` service calls in mode `declaration`.
