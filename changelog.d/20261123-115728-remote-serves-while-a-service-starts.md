type: Fixed

**One service that starts slowly no longer holds every client of `remote`**: the connection to a service is now a state of the loop of `remote`, so the calls to the other services go on while one service starts, and a service that never answers ends its connection at the hang bound.
