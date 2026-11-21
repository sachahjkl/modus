type: Changed

**The SipHash of the tool from `core:crypto`.** Fact key calculation in `modustool` now calls `core:crypto/siphash` directly in place of its hand-rolled SipHash-2-4 implementation, producing identical fact keys.
