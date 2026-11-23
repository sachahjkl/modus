type: Changed

**The collector pays the memory of each space from its budget, and keeps room for a wide grant.** An audit space now takes its memory when it opens and gives it back when it closes, so a collector holds as many spaces as its budget pays, up to 16, not a fixed 8. The three act spaces of a wide grant always keep their room: a server audit that would take it is refused with the kind `Budget`. An image whose start lists declare more audits than the collector can hold is refused at build.
