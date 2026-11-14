type: Added

**The palette sets the scheduling strategy**: the palette has one entry for each scheduling strategy, "set strategy to eevdf", and the strategy that the machine uses says so. The console has the command `strategy(name)`, with `round_robin`, `fair` or `eevdf`: it calls the new export `strategy_set` of the program `scheduler`, which holds the right to change the strategy and must run. A press of the pointer in a field of the form of a command puts the caret there, and a press on a candidate takes it.
