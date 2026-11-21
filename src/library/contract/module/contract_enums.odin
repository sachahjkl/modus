package module

import "modus:contract/block"
import "modus:contract/call_status"
import "modus:contract/enum_word"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"

// The members of the contract enums that a field of the kind Status holds
// (value_kinds.Contract_Enum): their names, their words in a sentence, and
// the size of a field of each (docs/MODULE_CONTRACT.md, "The kind of a
// field"). The dispatch is in this package: it is the contract package
// that renders a fact, and it can import each contract package that
// declares a contract enum, its own Load_Stage, Error and Difference too.
// A contract package that imports this one cannot declare a contract enum.

// The name of each stage of a load, as Load_Stage names it.
@(rodata)
LOAD_STAGE_NAMES := [Load_Stage]string {
	.None  = "None",
	.Find  = "Find",
	.Read  = "Read",
	.Cycle = "Cycle",
	.Check = "Check",
	.Bind  = "Bind",
	.Map   = "Map",
	.Room  = "Room",
	.Unmap = "Unmap",
}

// The name of each error of a module file, as Error names it.
@(rodata)
ERROR_NAMES := [Error]string {
	.None               = "None",
	.Too_Small          = "Too_Small",
	.Bad_Magic          = "Bad_Magic",
	.Unknown_Version    = "Unknown_Version",
	.Unknown_Feature    = "Unknown_Feature",
	.Unknown_Machine    = "Unknown_Machine",
	.Bad_Table          = "Bad_Table",
	.Bad_Segment        = "Bad_Segment",
	.Bad_Rebase         = "Bad_Rebase",
	.Bad_Import_Slot           = "Bad_Import_Slot",
	.Bad_Import         = "Bad_Import",
	.Bad_Export         = "Bad_Export",
	.Bad_Own_Hash_Place = "Bad_Own_Hash_Place",
	.Bad_Record_Stream_Place = "Bad_Record_Stream_Place",
	.Too_Many_Record_Streams = "Too_Many_Record_Streams",
}

// The name of each difference of a replacement, as Difference names it.
@(rodata)
DIFFERENCE_NAMES := [Difference]string {
	.None                = "None",
	.Missing_Export      = "Missing_Export",
	.Parameter_Count     = "Parameter_Count",
	.Parameter_Type      = "Parameter_Type",
	.Parameter_Detail    = "Parameter_Detail",
	.Result_Type         = "Result_Type",
	.Result_Detail       = "Result_Detail",
	.Error_Record        = "Error_Record",
	.Parameter_Direction = "Parameter_Direction",
}

// The words of Load_Stage, Error and Difference in 8 bytes, for a record
// that holds them beside fields of 8 bytes with no padding.
Load_Stage_Word :: distinct u64
Error_Word :: distinct u64
Difference_Word :: distinct u64
#assert(size_of(Load_Stage_Word) >= size_of(Load_Stage) && size_of(Error_Word) >= size_of(Error) && size_of(Difference_Word) >= size_of(Difference))

// The bytes of each contract enum: the size of a field of the kind Status
// that holds it. None has no field.
@(rodata)
CONTRACT_ENUM_SIZES := [value_kinds.Contract_Enum]u32 {
	.None            = 0,
	.Status          = size_of(op.Status),
	.Log_Level       = size_of(op.Log_Level),
	.Log_Record_Form = size_of(op.Log_Record_Form),
	.Stop_Cause      = size_of(op.Stop_Cause),
	.Stop_Outcome    = size_of(op.Stop_Outcome),
	.Error_Kind      = size_of(errors.Kind),
	.Error_Unit      = size_of(errors.Unit),
	.Object_Kind     = size_of(op.Object_Kind),
	.Load_Stage      = size_of(Load_Stage),
	.Module_Error    = size_of(Error),
	.Load_Difference = size_of(Difference),
	.Block_Status    = size_of(block.Status),
	.Storage_Status  = size_of(storage_status.Status),
	.Call_Status     = size_of(call_status.Call_Status),
	.Pointer_Part    = size_of(pointer_pictures.Part),
	.Pointer_Field   = size_of(pointer_pictures.Field),
	.Pointer_Problem = size_of(pointer_pictures.Problem_Kind),
}

// The bytes of the word type of each contract enum
// (value_kinds.Contract_Enum_Type.word_name): 0 for an enum with none.
@(rodata)
CONTRACT_ENUM_WORD_SIZES := [value_kinds.Contract_Enum]u32 {
	.None            = 0,
	.Status          = size_of(op.Status_Word),
	.Log_Level       = 0,
	.Log_Record_Form = size_of(op.Log_Record_Form_Word),
	.Stop_Cause      = size_of(op.Stop_Cause_Word),
	.Stop_Outcome    = size_of(op.Stop_Outcome_Word),
	.Error_Kind      = size_of(errors.Kind_Word),
	.Error_Unit      = size_of(errors.Unit_Word),
	.Object_Kind     = size_of(op.Object_Kind_Word),
	.Load_Stage      = size_of(Load_Stage_Word),
	.Module_Error    = size_of(Error_Word),
	.Load_Difference = size_of(Difference_Word),
	.Block_Status    = size_of(block.Status_Word),
	.Storage_Status  = size_of(storage_status.Status_Word),
	.Call_Status     = size_of(call_status.Call_Status_Word),
	.Pointer_Part    = size_of(pointer_pictures.Part_Word),
	.Pointer_Field   = size_of(pointer_pictures.Field_Word),
	.Pointer_Problem = size_of(pointer_pictures.Problem_Kind_Word),
}

