type: Changed

**One QUIC server of the services.** `remote`, `remote_display`, and `quic_echo` now share one freestanding support package (`modus:quic_server`) for the datagram endpoint, held-command queue, validation tags, and QUIC server exchange loop, replacing three duplicated copies.
