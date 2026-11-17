type: Changed

**An idle timeout that QUIC cannot carry is refused at the start**: `connection_start_client`, `connection_start_server` and `server_init` of `support/quic` give `Bad_Value` with the unit `Milliseconds` for an `idle_timeout_milliseconds` over 2^62 - 1, in place of a `Too_Long` of the transport parameters later. A record of transport parameters that the writer refuses is now `Bad_Value` too; `Too_Long` means only that the parameters do not fit.