// contract_enum_member_count gives the count of the members of a contract
// enum, whose words are 0 up to the count: a reader that lists the members
// (the completion of a condition of the console) reads each one by
// contract_enum_member_name. None has no member.
contract_enum_member_count :: proc "contextless" (which: value_kinds.Contract_Enum) -> u64 {
	switch which {
	case .None:
		return 0
	case .Status:
		return u64(max(op.Status)) + 1
	case .Log_Level:
		return u64(max(op.Log_Level)) + 1
	case .Log_Record_Form:
		return u64(max(op.Log_Record_Form)) + 1
	case .Stop_Cause:
		return u64(max(op.Stop_Cause)) + 1
	case .Stop_Outcome:
		return u64(max(op.Stop_Outcome)) + 1
	case .Error_Kind:
		return u64(max(errors.Kind)) + 1
	case .Error_Unit:
		return u64(max(errors.Unit)) + 1
	case .Object_Kind:
		return u64(max(op.Object_Kind)) + 1
	case .Load_Stage:
		return u64(max(Load_Stage)) + 1
	case .Module_Error:
		return u64(max(Error)) + 1
	case .Load_Difference:
		return u64(max(Difference)) + 1
	case .Block_Status:
		return u64(max(block.Status)) + 1
	case .Storage_Status:
		return u64(max(storage_status.Status)) + 1
	case .Call_Status:
		return u64(max(call_status.Call_Status)) + 1
	case .Pointer_Part:
		return u64(max(pointer_pictures.Part)) + 1
	case .Pointer_Field:
		return u64(max(pointer_pictures.Field)) + 1
	case .Pointer_Problem:
		return u64(max(pointer_pictures.Problem_Kind)) + 1
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
		member := enum_word.member_of_word(op.Status, word) or_return
		return op.STATUS_NAMES[member], true
	case .Log_Level:
		member := enum_word.member_of_word(op.Log_Level, word) or_return
		return op.LOG_LEVEL_NAMES[member], true
	case .Log_Record_Form:
		member := enum_word.member_of_word(op.Log_Record_Form, word) or_return
		return op.LOG_RECORD_FORM_NAMES[member], true
	case .Stop_Cause:
		member := enum_word.member_of_word(op.Stop_Cause, word) or_return
		return op.STOP_CAUSE_NAMES[member], true
	case .Stop_Outcome:
		member := enum_word.member_of_word(op.Stop_Outcome, word) or_return
		return op.STOP_OUTCOME_NAMES[member], true
	case .Error_Kind:
		member := enum_word.member_of_word(errors.Kind, word) or_return
		return errors.KIND_NAMES[member], true
	case .Error_Unit:
		member := enum_word.member_of_word(errors.Unit, word) or_return
		return errors.UNIT_MEMBER_NAMES[member], true
	case .Object_Kind:
		member := enum_word.member_of_word(op.Object_Kind, word) or_return
		return op.OBJECT_KIND_MEMBER_NAMES[member], true
	case .Load_Stage:
		member := enum_word.member_of_word(Load_Stage, word) or_return
		return LOAD_STAGE_NAMES[member], true
	case .Module_Error:
		member := enum_word.member_of_word(Error, word) or_return
		return ERROR_NAMES[member], true
	case .Load_Difference:
		member := enum_word.member_of_word(Difference, word) or_return
		return DIFFERENCE_NAMES[member], true
	case .Block_Status:
		member := enum_word.member_of_word(block.Status, word) or_return
		return block.STATUS_NAMES[member], true
	case .Storage_Status:
		member := enum_word.member_of_word(storage_status.Status, word) or_return
		return storage_status.STATUS_NAMES[member], true
	case .Call_Status:
		member := enum_word.member_of_word(call_status.Call_Status, word) or_return
		return call_status.CALL_STATUS_NAMES[member], true
	case .Pointer_Part:
		member := enum_word.member_of_word(pointer_pictures.Part, word) or_return
		return pointer_pictures.PART_MEMBER_NAMES[member], true
	case .Pointer_Field:
		member := enum_word.member_of_word(pointer_pictures.Field, word) or_return
		return pointer_pictures.FIELD_MEMBER_NAMES[member], true
	case .Pointer_Problem:
		member := enum_word.member_of_word(pointer_pictures.Problem_Kind, word) or_return
		return pointer_pictures.PROBLEM_KIND_NAMES[member], true
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
	case .Stop_Cause:
		cause := enum_word.member_of_word(op.Stop_Cause, word) or_return
		return op.STOP_CAUSE_TEXTS[cause], true
	case .Stop_Outcome:
		outcome := enum_word.member_of_word(op.Stop_Outcome, word) or_return
		return op.STOP_OUTCOME_TEXTS[outcome], true
	case .None, .Status, .Log_Level, .Log_Record_Form, .Error_Kind, .Error_Unit, .Object_Kind, .Load_Stage, .Module_Error, .Load_Difference, .Block_Status, .Storage_Status, .Call_Status, .Pointer_Part, .Pointer_Field, .Pointer_Problem:
		return contract_enum_member_name(which, word)
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
