type: Changed

**Remote and network for real use**: `remote` holds 32 clients at once and the client table 64 keys, 32 for one principal, which its disk grant table keeps across a restart (format 4: a table of an older format is refused); `remote_display` holds 8 viewers, its protocol takes screens up to 7680 × 4320 with the memory of the service and the bounds of a viewer frame from the screen in force; the network service holds 96 endpoints, 256 neighbors and a prefix length that it checks in place of a fixed /24; TCP scales its windows past 64 KiB (RFC 7323).
