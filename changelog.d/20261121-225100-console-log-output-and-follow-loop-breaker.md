type: Added

**Console `log` wiring and `log.follow` loop breaker**: the console supports naming a module's implicit `log` output in `wire(server.log, collector.sources)` and piping `log.follow |> where(level = Warning)`, protected by a self-feedback loop breaker that suppresses render echoing into the kernel log and excludes the console's own process slot by default.
