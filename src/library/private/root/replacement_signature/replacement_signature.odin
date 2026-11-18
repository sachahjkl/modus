// The signature of a replacement row, and the decision of the root
// service on a replacement that a process asks for (docs/MODULE_CONTRACT.md,
// "Who may replace a module").
//
// The root service compiles it in: it imports no module. The tool signs
// the rows of the build with the procedures of
// replacement_signature_host.odin.
//
// See [replacement row](term:replacement-row).
package replacement_signature

import "base:runtime"
import "modus:contract/replacement_list"
import "modus:support/cryptography/ed25519"

// What the root service decides for one pair of modules in the scope
// System.
Decision :: enum u8 {
	Accepted       = 0, // A row of the pair verifies under the signing key of the system.
	No_List        = 1, // The boot image has no replacement list: no replacement is signed.
	List_Not_Valid = 2, // The list breaks its format: no row of it is read.
	No_Row         = 3, // No row of the list names the pair in the scope System.
	Not_Authentic  = 4, // The row of the pair does not verify under the signing key of the system.
}

// The words of each decision that refuses, after "refused the replacement
// of A by B: ".
@(rodata)
decision_sentences := [Decision]string {
	.Accepted       = "its row verifies under the signing key of the system",
	.No_List        = "the boot image has no replacement list, so no replacement is signed",
	.List_Not_Valid = "the replacement list of the boot image breaks its format",
	.No_Row         = "no signed row of the replacement list names it",
	.Not_Authentic  = "the signature of its row does not verify under the signing key of the system",
}

// row_verifies says if the signature of a row verifies under a public key,
// for the pair and the scope of the row. A public key that is not a point,
// or a point of small order, fails.
row_verifies :: #force_no_inline proc "contextless" (row: ^replacement_list.Row, public_key: [replacement_list.PUBLIC_KEY_SIZE]u8) -> bool {
	// The code of the origin needs a context; a zero one, as in the boot
	// program: it allocates nothing here.
	context = runtime.Context{}
	key: ed25519.Public_Key
	key_bytes := public_key
	if !ed25519.public_key_set_bytes(&key, key_bytes[:]) {
		return false
	}
	message := replacement_list.signed_message(row.from, row.to, row.scope, row.principal)
	signature := row.signature
	return ed25519.verify(&key, message[:], signature[:])
}

// system_decision decides on the replacement of the module `from` by the
// module `to` for each importer of the machine. list is the resource
// `replacement_list` of the boot image, or nil when it has none; system_key
// is the public key that verified the system description. problem says why
// a list is not valid.
system_decision :: proc "contextless" (list: []u8, from, to: [replacement_list.HASH_SIZE]u8, system_key: [replacement_list.PUBLIC_KEY_SIZE]u8) -> (decision: Decision, problem: replacement_list.List_Problem) {
	if list == nil {
		return .No_List, .None
	}
	list_rows: []replacement_list.Row
	list_rows, problem = replacement_list.rows(list)
	if problem != .None {
		return .List_Not_Valid, problem
	}
	row, found := replacement_list.row_find(list_rows, from, to, .System, 0)
	if !found {
		return .No_Row, .None
	}
	if !row_verifies(&row, system_key) {
		return .Not_Authentic, .None
	}
	return .Accepted, .None
}
