// The replacement list (docs/MODULE_CONTRACT.md, "Who may replace a
// module"): the replacement rows that the key of a principal signed. Each
// row names the hash of the module that an import names, the hash of the
// module that a loader gives in its place, and the importer scope, with an
// Ed25519 signature over the three.
//
// The root service writes a replacement in the replacement table of the
// machine only for a row whose signature verifies under a key that it
// trusts for the scope of the row. The console names the two modules; it
// gives no row and no signature.
//
// The file, all numbers little-endian:
//
//   Header                     16 bytes
//   Row, header.row_count times, 136 bytes each
//
// and no other byte. The build writes it as the resource
// `replacement_list` of the boot image of each volume, and signs each row
// with the key that signs the system description of that volume.
//
// The parts:
//
// - `Header`, `Row`, `Scope`, `rows`, `List_Problem`: the file.
// - `signed_message`, `SIGNATURE_LABEL`: what a key signs for one row.
// - `row_find`: the row of one pair and one scope.
//
// The signature itself is `src/library/support/replacement_signature`: a
// contract package holds no cryptography.
//
// See [replacement row](term:replacement-row).
package replacement_list

MAGIC :: u64(0x5453494c4c504552) // The bytes "REPLLIST".
VERSION :: 1 // The version of the format. A reader refuses another.
// A bound for the reader: the replacement table of a machine holds 32
// replacements, and a list offers a few more pairs than it holds.
ROW_CAPACITY :: 64
HASH_SIZE :: 32 // The bytes of the BLAKE3 hash of a module file.
PUBLIC_KEY_SIZE :: 32 // The bytes of an Ed25519 public key.
SIGNATURE_SIZE :: 64 // The bytes of an Ed25519 signature.

// The name of the resource of the boot image that holds the list.
RESOURCE_NAME :: "replacement_list"

// The first 32 bytes of the signed message, with zero bytes after it. The
// signing key of the system also signs the system description: the label
// keeps a signature of one from being taken for the other.
SIGNATURE_LABEL :: "module replacement signature 1"
#assert(len(SIGNATURE_LABEL) < 32)
// The label (32 bytes), the old hash, the new hash, the scope (4 bytes) and
// its principal (4 bytes).
SIGNED_MESSAGE_SIZE :: 32 + 2 * HASH_SIZE + 8

// Which importers a row reaches, and so which key must sign it.
Scope :: enum u32 {
	None      = 0, // Not valid: the reader refuses it.
	System    = 1, // Each importer of the machine. The signing key of the system signs it.
	Principal = 2, // The programs of the session of one principal. The signing key of that principal signs it.
}

// The first 16 bytes of the list.
Header :: struct {
	magic:     u64, // `MAGIC`.
	version:   u32, // `VERSION`.
	row_count: u32, // The rows after the header: at most `ROW_CAPACITY`. 0 is a valid list.
}
#assert(size_of(Header) == 16)

// One replacement row: where an import names the module `from`, a loader
// gives the module `to`, for the importers of the scope. 136 bytes.
//
// Example: `{from = <hash of calendar>, to = <hash of calendar_fixed>,
// scope = .System, principal = 0, signature = <by the signing key of the
// system>}` lets the console ask for `replace("calendar",
// "calendar_fixed")`.
Row :: struct {
	from:      [HASH_SIZE]u8, // The hash that an import names.
	to:        [HASH_SIZE]u8, // The hash of the module that a loader gives in its place.
	scope:     Scope,
	principal: u32, // The number of the principal for the scope Principal (1 or more); 0 for the scope System.
	signature: [SIGNATURE_SIZE]u8, // Ed25519 over `signed_message(from, to, scope, principal)`.
}
#assert(size_of(Row) == 136)

