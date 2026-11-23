type: Fixed

**A slow start no longer fails a correct connection**: the wait for the answer of the root service to a connection, and for a service or a call host to become ready, ends when that process stops, or at the hang bound of 60 s. It ended after 3 to 30 s before, which a loaded machine can pass while it starts a service.
