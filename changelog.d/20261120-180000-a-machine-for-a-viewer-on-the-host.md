type: Added

**A machine for a viewer on the host**: `modustool run --remote-display <viewer key>` runs the machine with no window, starts `remote_display`, prints the port of the UDP relay of the peer to its port 7101 and the public key of the service, and allows the viewer key for the view and the input. The native viewer then connects with `viewertool machine <port> <key>`. The machine stops when the viewer has ended. The UDP relay of the peer now reaches any port of the machine that its start names.
