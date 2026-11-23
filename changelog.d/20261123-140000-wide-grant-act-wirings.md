type: Added

**The rings of the act records wired by the root service at the grant.** A wide grant now holds only once its act records have a reader: the root service sends the grant to the collector of the principal, then wires the record outputs `acts` of `remote` and of the trusted display to it, and ends these wirings with the grant; `remote` writes a record before each call of a key under a grant, and refuses the call with `Busy` when the ring is full.
