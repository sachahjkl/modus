// Closed status enums carried in the service records of plans and recipes
// (src/library/modus/contract/plans_recipes/service_records.odin).
//
// This package is a leaf contract package with no dependency on module, so
// module/contract_enums.odin can import it and map each member to its name for
// Status fields (value_kinds.Contract_Enum).
package plans_recipes_status

import "modus:contract/enum_word"

// Where a generation stands against the current generation of its principal.
// A rollback leaves the later generations: the next apply writes the
// generation after the highest one.
Generation_Standing :: enum u64 {
	None    = 0,
	Current = 1,
	Earlier = 2,
	Later   = 3,
}

Generation_Standing_Word :: distinct u64
#assert(size_of(Generation_Standing_Word) == 8 && size_of(Generation_Standing) == 8)

@(rodata)
GENERATION_STANDING_NAMES := [Generation_Standing]string {
	.None    = "None",
	.Current = "Current",
	.Earlier = "Earlier",
	.Later   = "Later",
}

// generation_standing_of_word is the border of the standing word of a
// generation row.
generation_standing_of_word :: proc "contextless" (word: u64) -> (standing: Generation_Standing, ok: bool) {
	member := enum_word.member_of_word(Generation_Standing, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Whether an apply of a difference needs the consent of the principal on the
// trusted display.
Plan_Consent :: enum u64 {
	None       = 0,
	Not_Needed = 1,
	Needed     = 2,
}

Plan_Consent_Word :: distinct u64
#assert(size_of(Plan_Consent_Word) == 8 && size_of(Plan_Consent) == 8)

@(rodata)
PLAN_CONSENT_NAMES := [Plan_Consent]string {
	.None       = "None",
	.Not_Needed = "Not_Needed",
	.Needed     = "Needed",
}

// plan_consent_of_word is the border of the consent word of a summary.
plan_consent_of_word :: proc "contextless" (word: u64) -> (consent: Plan_Consent, ok: bool) {
	member := enum_word.member_of_word(Plan_Consent, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Whether a recipe input or output is a Blob or a Tree. Values 1 and 2 match
// object_cache.Cache_Object_Kind identically; 0 means unset and is refused at
// the border.
Recipe_Object_Kind :: enum u8 {
	None = 0,
	Blob = 1,
	Tree = 2,
}

Recipe_Object_Kind_Word :: distinct u64
#assert(size_of(Recipe_Object_Kind_Word) == 8 && size_of(Recipe_Object_Kind) == 1)

@(rodata)
RECIPE_OBJECT_KIND_NAMES := [Recipe_Object_Kind]string {
	.None = "None",
	.Blob = "Blob",
	.Tree = "Tree",
}

// recipe_object_kind_of_word converts a transport word to Recipe_Object_Kind,
// refusing unknown values and None.
recipe_object_kind_of_word :: proc "contextless" (word: u64) -> (kind: Recipe_Object_Kind, ok: bool) {
	member := enum_word.member_of_word(Recipe_Object_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Closed set of recipe build modes (maps directly to object_cache.Substitution_Mode).
// Zero means unset and is refused at the border.
Build_Mode :: enum u8 {
	None         = 0,
	Prefer_Cache = 1,
	Build_Only   = 2,
	Cache_Only   = 3,
	Verify       = 4,
}

Build_Mode_Word :: distinct u64
#assert(size_of(Build_Mode_Word) == 8 && size_of(Build_Mode) == 1)

@(rodata)
BUILD_MODE_NAMES := [Build_Mode]string {
	.None         = "None",
	.Prefer_Cache = "Prefer_Cache",
	.Build_Only   = "Build_Only",
	.Cache_Only   = "Cache_Only",
	.Verify       = "Verify",
}

// Closed set of build result classifications returned by recipes.build.
Recipe_Build_Outcome :: enum u8 {
	None          = 0,
	From_Cache    = 1,
	Built_Locally = 2,
	Refused       = 3,
	Building      = 4, // A guest build runs on the build thread of the service: the history gives its end.
}

Recipe_Build_Outcome_Word :: distinct u64
#assert(size_of(Recipe_Build_Outcome_Word) == 8 && size_of(Recipe_Build_Outcome) == 1)

@(rodata)
RECIPE_BUILD_OUTCOME_NAMES := [Recipe_Build_Outcome]string {
	.None          = "None",
	.From_Cache    = "From_Cache",
	.Built_Locally = "Built_Locally",
	.Refused       = "Refused",
	.Building      = "Building",
}

// recipe_build_outcome_of_word converts a transport word to Recipe_Build_Outcome,
// refusing unknown values and None.
recipe_build_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Recipe_Build_Outcome, ok: bool) {
	member := enum_word.member_of_word(Recipe_Build_Outcome, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Closed set of provenance origins recorded in Realisation_Row.origin.
Provenance_Origin :: enum u8 {
	None         = 0,
	Local_Build  = 1,
	Remote_Cache = 2,
}

Provenance_Origin_Word :: distinct u64
#assert(size_of(Provenance_Origin_Word) == 8 && size_of(Provenance_Origin) == 1)

@(rodata)
PROVENANCE_ORIGIN_NAMES := [Provenance_Origin]string {
	.None         = "None",
	.Local_Build  = "Local_Build",
	.Remote_Cache = "Remote_Cache",
}

// provenance_origin_of_word converts a transport word to Provenance_Origin,
// refusing unknown values and None.
provenance_origin_of_word :: proc "contextless" (word: u64) -> (origin: Provenance_Origin, ok: bool) {
	member := enum_word.member_of_word(Provenance_Origin, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Closed set of refusal reasons for recipe validation, cache verification,
// and sandboxed builds.
Recipe_Refusal :: enum u8 {
	None                  = 0,
	Zero_Builder_Hash     = 1,
	Bad_Output_Kind       = 2,
	Bad_Build_Mode        = 3,
	Too_Many_Inputs       = 4,
	Invalid_Input_Name    = 5,
	Zero_Input_Hash       = 6,
	Duplicate_Input       = 7,
	Bad_Input_Kind        = 8,
	Arguments_Too_Large   = 9,
	Nonzero_Padding       = 10,
	Buffer_Too_Small      = 11,
	Cache_Miss            = 12,
	Untrusted_Realisation = 13,
	Hash_Mismatch         = 14,
	Bad_Signature         = 15,
	Malformed_Output      = 16,
	Builder_Failed        = 17,
	Verify_Disagreement   = 18,
	Sandbox_Violation     = 19,
	Store_Full            = 20,
	Bad_Head_Value        = 21,
	Unknown_Recipe        = 22,
	Recipe_Limit_Reached  = 23,
	Builder_Needs_Sandbox = 24,
	Store_Failed          = 25, // The private store did not take the realisation: nothing was recorded.
	Store_Damaged         = 26, // A realisation of the private store does not decode, or its output does not match its hash.
	Untyped_Hash          = 27, // The arguments of a recipe hold a bare hash: it names no kind, so it names no input.
	Nested_Input          = 28, // A tree or a module file below the first level of the arguments: its input would have no name.
	Not_A_Recipe          = 29, // The value is not a recipe, or its arguments are not a record.
	Damaged_Recipe        = 30, // The recipe does not decode, or its written hash is not the hash of its record.
	Unsupported_Argument  = 31, // An argument of a kind that a recipe does not take: a recipe, a follow, a store, a plan, a project, or a negative source_date.
	Builder_Absent        = 32, // No module of the boot image has the hash of the builder.
	Input_Absent          = 33, // An object of an input is not in the place of the objects of the service: no build gave it.
	Builder_Timed_Out     = 34, // The builder gave no answer within builder.BUILD_TIME_BOUND_MILLISECONDS: the service ended it.
	Input_Too_Large       = 35, // The inputs of one build hold more objects than builder.MAX_INPUT_OBJECTS, or a tree nested deeper than the bound.
	Output_Too_Large      = 36, // The output passes the size bound of the recipe.
	Builder_Busy          = 37, // The guest builds that the service holds are as many as it runs and queues: a build waits for room.
	Memory_Past_Bound     = 38, // The guest build needs more memory than the budget of the service has left.
	Put_Quota_Reached     = 39, // The principal put as many objects in the hour as a principal may keep while no recipe names them.
	Build_Cancelled       = 40, // The principal that queued the guest build cancelled it.
}

Recipe_Refusal_Word :: distinct u64
#assert(size_of(Recipe_Refusal_Word) == 8 && size_of(Recipe_Refusal) == 1)

@(rodata)
RECIPE_REFUSAL_NAMES := [Recipe_Refusal]string {
	.None                  = "None",
	.Zero_Builder_Hash     = "Zero_Builder_Hash",
	.Bad_Output_Kind       = "Bad_Output_Kind",
	.Bad_Build_Mode        = "Bad_Build_Mode",
	.Too_Many_Inputs       = "Too_Many_Inputs",
	.Invalid_Input_Name    = "Invalid_Input_Name",
	.Zero_Input_Hash       = "Zero_Input_Hash",
	.Duplicate_Input       = "Duplicate_Input",
	.Bad_Input_Kind        = "Bad_Input_Kind",
	.Arguments_Too_Large   = "Arguments_Too_Large",
	.Nonzero_Padding       = "Nonzero_Padding",
	.Buffer_Too_Small      = "Buffer_Too_Small",
	.Cache_Miss            = "Cache_Miss",
	.Untrusted_Realisation = "Untrusted_Realisation",
	.Hash_Mismatch         = "Hash_Mismatch",
	.Bad_Signature         = "Bad_Signature",
	.Malformed_Output      = "Malformed_Output",
	.Builder_Failed        = "Builder_Failed",
	.Verify_Disagreement   = "Verify_Disagreement",
	.Sandbox_Violation     = "Sandbox_Violation",
	.Store_Full            = "Store_Full",
	.Bad_Head_Value        = "Bad_Head_Value",
	.Unknown_Recipe        = "Unknown_Recipe",
	.Recipe_Limit_Reached  = "Recipe_Limit_Reached",
	.Builder_Needs_Sandbox = "Builder_Needs_Sandbox",
	.Store_Failed          = "Store_Failed",
	.Store_Damaged         = "Store_Damaged",
	.Untyped_Hash          = "Untyped_Hash",
	.Nested_Input          = "Nested_Input",
	.Not_A_Recipe          = "Not_A_Recipe",
	.Damaged_Recipe        = "Damaged_Recipe",
	.Unsupported_Argument  = "Unsupported_Argument",
	.Builder_Absent        = "Builder_Absent",
	.Input_Absent          = "Input_Absent",
	.Builder_Timed_Out     = "Builder_Timed_Out",
	.Input_Too_Large       = "Input_Too_Large",
	.Output_Too_Large      = "Output_Too_Large",
	.Builder_Busy          = "Builder_Busy",
	.Memory_Past_Bound     = "Memory_Past_Bound",
	.Put_Quota_Reached     = "Put_Quota_Reached",
	.Build_Cancelled       = "Build_Cancelled",
}

// recipe_refusal_of_word is the one border of a refusal word that crosses
// a call: the value found of an error record of the service recipes. A
// word that names no refusal is refused, and so is None, which is no
// refusal.
recipe_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Recipe_Refusal, ok: bool) {
	member := enum_word.member_of_word(Recipe_Refusal, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}