// Why a reader refuses a list.
List_Problem :: enum u8 {
	None       = 0, // The list follows its format.
	Too_Small  = 1, // It has fewer bytes than a header.
	Magic      = 2, // It does not start with `MAGIC`.
	Version    = 3, // It has another version.
	Count      = 4, // It counts more rows than `ROW_CAPACITY`.
	Size       = 5, // Its size is not the header and its rows exactly.
	Scope      = 6, // A row has the scope None or a scope that the format does not know, or a principal that does not go with its scope.
	Same_Hash  = 7, // A row has a zero hash, or the same hash twice: a module does not replace itself.
	Repeated   = 8, // Two rows name the same pair in the same scope.
}

// The words of each problem, for a line of the log.
@(rodata)
list_problem_sentences := [List_Problem]string {
	.None      = "the replacement list follows its format",
	.Too_Small = "the replacement list is shorter than its header",
	.Magic     = "the replacement list does not start with its magic",
	.Version   = "the replacement list has another version",
	.Count     = "the replacement list counts more rows than its capacity",
	.Size      = "the size of the replacement list is not its header and its rows",
	.Scope     = "a row of the replacement list has a scope that is not valid",
	.Same_Hash = "a row of the replacement list has a zero hash or the same hash twice",
	.Repeated  = "two rows of the replacement list name the same pair in the same scope",
}

// rows gives the rows of a list, after it checked the whole format. The
// list stays where it is: the caller gives bytes that no other party can
// change while it reads them (the pages of the boot image, which no program
// writes), or a copy of them.
rows :: proc "contextless" (list: []u8) -> (result: []Row, problem: List_Problem) {
	if len(list) < size_of(Header) {
		return nil, .Too_Small
	}
	header := (^Header)(raw_data(list))^
	if header.magic != MAGIC {
		return nil, .Magic
	}
	if header.version != VERSION {
		return nil, .Version
	}
	if header.row_count > ROW_CAPACITY {
		return nil, .Count
	}
	if len(list) != size_of(Header) + int(header.row_count) * size_of(Row) {
		return nil, .Size
	}
	result = ([^]Row)(raw_data(list[size_of(Header):]))[:header.row_count]
	for &row, index in result {
		// A value of the file can be outside the enumeration: only the two
		// known scopes pass.
		#partial switch row.scope {
		case .System:
			if row.principal != 0 {
				return nil, .Scope
			}
		case .Principal:
			if row.principal == 0 {
				return nil, .Scope
			}
		case:
			return nil, .Scope
		}
		if row.from == {} || row.to == {} || row.from == row.to {
			return nil, .Same_Hash
		}
		// One row for one pair and one scope: the row that a reader
		// verifies is then the only one that can apply.
		for &earlier in result[:index] {
			if earlier.from == row.from && earlier.to == row.to && earlier.scope == row.scope && earlier.principal == row.principal {
				return nil, .Repeated
			}
		}
	}
	return result, .None
}

// row_find gives the row of one pair in one scope, from rows that `rows`
// gave.
row_find :: proc "contextless" (list: []Row, from, to: [HASH_SIZE]u8, scope: Scope, principal: u32) -> (row: Row, found: bool) {
	for &item in list {
		if item.from == from && item.to == to && item.scope == scope && item.principal == principal {
			return item, true
		}
	}
	return {}, false
}

// signed_message gives the bytes that a key signs for one row: the label,
// the old hash, the new hash, the scope and its principal. A signature of
// one row verifies for no other pair, direction or scope.
signed_message :: proc "contextless" (from, to: [HASH_SIZE]u8, scope: Scope, principal: u32) -> (message: [SIGNED_MESSAGE_SIZE]u8) {
	label := SIGNATURE_LABEL
	for index in 0 ..< len(label) {
		message[index] = label[index]
	}
	for index in 0 ..< HASH_SIZE {
		message[32 + index] = from[index]
		message[32 + HASH_SIZE + index] = to[index]
	}
	tail := 32 + 2 * HASH_SIZE
	for shift in 0 ..< 4 {
		message[tail + shift] = u8(u32(scope) >> uint(8 * shift))
		message[tail + 4 + shift] = u8(principal >> uint(8 * shift))
	}
	return
}
