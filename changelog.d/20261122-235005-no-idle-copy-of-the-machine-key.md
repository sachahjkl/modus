type: Security

**No idle copy of the key of the machine in remote.** The outbound links of `remote` copy the private key of the machine from the server only for the start of one connection, and erase that copy at once; no copy waits in the memory of the links.
