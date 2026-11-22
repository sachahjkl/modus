type: Fixed

**The web desktop reaches its first frame**: the root service hashes each file of the boot image once, at its image check, and its loads and the resources that it gives take the hash of the entry. The compositor stops each of its start measures after 2 ms. Before, the start of the desktop in a page passed the hang bound of the start policy, and the rescue start policy stopped it before its first frame.
