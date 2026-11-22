// The rule of a nickname of a disk process that crosses a border of the
// core: the disk rows of principals and the name of a principal
// (src/md/api/root_service_split.md).
//
// This is a contract package: it imports base and contract packages only,
// allocates no memory, and calls no kernel operation.
package root_delegation

// Maximum length in bytes of a disk process nickname, matching the root ring
// transport bound.
NICKNAME_CAPACITY :: 23

// Why validate_nickname refused a nickname.
Nickname_Refusal :: enum u8 {
	None      = 0,
	Empty     = 1,
	Too_Long  = 2,
	Bad_Byte  = 3,
	Reserved  = 4,
}

// Reserved names that a disk process cannot claim as its nickname because they
// collide with system stores, grant tables, or privileged system parts.
@(private = "file", rodata)
reserved_disk_nicknames := [?]string {
	"module_files",
	"grant_table",
	"root",
	"wiring",
	"disk_processes",
	"principals",
	"devices",
	"powerbox",
	"collector",
	"plans",
	"recipes",
	"projects",
	"settings",
	"start_policy",
}

// validate_nickname checks that a disk process nickname is non-empty, within
// NICKNAME_CAPACITY, composed solely of ASCII letters, digits, '-', and '_',
// and does not collide with reserved system names.
validate_nickname :: proc "contextless" (name: string) -> Nickname_Refusal {
	if len(name) == 0 {
		return .Empty
	}
	if len(name) > NICKNAME_CAPACITY {
		return .Too_Long
	}
	for index in 0 ..< len(name) {
		ch := name[index]
		allowed := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'
		if !allowed {
			return .Bad_Byte
		}
	}
	for reserved in reserved_disk_nicknames {
		if name == reserved {
			return .Reserved
		}
	}
	return .None
}
