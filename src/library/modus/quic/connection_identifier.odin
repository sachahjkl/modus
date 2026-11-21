package quic

// A connection identifier: 0 to `CONNECTION_ID_LIMIT` bytes.
//
// A [connection identifier](term:connection-identifier) was an array and a separate length in each
// record, and three records added a `has_` field. That form held states with no meaning: a
// negative length, a length over 20, a byte after the length that is not 0, a length with its
// `has_` field false. A writer then had to refuse them each time it ran. This record is made by
// `connection_identifier_make` or `connection_identifier_of_chosen` only, so the bytes after the
// length are 0, and `==` of two records is the equality of the two identifiers. An optional
// identifier is a `Maybe(Connection_Identifier)`: an absent one has no bytes and no length.
//
// The language has no private field, so a hand-made record can still hold a `length` over
// `CONNECTION_ID_LIMIT`. `connection_identifier_bytes` slices the array with it, and the check of
// the bounds of the slice stops the process: such a record never reaches the network.
Connection_Identifier :: struct {
	bytes:  [CONNECTION_ID_LIMIT]u8, // The identifier is the first `length` bytes. Each byte after them is 0.
	length: u8, // 0 to `CONNECTION_ID_LIMIT`.
}

// connection_identifier_make gives the identifier of bytes. ok is false, and the identifier is
// empty, when the bytes are more than `CONNECTION_ID_LIMIT`: no identifier is ever cut.
connection_identifier_make :: proc "contextless" (bytes: []u8) -> (identifier: Connection_Identifier, ok: bool) {
	if len(bytes) > CONNECTION_ID_LIMIT {
		return {}, false
	}
	identifier.length = u8(copy(identifier.bytes[:], bytes))
	return identifier, true
}

// connection_identifier_of_chosen gives the identifier of the `CONNECTION_ID_SIZE` bytes that this
// side chose. It cannot fail: `CONNECTION_ID_SIZE` is under the limit.
connection_identifier_of_chosen :: proc "contextless" (chosen: [CONNECTION_ID_SIZE]u8) -> (identifier: Connection_Identifier) {
	#assert(CONNECTION_ID_SIZE <= CONNECTION_ID_LIMIT)
	for value, index in chosen {
		identifier.bytes[index] = value
	}
	identifier.length = CONNECTION_ID_SIZE
	return
}

// connection_identifier_bytes gives the bytes of an identifier: a slice of the record, which the
// caller keeps while it reads them.
connection_identifier_bytes :: proc "contextless" (identifier: ^Connection_Identifier) -> []u8 {
	return identifier.bytes[:identifier.length]
}
