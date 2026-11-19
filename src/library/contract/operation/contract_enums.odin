package operation

import "modus:contract/enum_word"
import "modus:contract/value_kinds"

// The names of the members of the contract enums that a field of the kind
// Status holds (value_kinds.Contract_Enum): a reader writes the name of the
// member, with no copy of the names of the enumeration
// (docs/MODULE_CONTRACT.md, "The kind of a field").

// The name of each log level, as `Log_Level` names it.
@(rodata)
LOG_LEVEL_NAMES := [Log_Level]string {
	.Info    = "Info",
	.Debug   = "Debug",
	.Warning = "Warning",
	.Error   = "Error",
}

// The bytes of each contract enum: the size of a field of the kind Status
// that holds it. None has no field.
@(rodata)
CONTRACT_ENUM_SIZES := [value_kinds.Contract_Enum]u32 {
	.None      = 0,
	.Status    = size_of(Status),
	.Log_Level = size_of(Log_Level),
}

// contract_enum_member_name gives the name of the member of a contract enum
// that a word holds. The word comes from a record that another party
// wrote: ok is false for a word that names no member of that enum, and for
// None. The caller then writes the number, never a name.
//
// Example: `contract_enum_member_name(.Log_Level, 2)` is `"Warning", true`,
// and `contract_enum_member_name(.Log_Level, 4)` is `"", false`.
contract_enum_member_name :: proc "contextless" (which: value_kinds.Contract_Enum, word: u64) -> (name: string, ok: bool) {
	switch which {
	case .None:
		return "", false
	case .Status:
		status := enum_word.member_of_word(Status, word) or_return
		return STATUS_NAMES[status], true
	case .Log_Level:
		level := enum_word.member_of_word(Log_Level, word) or_return
		return LOG_LEVEL_NAMES[level], true
	}
	return "", false
}
