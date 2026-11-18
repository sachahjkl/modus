#+build !freestanding
package replacement_signature

// The part of the tool: it signs a row and writes a list. Only a host
// holds a private key, so the programs of the system do not build it.

import "modus:contract/replacement_list"
import "modus:support/cryptography/ed25519"

// row_sign writes, in the row, the signature of its pair and its scope by
// a private key.
row_sign :: proc(row: ^replacement_list.Row, private_key: ^ed25519.Private_Key) {
	message := replacement_list.signed_message(row.from, row.to, row.scope, row.principal)
	ed25519.sign(private_key, message[:], row.signature[:])
}
