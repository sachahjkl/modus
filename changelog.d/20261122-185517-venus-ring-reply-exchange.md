type: Added

**The exchange of a Venus command and its reply through the ring.** `venus_vulkan` sends one command with the reply flag and its seek of the reply stream in one ring write, and reads the reply once the head of the renderer passes it, with `venus_ring_submit_command` and `venus_ring_poll_reply`. It refuses a full reply stream, a fatal ring and a reply that it already read, and the decoder of the physical device properties refuses a name that is not UTF-8. Host tests only: no process maps the memory of the device yet.
