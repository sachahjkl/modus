type: Fixed

**A machine with no screen.** A machine with no framebuffer, or whose compositor stopped, no longer ends its start on a failure that nobody sees: the root service writes `root: no screen: no console; remote calls still reach the system`, starts no input service, no compositor and no console, gives no process a window, refuses a process that needs a terminal, and starts `remote` itself, so a client key that a principal allowed before still calls the services.
