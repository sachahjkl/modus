package operation

// The names of the members of the contract enums of this package that a
// field of the kind Status holds (value_kinds.Contract_Enum), and their
// word types. A reader writes the name of a member with
// module.contract_enum_member_name, which reads these tables: the
// dispatch over each contract enum is in the package module, which can
// import each contract package that declares one (docs/MODULE_CONTRACT.md,
// "The kind of a field").

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
// the words of STOP_CAUSE_TEXTS in its place (module.contract_enum_member_words).
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
// (module.contract_enum_member_words).
@(rodata)
STOP_OUTCOME_NAMES := [Stop_Outcome]string {
	.None               = "None",
	.Done               = "Done",
	.Failed             = "Failed",
	.Refused            = "Refused",
	.Stopped_On_Request = "Stopped_On_Request",
}

// The name of each kind of object, as `Object_Kind` names it.
// OBJECT_KIND_NAMES gives the words of a sentence.
@(rodata)
OBJECT_KIND_MEMBER_NAMES := [Object_Kind]string {
	.None      = "None",
	.Memory    = "Memory",
	.Process   = "Process",
	.Interrupt = "Interrupt",
	.Ports     = "Ports",
	.Machine   = "Machine",
	.Thread    = "Thread",
	.Budget    = "Budget",
	.Log       = "Log",
}

// The word types of the contract enums of this package: each a distinct
// integer of 8 bytes, so that a record holds the enum beside fields of 8
// bytes with no padding, which the build refuses. A field of a word type
// is a Status of its enum: a reader writes the name of the member, or the
// number of a word that names none. A writer converts the member, as
// `call_outcome.Call_Outcome_Word(status)`.

// The word of a Stop_Cause: a Stop_Cause has 1 byte.
Stop_Cause_Word :: distinct u64
// The word of a Stop_Outcome: a Stop_Outcome has 1 byte.
Stop_Outcome_Word :: distinct u64
// The word of a Log_Record_Form: a Log_Record_Form has 1 byte.
Log_Record_Form_Word :: distinct u64
// The word of an Object_Kind: an Object_Kind has 1 byte.
Object_Kind_Word :: distinct u64

#assert(size_of(Stop_Cause_Word) >= size_of(Stop_Cause))
#assert(size_of(Stop_Outcome_Word) >= size_of(Stop_Outcome))
#assert(size_of(Log_Record_Form_Word) >= size_of(Log_Record_Form))
#assert(size_of(Object_Kind_Word) >= size_of(Object_Kind))
