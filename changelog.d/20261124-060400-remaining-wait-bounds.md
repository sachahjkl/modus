type: Changed

**Each wait for another process ends at its stop or at the hang bound.** Replaced the remaining short fixed wait timeouts across the console (`request_record`, `disk_request`, `WIRE_ANSWER_LIMIT`, palette provider refresh and revoke wait), `debugger`, `remote` mesh handshakes and requests, `root` disk load cancel, `compositor` GPU scanout (with immediate fallback when `gpu_device` stops), and `quic_server` endpoint info waits with serving-process stop checks and the 60 s answer hang bound.
