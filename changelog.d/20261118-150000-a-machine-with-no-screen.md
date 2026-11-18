type: Fixed

**A machine with no screen.** A machine with no screen at its start no longer ends its start on a failure that nobody sees: the root service writes `root: no screen: no console, no window; the other services start`, starts no input service, no compositor and no console, gives no process a window, refuses a process that needs a terminal, and starts the other services of the boot. An `unlock` that needs a typed key writes one line and stops. A compositor that stops later gives one line, refuses the later terminals, and starts nothing.
