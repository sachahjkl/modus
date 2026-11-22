type: Added

**The wire borders of TLS and QUIC in the module `tls_tcp`.** The module now reads and writes the header of a TLS 1.3 record, reads and writes the variable-length integers of QUIC, and reads the form and the version of a QUIC packet header, over bytes and tables of the caller. Each refusal gives an error record and writes no byte: an unknown content type, a legacy version other than 0x0303, a record longer than 16 640 bytes, a negative integer or one over 2^62 - 1, and a short buffer.
