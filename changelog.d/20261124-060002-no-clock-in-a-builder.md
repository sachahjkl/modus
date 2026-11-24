type: Security

**No clock in a builder.** Sandboxed builder call hosts run with `Process_Flag.No_Clock` (heritable to child processes), omitting the time page mapping, trapping `rdtsc` and `rdtscp` with `#GP` through `CR4.TSD`, zeroing kernel entry return time, and disabling wall-clock deadlines so a builder cannot embed build time in its output.
