# The connection identifier of QUIC

A connection identifier is 0 to 20 bytes (RFC 9000, section 17.2). The QUIC library holds it in packet headers, connection records, retry tokens and transport parameters. What the library does with it is in [`docs/QUIC.md`](../../../docs/QUIC.md), "5. The transport of one connection (the third layer, built)".

## Constraints

- A record must not hold a value that a writer loses or a reader cannot give back.
- An identifier comes from the network, from the generator of this side, or from a retry token.

## The chosen form

- One record, `Connection_Identifier`: an array of 20 bytes and a `u8` count. Two constructors make it: `connection_identifier_make` from bytes, which refuses more than 20, and `connection_identifier_of_chosen` from the 8 bytes that this side chose. Each leaves the bytes after the count at 0, so `==` of two records is the equality of the identifiers.
- An optional identifier of the transport parameters is a `Maybe(Connection_Identifier)`. Absent, it has no bytes and no count.
- So the writer of the transport parameters refuses no identifier: it refuses only a role that names the wrong parameters. `retry_token_make` has no refusal of a length.
- A required identifier that the reader did not see is found by the set of the parameters that it saw, not by a field of the record.

## Refused forms

- **An array and a separate length, with a `has_` field for an optional one.** It held a negative length, a length over 20, a byte after the length, and a length with its `has_` field false. Each writer refused them each time it ran.
- **A slice.** It names memory of another record, which a later packet can change.
- **Private fields.** The language has none. A record made by hand can still hold a count over 20; `connection_identifier_bytes` then stops the program on the check of the bounds of the slice, so such a record never reaches the network.

## State

Built: the record, its constructors and host tests, and each record of the library. Left: `initial_secrets`, `retry_integrity_tag` and `retry_packet_write` take slices and keep their refusal of more than 20 bytes.
