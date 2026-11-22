type: Added

**An SSH client.** Added the freestanding zero-allocation `modus:ssh_client` package and `ssh_client` library module implementing RFC 4253/4252/4254 SSH-2 transport (`curve25519-sha256`, `ssh-ed25519` with strict `Known_Hosts` verification and no silent TOFU, `chacha20-poly1305@openssh.com`), Ed25519 public-key authentication, interactive session channels (`pty-req`, `shell`, `window-change`), and a bounded VT100/ANSI escape sequence parser.
