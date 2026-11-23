type: Changed

**The store picker shows the stores of the principal**: the trusted store picker (`powerbox_pick_store`) reads the stores of the principal of its caller from the storage service, by pages through the powerbox, in place of a fixed list of four names. A pick is kept only when the powerbox finds that store at its place in its own copy of the list; a list that changed after the picker showed refuses the pick, and the principal asks again.
