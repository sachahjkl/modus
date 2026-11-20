package operation

import "modus:contract/enum_word"
import "modus:contract/errors"
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

// The name of each record form, as `Log_Record_Form` names it.
@(rodata)
LOG_RECORD_FORM_NAMES := [Log_Record_Form]string {
	.Text = "Text",
	.Fact = "Fact",
}

// The name of each stop cause, as `Stop_Cause` names it. A sentence writes
// the words of STOP_CAUSE_TEXTS in its place (contract_enum_member_words).
@(rodata)
STOP_CAUSE_NAMES := [Stop_Cause]string {
	.None              = "None",
	.Itself            = "Itself",
	.Holder            = "Holder",
	.Last_Thread_Ended = "Last_Thread_Ended",
	.Handles_Closed    = "Handles_Closed",
	.Fault             = "Fault",
	.Not_Committed     = "Not_Committed",
	.Cannot_Return     = "Cannot_Return",
	.Fault_Unanswered  = "Fault_Unanswered",
}

// The name of each stop outcome, as `Stop_Outcome` names it. A sentence
// writes the words of STOP_OUTCOME_TEXTS in its place
// (contract_enum_member_words).
@(rodata)
STOP_OUTCOME_NAMES := [Stop_Outcome]string {
	.None               = "None",
	.Done               = "Done",
	.Failed             = "Failed",
	.Refused            = "Refused",
	.Stopped_On_Request = "Stopped_On_Request",
}

// The bytes of each contract enum: the size of a field of the kind Status
// that holds it. None has no field.
@(rodata)
CONTRACT_ENUM_SIZES := [value_kinds.Contract_Enum]u32 {
	.None            = 0,
	.Status          = size_of(Status),
	.Log_Level       = size_of(Log_Level),
	.Log_Record_Form = size_of(Log_Record_Form),
	.Stop_Cause      = size_of(Stop_Cause),
	.Stop_Outcome    = size_of(Stop_Outcome),
	.Error_Kind      = size_of(errors.Kind),
	.Error_Unit      = size_of(errors.Unit),
}

// The word of a Status in 8 bytes: a field of a log fact or of a record
// that holds a status beside fields of 8 bytes, with no padding. A Status
// has 4 bytes, so a record of a status and a u64 has 4 bytes that no
// field covers, which the build refuses; this type covers them. A reader
// writes the name of the member, or the number of a word that names none.
//
// Example: `status: op.Status_Word` in a fact type, written with
// `op.Status_Word(status)`.
Status_Word :: distinct u64

// The bytes of the word type of each contract enum
// (value_kinds.Contract_Enum_Type.word_name): 0 for an enum with none.
@(rodata)
CONTRACT_ENUM_WORD_SIZES := [value_kinds.Contract_Enum]u32 {
	.None            = 0,
	.Status          = size_of(Status_Word),
	.Log_Level       = 0,
	.Log_Record_Form = 0,
	.Stop_Cause      = 0,
	.Stop_Outcome    = 0,
	.Error_Kind      = size_of(errors.Kind_Word),
	.Error_Unit      = size_of(errors.Unit_Word),
}

// A word type holds each word of its enum.
#assert(size_of(Status_Word) >= size_of(Status))
#assert(size_of(errors.Kind_Word) >= size_of(errors.Kind))
#assert(size_of(errors.Unit_Word) >= size_of(errors.Unit))

// contract_enum_member_count gives the count of the members of a contract
// enum, whose words are 0 up to the count: a reader that lists the members
// (the completion of a condition of the console) reads each one by
// contract_enum_member_name. None has no member.
contract_enum_member_count :: proc "contextless" (which: value_kinds.Contract_Enum) -> u64 {
	switch which {
	case .None:
		return 0
	case .Status:
		return u64(max(Status)) + 1
	case .Log_Level:
		return u64(max(Log_Level)) + 1
	case .Log_Record_Form:
		return u64(max(Log_Record_Form)) + 1
	case .Stop_Cause:
		return u64(max(Stop_Cause)) + 1
	case .Stop_Outcome:
		return u64(max(Stop_Outcome)) + 1
	case .Error_Kind:
		return u64(max(errors.Kind)) + 1
	case .Error_Unit:
		return u64(max(errors.Unit)) + 1
	}
	return 0
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
	case .Log_Record_Form:
		form := enum_word.member_of_word(Log_Record_Form, word) or_return
		return LOG_RECORD_FORM_NAMES[form], true
	case .Stop_Cause:
		cause := enum_word.member_of_word(Stop_Cause, word) or_return
		return STOP_CAUSE_NAMES[cause], true
	case .Stop_Outcome:
		outcome := enum_word.member_of_word(Stop_Outcome, word) or_return
		return STOP_OUTCOME_NAMES[outcome], true
	case .Error_Kind:
		kind := enum_word.member_of_word(errors.Kind, word) or_return
		return errors.KIND_NAMES[kind], true
	case .Error_Unit:
		unit := enum_word.member_of_word(errors.Unit, word) or_return
		return errors.UNIT_MEMBER_NAMES[unit], true
	}
	return "", false
}

// contract_enum_member_words gives the words of the member of a contract
// enum in a sentence: the sentence of a log fact writes them where its
// template names a field of the kind Status. They are the name of the
// member, but for the two enums of a stop, whose members a line has
// written with the words of a reader since before the facts ("itself,
// done", "a holder"): a fact template then writes the sentence of today. A
// column and a condition keep the name, which a principal types. ok is
// false as for contract_enum_member_name.
//
// Example: `contract_enum_member_words(.Stop_Outcome, 1)` is `"done", true`,
// and `contract_enum_member_words(.Log_Level, 2)` is `"Warning", true`.
contract_enum_member_words :: proc "contextless" (which: value_kinds.Contract_Enum, word: u64) -> (words: string, ok: bool) {
	switch which {
	case .None, .Status, .Log_Level, .Log_Record_Form, .Error_Kind, .Error_Unit:
		return contract_enum_member_name(which, word)
	case .Stop_Cause:
		cause := enum_word.member_of_word(Stop_Cause, word) or_return
		return STOP_CAUSE_TEXTS[cause], true
	case .Stop_Outcome:
		outcome := enum_word.member_of_word(Stop_Outcome, word) or_return
		return STOP_OUTCOME_TEXTS[outcome], true
	}
	return "", false
}

// contract_enum_member_of_name gives the word of the member of a contract
// enum that a name names, as contract_enum_member_name writes it. The name
// comes from a principal: ok is false for a name that names no member of
// that enum, for another case of the letters, and for None.
//
// Example: `contract_enum_member_of_name(.Log_Level, "Warning")` is `2,
// true`, and `contract_enum_member_of_name(.Log_Level, "warning")` is `0,
// false`.
contract_enum_member_of_name :: proc "contextless" (which: value_kinds.Contract_Enum, name: string) -> (word: u64, ok: bool) {
	for candidate in 0 ..< contract_enum_member_count(which) {
		if member, named := contract_enum_member_name(which, candidate); named && member == name {
			return candidate, true
		}
	}
	return 0, false
}
