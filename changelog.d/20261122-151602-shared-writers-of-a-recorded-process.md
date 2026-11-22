type: Added

**Shared writers of a recorded process.** A process that shares a page with Write with another process is recorded and replayed: the input history names each such mapping, and a replay maps private pages at the same address, so it needs no peer and reads, at each input point, the bytes that the peer wrote during the record. The machine test of the debugger records a process while another one writes their shared page each round, replays the history with no writer to the same end, and replays a copy with one changed byte to its first divergence.
