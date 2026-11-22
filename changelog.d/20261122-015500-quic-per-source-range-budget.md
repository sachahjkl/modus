type: Security

**A budget for each source of a QUIC flood.** QUIC servers now enforce a per-IPv4-/24 admission token bucket and active handshake cap with fixed capacity and LRU eviction before performing connection cryptography, so a flood from one address range spends only that range's budget while clients from other ranges still connect immediately.
