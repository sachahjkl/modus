type: Changed

**Delegated wiring service.** Record-stream wiring now runs in a separate `wiring` system service holding only attenuated grants (read-only boot image, `Spend`-only per-asker child wiring budgets, `Give`-only process tokens, and wiring rings) and consuming `Process_Stop_Notice` records from the root core's `stops` output. A fault in wiring validation or state stops `wiring` alone rather than the root service.
