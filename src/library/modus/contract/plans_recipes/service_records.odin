// The records that the exports of the services plans, recipes and projects
// take and give, and the borders that turn them into the records of this
// contract (src/md/features/declarations.md, "The services of the
// declarations"; src/md/features/recipes.md, "The builder").
//
// An export takes no slice by value and no address in a record, so a plan,
// a recipe and a pin cross the call as tables of fixed rows: a hash is a
// field of 32 bytes, a name is a Text (its bytes, then zeros), and each
// closed set travels as a word that the border turns into its enum.
package plans_recipes

import "modus:contract/blake3"
import "modus:contract/chosen_values"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes_status"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"

// The context string of the hash of the builder that the recipes service
// runs itself: the tree of the inputs of a recipe, by their names.
INPUTS_TREE_BUILDER_DOMAIN :: "modus builder inputs tree v1"

// The context string of the hash of the guest builder: a recipe with this
// builder runs its deterministic build in a sandboxed Linux guest.
GUEST_BUILDER_DOMAIN :: "modus builder guest linux v1"

// The prefix of the name of a module of the console of a project: Lex gives
// a module of the list `modules` as its hash only.
CONSOLE_MODULE_NAME_PREFIX :: "module_"

// The hexadecimal digits of the hash that the name of a console module keeps.
CONSOLE_MODULE_NAME_DIGITS :: 16

// One entry of a plan, as a row of the table that plans.difference and
// plans.apply take. A row is a record that a call carries, at most
// module.RECORD_SIZE_LIMIT bytes, so the text of a value of the kind Text
// takes one row for each PLAN_ROW_TEXT_BYTES of it: the rows of one text
// follow each other, with its name, its layer and the kind Text, and the
// number of the part in value_word, from 0 (plan_rows_of_entry). The border
// joins them into one entry (plan_of_rows).
Plan_Entry_Row :: struct {
	kind_word:            i64,
	role_word:            i64,
	start_grants_mask:    i64,
	store_rights_word:    i64,
	module_hash:          value_kinds.Hash_Field,
	interposed_over_hash: value_kinds.Hash_Field,
	recipe_hash:          value_kinds.Hash_Field,
	name:                 [64]u8,
	value_word:           i64, // A Value of the kind Word: the word of the field. Of the kind Text: the number of the part of the text in this row, from 0.
	value_layer_word:     i64, // A Value: Plan_Default (1) or Locked (3).
	value_kind_word:      i64, // A Value: Word (1) or Text (2) (chosen_values.Entry_Kind); 0 for another kind of entry.
	value_text:           [40]u8, // A Value of the kind Text: one part of its text, PLAN_ROW_TEXT_BYTES bytes but in its last part, then zero bytes.
}

// The bytes of the text of a value in one row.
PLAN_ROW_TEXT_BYTES :: 40
#assert(size_of(Plan_Entry_Row) == 256) // module.RECORD_SIZE_LIMIT: a call carries the row.
#assert(len(Plan_Entry_Row{}.value_text) == PLAN_ROW_TEXT_BYTES)
// The rows of the longest text.
PLAN_TEXT_ROWS_MOST :: (PLAN_VALUE_TEXT_BYTES + PLAN_ROW_TEXT_BYTES - 1) / PLAN_ROW_TEXT_BYTES
#assert(len(Plan_Entry_Row{}.name) == MAX_ENTRY_NAME_BYTES)

// Re-exported closed status enums and borders from plans_recipes_status.
Plan_Consent :: plans_recipes_status.Plan_Consent
Plan_Consent_Word :: plans_recipes_status.Plan_Consent_Word
Generation_Standing :: plans_recipes_status.Generation_Standing
Generation_Standing_Word :: plans_recipes_status.Generation_Standing_Word
plan_consent_of_word :: plans_recipes_status.plan_consent_of_word
generation_standing_of_word :: plans_recipes_status.generation_standing_of_word

// One row of a difference, as plans.difference gives it.
Plan_Diff_Row :: struct {
	change_word:           i64,
	entry_kind_word:       i64,
	role_word:             i64,
	added_grants_mask:     i64,
	removed_grants_mask:   i64,
	old_store_rights_word: i64,
	new_store_rights_word: i64,
	old_module_hash:       value_kinds.Hash_Field,
	new_module_hash:       value_kinds.Hash_Field,
	name:                  [64]u8,
	old_value_word:        i64, // A Value: the word before, 0 for an added one.
	new_value_word:        i64, // A Value: the word after, 0 for a removed one.
	old_value_layer_word:  i64,
	new_value_layer_word:  i64,
	new_value_kind_word:   i64, // A Value: the kind after, Word (1) or Text (2); 0 for a removed one. A text is not in the row: the trusted display shows it.
}

#assert(size_of(Plan_Diff_Row) == 224)

// The counts of a difference and the two plan hashes. An apply names
// current_plan_hash, so an apply of a difference that another apply made
// stale is refused.
Plan_Difference_Summary :: struct {
	change_count:       i64,
	added_roles:        i64,
	removed_roles:      i64,
	changed_roles:      i64,
	added_modules:      i64,
	removed_modules:    i64,
	changed_modules:    i64,
	added_stores:       i64,
	removed_stores:     i64,
	changed_stores:     i64,
	added_values:       i64,
	removed_values:     i64,
	changed_values:     i64,
	added_grants:       i64,
	removed_grants:     i64,
	consent:            plans_recipes_status.Plan_Consent,
	current_plan_hash:  value_kinds.Hash_Field,
	proposed_plan_hash: value_kinds.Hash_Field,
}

#assert(size_of(Plan_Difference_Summary) == 192)

// The hash of the current plan that an apply expects. Zero: the principal
// has no applied plan yet.
Plan_Expected :: struct {
	current_plan_hash: value_kinds.Hash_Field,
}

// One generation of the applied plans of a principal, as plans.generations,
// plans.apply and plans.rollback give it.
Plan_Generation_Row :: struct {
	generation:         i64,
	timestamp_ms:       i64,
	standing:           plans_recipes_status.Generation_Standing,
	plan_hash:          value_kinds.Hash_Field,
	previous_plan_hash: value_kinds.Hash_Field,
}

#assert(size_of(Plan_Generation_Row) == 88)

// The head of a recipe that recipes.register takes, beside its input table
// and its argument bytes.
Recipe_Head :: struct {
	output_kind:        plans_recipes_status.Recipe_Object_Kind_Word,
	source_date_unix:   i64,
	output_block_limit: i64,
	builder_hash:       value_kinds.Hash_Field,
}

#assert(size_of(Recipe_Head) == 56)

// One input of a recipe, as a row of the table that recipes.register takes.
Recipe_Input_Row :: struct {
	kind: plans_recipes_status.Recipe_Object_Kind_Word,
	hash: value_kinds.Hash_Field,
	name: [64]u8,
}

#assert(size_of(Recipe_Input_Row) == 104)

// The recipe that recipes.build and recipes.cache_lookup name: its hash.
Recipe_Reference :: struct {
	recipe_hash: value_kinds.Hash_Field,
}

// One build, as recipes.build and recipes.builds give it.
Recipe_Build_Row :: struct {
	outcome:     plans_recipes_status.Recipe_Build_Outcome_Word,
	refusal:     plans_recipes_status.Recipe_Refusal_Word,
	output_kind: plans_recipes_status.Recipe_Object_Kind_Word,
	mode:        plans_recipes_status.Build_Mode_Word,
	recipe_hash: value_kinds.Hash_Field,
	output_hash: value_kinds.Hash_Field,
}

#assert(size_of(Recipe_Build_Row) == 96)

// One realisation of the cache of the recipes service.
Realisation_Row :: struct {
	origin:            plans_recipes_status.Provenance_Origin_Word,
	output_kind:       plans_recipes_status.Recipe_Object_Kind_Word,
	recipe_hash:       value_kinds.Hash_Field,
	output_hash:       value_kinds.Hash_Field,
	signer_public_key: value_kinds.Hash_Field,
}

#assert(size_of(Realisation_Row) == 112)
#assert(object_cache.PUBLIC_KEY_SIZE == value_kinds.HASH_FIELD_BYTES)

// Summary row returned by recipes.publish after uploading a recipe's output
// closure bottom-up and its signed Realisation_Record to the QUIC cache.
Publish_Row :: struct {
	recipe_hash:       value_kinds.Hash_Field,
	output_hash:       value_kinds.Hash_Field,
	signer_public_key: value_kinds.Hash_Field,
	objects_uploaded:  u64,
	objects_skipped:   u64,
	bytes_uploaded:    u64,
}

#assert(size_of(Publish_Row) == 120)
#assert(offset_of(Publish_Row, objects_uploaded) == 96)
#assert(offset_of(Publish_Row, objects_skipped) == 104)
#assert(offset_of(Publish_Row, bytes_uploaded) == 112)

// One pin of a project, as projects.pins gives it.
Pin_Row :: struct {
	tree_hash:          value_kinds.Hash_Field,
	source_module_hash: value_kinds.Hash_Field,
	name:               [64]u8,
	upstream_ref:       [128]u8,
}

#assert(size_of(Pin_Row) == 256)
#assert(len(Pin_Row{}.upstream_ref) == MAX_UPSTREAM_REF_BYTES)

// The pin that projects.update moved, and the one line of pins.lex that
// changed: changed_lines is 0 when the pin already had the new hash.
Pin_Update_Row :: struct {
	changed_lines: i64,
	line_number:   i64,
	old_tree_hash: value_kinds.Hash_Field,
	new_tree_hash: value_kinds.Hash_Field,
}

#assert(size_of(Pin_Update_Row) == 80)

// The new tree hash of an input that projects.update takes.
Pin_Target :: struct {
	tree_hash: value_kinds.Hash_Field,
}

// text_field_length gives the length of a Text field: its bytes up to the
// first zero. ok is false when a byte after that zero is not zero, as a
// Text holds zeros past its length and a hidden tail would change no hash.
text_field_length :: proc "contextless" (field: []u8) -> (length: int, ok: bool) {
	length = len(field)
	for value, index in field {
		if value == 0 {
			length = index
			break
		}
	}
	for value in field[length:] {
		if value != 0 {
			return 0, false
		}
	}
	return length, true
}

// plan_of_rows is the border of a plan that an export takes: it fills out
// from rows for principal, then checks it whole with plan_validate. out
// holds the plan in its own memory: more entries than it holds are
// Too_Many_Entries. The rows of the parts of one text join into one entry.
// On a refusal, out is empty and keeps its memory.
plan_of_rows :: proc "contextless" (principal: u64, rows: []Plan_Entry_Row, out: ^Plan_Spec) -> (refusal: Plan_Refusal, bad_index: u32) {
	if out == nil {
		return .Buffer_Too_Small, 0
	}
	plan_clear(out)
	if len(rows) == 0 {
		return .Empty_Plan, 0
	}
	out.principal = principal
	for index in 0 ..< len(rows) {
		if row_refusal := plan_row_add(out, &rows[index]); row_refusal != .None {
			plan_clear(out)
			return row_refusal, u32(index)
		}
	}
	refusal, bad_index = plan_validate(out)
	if refusal != .None {
		plan_clear(out)
	}
	return refusal, bad_index
}

// plan_row_add adds one row to the plan that out holds: a new entry, or
// the next part of the text of the entry before it. A caller that reads
// its rows one at a time out of memory that another process can change
// (the region of a call) copies each row once and adds it; plan_validate
// then checks the plan whole. On a refusal, out is as it was before the
// row, and the caller clears it.
plan_row_add :: proc "contextless" (out: ^Plan_Spec, row: ^Plan_Entry_Row) -> Plan_Refusal {
	count := int(out.entry_count)
	length, text_ok := text_field_length(row.name[:])
	if !text_ok || length == 0 {
		return .Invalid_Name
	}
	// A part of a text: it follows the part before it, of the same name,
	// layer and kind, and the part before is whole.
	part_length, part_whole := text_field_length(row.value_text[:])
	is_text := row.kind_word == i64(Plan_Entry_Kind.Value) && row.value_kind_word == i64(chosen_values.Entry_Kind.Text)
	if !part_whole {
		return .Bad_Value
	}
	if is_text && row.value_word != 0 {
		before := count > 0 ? &out.entries[count - 1] : nil
		parts := before == nil ? 0 : (int(before.value_text_length) + PLAN_ROW_TEXT_BYTES - 1) / PLAN_ROW_TEXT_BYTES
		whole_before := before != nil && int(before.value_text_length) == parts * PLAN_ROW_TEXT_BYTES
		if before == nil || before.value_kind_word != u64(chosen_values.Entry_Kind.Text) || string(before.name_bytes[:before.name_length]) != string(row.name[:length]) || before.value_layer_word != u64(row.value_layer_word) || row.value_word != i64(parts) || !whole_before || part_length == 0 || int(before.value_text_length) + part_length > PLAN_VALUE_TEXT_BYTES {
			return .Bad_Value
		}
		copy(before.value_text[before.value_text_length:], row.value_text[:part_length])
		before.value_text_length += u16(part_length)
		return .None
	}
	// The memory of the plan holds its entries: one past it is refused at
	// its row.
	if count >= len(out.entries) || count >= len(out.order) || count >= int(PLAN_ENTRY_COUNT_LIMIT) {
		return .Too_Many_Entries
	}
	entry := &out.entries[count]
	entry^ = {}
	entry.kind_word = u64(row.kind_word)
	copy(entry.name_bytes[:length], row.name[:length])
	entry.name_length = u8(length)
	entry.role_word = u64(row.role_word)
	entry.module_hash = blake3.Hash(row.module_hash)
	entry.interposed_over_hash = blake3.Hash(row.interposed_over_hash)
	entry.recipe_hash = blake3.Hash(row.recipe_hash)
	entry.start_grants_mask = u64(row.start_grants_mask)
	entry.store_rights_word = u64(row.store_rights_word)
	entry.value_layer_word = u64(row.value_layer_word)
	entry.value_kind_word = u64(row.value_kind_word)
	// A text keeps the word 0; its first part is its first bytes.
	entry.value_word = is_text ? 0 : cast(u64)row.value_word
	copy(entry.value_text[:], row.value_text[:part_length])
	entry.value_text_length = u16(part_length)
	out.entry_count = u32(count + 1)
	return .None
}

// plan_rows_of_entry writes the rows of an entry, the form back of
// plan_of_rows: one row, or one for each part of a text. count is the rows
// written; 0 when out has no room for them.
plan_rows_of_entry :: proc "contextless" (entry: ^Plan_Entry, out: []Plan_Entry_Row) -> (count: int) {
	row: Plan_Entry_Row
	length := min(int(entry.name_length), MAX_ENTRY_NAME_BYTES)
	copy(row.name[:length], entry.name_bytes[:length])
	row.kind_word = i64(entry.kind_word)
	row.role_word = i64(entry.role_word)
	row.start_grants_mask = i64(entry.start_grants_mask)
	row.store_rights_word = i64(entry.store_rights_word)
	row.module_hash = value_kinds.Hash_Field(entry.module_hash)
	row.interposed_over_hash = value_kinds.Hash_Field(entry.interposed_over_hash)
	row.recipe_hash = value_kinds.Hash_Field(entry.recipe_hash)
	row.value_word = cast(i64)entry.value_word
	row.value_layer_word = i64(entry.value_layer_word)
	row.value_kind_word = i64(entry.value_kind_word)
	if entry.value_kind_word != u64(chosen_values.Entry_Kind.Text) {
		if len(out) < 1 {
			return 0
		}
		out[0] = row
		return 1
	}
	text := plan_value_text(entry)
	parts := max(1, (len(text) + PLAN_ROW_TEXT_BYTES - 1) / PLAN_ROW_TEXT_BYTES)
	if len(out) < parts {
		return 0
	}
	for part in 0 ..< parts {
		out[part] = row
		out[part].value_word = i64(part)
		start := part * PLAN_ROW_TEXT_BYTES
		copy(out[part].value_text[:], text[start:min(len(text), start + PLAN_ROW_TEXT_BYTES)])
	}
	return parts
}

// plan_diff_row_of_item gives the row of one item of a difference.
plan_diff_row_of_item :: proc "contextless" (item: ^Plan_Diff_Item) -> (row: Plan_Diff_Row) {
	length := min(int(item.name_length), MAX_ENTRY_NAME_BYTES)
	copy(row.name[:length], item.name_bytes[:length])
	row.change_word = i64(item.change)
	row.entry_kind_word = i64(item.entry_kind)
	row.role_word = i64(item.role)
	row.added_grants_mask = i64(item.added_grants_mask)
	row.removed_grants_mask = i64(item.removed_grants_mask)
	row.old_store_rights_word = i64(item.old_store_rights)
	row.new_store_rights_word = i64(item.new_store_rights)
	row.old_module_hash = value_kinds.Hash_Field(item.old_module_hash)
	row.new_module_hash = value_kinds.Hash_Field(item.new_module_hash)
	row.old_value_word, row.new_value_word = cast(i64)item.old_value_word, cast(i64)item.new_value_word
	row.old_value_layer_word, row.new_value_layer_word = i64(item.old_value_layer_word), i64(item.new_value_layer_word)
	row.new_value_kind_word = i64(item.new_value_kind_word)
	return row
}

// plan_difference_summary_of gives the counts and the hashes of a difference.
plan_difference_summary_of :: proc "contextless" (difference: ^Plan_Difference) -> Plan_Difference_Summary {
	consent := Plan_Consent.Not_Needed
	if difference.any_grant_added {
		consent = .Needed
	}
	return {
		change_count       = i64(difference.change_count),
		added_roles        = i64(difference.added_roles),
		removed_roles      = i64(difference.removed_roles),
		changed_roles      = i64(difference.changed_roles),
		added_modules      = i64(difference.added_modules),
		removed_modules    = i64(difference.removed_modules),
		changed_modules    = i64(difference.changed_modules),
		added_stores       = i64(difference.added_stores),
		removed_stores     = i64(difference.removed_stores),
		changed_stores     = i64(difference.changed_stores),
		added_values       = i64(difference.added_values),
		removed_values     = i64(difference.removed_values),
		changed_values     = i64(difference.changed_values),
		added_grants       = i64(difference.added_grants_count),
		removed_grants     = i64(difference.removed_grants_count),
		consent            = consent,
		current_plan_hash  = value_kinds.Hash_Field(difference.current_plan_hash),
		proposed_plan_hash = value_kinds.Hash_Field(difference.proposed_plan_hash),
	}
}

// plan_generation_row_of gives the row of one applied generation against the
// current generation of its principal.
plan_generation_row_of :: proc "contextless" (record: ^Applied_Plan_Record, current_generation: u64) -> Plan_Generation_Row {
	standing := Generation_Standing.Current
	if record.generation < current_generation {
		standing = .Earlier
	} else if record.generation > current_generation {
		standing = .Later
	}
	return {
		generation         = i64(min(record.generation, u64(max(i64)))),
		timestamp_ms       = i64(min(record.timestamp_ms, u64(max(i64)))),
		standing           = standing,
		plan_hash          = value_kinds.Hash_Field(record.plan_hash),
		previous_plan_hash = value_kinds.Hash_Field(record.previous_plan_hash),
	}
}

// recipe_spec_of_parts is the border of a recipe that recipes.register
// takes: it fills out from the head, the input rows and the argument bytes,
// then checks it whole with recipe_validate. On a refusal, out is zero.
recipe_spec_of_parts :: proc "contextless" (head: ^Recipe_Head, rows: []Recipe_Input_Row, arguments: []u8, out: ^Recipe_Spec) -> (refusal: Recipe_Refusal, bad_index: u32) {
	if out == nil || head == nil {
		return .Buffer_Too_Small, 0
	}
	out^ = {}
	if head.source_date_unix < 0 || head.output_block_limit < 0 {
		return .Bad_Head_Value, 0
	}
	if len(rows) > MAX_RECIPE_INPUTS {
		return .Too_Many_Inputs, 0
	}
	if len(arguments) > MAX_RECIPE_ARG_BYTES {
		return .Arguments_Too_Large, 0
	}
	out.builder_hash = blake3.Hash(head.builder_hash)
	output_kind, output_kind_ok := object_cache.cache_object_kind_of_word(u64(head.output_kind))
	if !output_kind_ok {
		out^ = {}
		return .Bad_Output_Kind, 0
	}
	out.output_kind = output_kind
	out.source_date_unix = u64(head.source_date_unix)
	out.output_block_limit = u64(head.output_block_limit)
	for index in 0 ..< len(rows) {
		row := &rows[index]
		length, text_ok := text_field_length(row.name[:])
		if !text_ok || length == 0 {
			out^ = {}
			return .Invalid_Input_Name, u32(index)
		}
		input_kind, input_kind_ok := object_cache.cache_object_kind_of_word(u64(row.kind))
		if !input_kind_ok {
			out^ = {}
			return .Bad_Input_Kind, u32(index)
		}
		input := &out.inputs[index]
		copy(input.name_bytes[:length], row.name[:length])
		input.name_length = u8(length)
		input.kind = input_kind
		input.hash = blake3.Hash(row.hash)
	}
	out.input_count = u32(len(rows))
	copy(out.arguments[:len(arguments)], arguments)
	out.arguments_length = u32(len(arguments))
	refusal, bad_index = recipe_validate(out)
	if refusal != .None {
		out^ = {}
	}
	return refusal, bad_index
}

// recipe_build_row_of gives the row of one build result.
recipe_build_row_of :: proc "contextless" (result: ^Recipe_Build_Result, mode: Build_Mode) -> Recipe_Build_Row {
	return {
		outcome     = Recipe_Build_Outcome_Word(result.outcome),
		refusal     = Recipe_Refusal_Word(result.refusal),
		output_kind = Recipe_Object_Kind_Word(result.output_kind),
		mode        = Build_Mode_Word(mode),
		recipe_hash = value_kinds.Hash_Field(result.recipe_hash),
		output_hash = value_kinds.Hash_Field(result.output_hash),
	}
}

// inputs_tree_builder_hash gives the builder hash of the inputs tree
// builder. It is no module: its output is a function of the input table only,
// so the recipes service builds it with no sandbox and no code of a caller.
inputs_tree_builder_hash :: proc "contextless" () -> blake3.Hash {
	return blake3.derive_key(INPUTS_TREE_BUILDER_DOMAIN, nil)
}

// guest_builder_hash gives the builder hash of the sandboxed Linux guest
// builder: a recipe with this builder packs its read-only inputs into a
// MODGBD1 input disk, boots a zero-network guest with frozen epoch time,
// checks exit status 0, unpacks the output disk, and returns its tree_hash.
guest_builder_hash :: proc "contextless" () -> blake3.Hash {
	return blake3.derive_key(GUEST_BUILDER_DOMAIN, nil)
}

// inputs_tree_build builds the output of the inputs tree builder: one tree
// whose entries are the inputs of the recipe, each under its name, a Blob as
// an object and a Tree as a tree. It takes no argument and gives a Tree only,
// so a recipe that asks for more is refused and not built in a way that
// nobody declared. output is unchanged on a refusal.
inputs_tree_build :: proc "contextless" (sandbox: ^Builder_Sandbox_Spec, output: []u8) -> (written: int, refusal: Recipe_Refusal) {
	if sandbox == nil {
		return 0, .Builder_Failed
	}
	if sandbox.builder_hash != inputs_tree_builder_hash() {
		return 0, .Builder_Needs_Sandbox
	}
	if sandbox.allow_network || sandbox.allow_root_ring || !sandbox.inputs_read_only || !sandbox.output_store_empty {
		return 0, .Sandbox_Violation
	}
	if sandbox.output_kind != .Tree || sandbox.arguments_length != 0 {
		return 0, .Sandbox_Violation
	}
	if sandbox.input_count > MAX_RECIPE_INPUTS {
		return 0, .Too_Many_Inputs
	}
	entries: [MAX_RECIPE_INPUTS]tree_hash.Tree_Entry
	for index in 0 ..< int(sandbox.input_count) {
		input := &sandbox.inputs[index]
		// A sandbox made by hand can hold the zero value, which names no kind.
		if _, kind_ok := object_cache.cache_object_kind_of_word(u64(input.kind)); !kind_ok {
			return 0, .Bad_Input_Kind
		}
		entry_kind := tree_hash.Tree_Entry_Kind.Object
		switch input.kind {
		case .Blob:
			entry_kind = .Object
		case .Tree:
			entry_kind = .Tree
		}
		entry, entry_refusal := tree_hash.tree_entry_make(entry_kind, string(input.name_bytes[:input.name_length]), input.hash)
		if entry_refusal != .None {
			return 0, .Invalid_Input_Name
		}
		entries[index] = entry
	}
	encoded, encode_refusal := tree_hash.tree_encode(entries[:sandbox.input_count], output)
	if encode_refusal != .None {
		return 0, .Malformed_Output
	}
	return encoded, .None
}

// realisation_row_of gives the row of one realisation and its origin word.
realisation_row_of :: proc "contextless" (record: ^object_cache.Realisation_Record, origin_word: u64) -> Realisation_Row {
	return {
		origin            = Provenance_Origin_Word(origin_word),
		output_kind       = Recipe_Object_Kind_Word(record.output_kind),
		recipe_hash       = value_kinds.Hash_Field(record.recipe_hash),
		output_hash       = value_kinds.Hash_Field(record.output_hash),
		signer_public_key = value_kinds.Hash_Field(record.signer_public_key),
	}
}

// pin_row_of_entry gives the row of one pin.
pin_row_of_entry :: proc "contextless" (pin: ^Pin_Entry) -> (row: Pin_Row) {
	name_length := min(int(pin.name_length), MAX_ENTRY_NAME_BYTES)
	reference_length := min(int(pin.upstream_ref_length), MAX_UPSTREAM_REF_BYTES)
	copy(row.name[:name_length], pin.name_bytes[:name_length])
	copy(row.upstream_ref[:reference_length], pin.upstream_ref_bytes[:reference_length])
	row.tree_hash = value_kinds.Hash_Field(pin.tree_hash)
	row.source_module_hash = value_kinds.Hash_Field(pin.source_module_hash)
	return row
}

// pins_lex_line_difference compares two forms of pins.lex line by line. It
// gives the count of lines that differ and, when that count is 1, the number
// of that line (from 1) and the line in each form, with no line end. Two forms
// with another count of lines differ in each line past the shorter.
pins_lex_line_difference :: proc "contextless" (old_text, new_text: []u8) -> (changed_lines: int, line_number: int, old_line, new_line: []u8) {
	old_rest, new_rest := old_text, new_text
	number := 0
	for len(old_rest) > 0 || len(new_rest) > 0 {
		number += 1
		old_current, old_after := line_split(old_rest)
		new_current, new_after := line_split(new_rest)
		if !bytes_equal(old_current, new_current) || (len(old_rest) == 0) != (len(new_rest) == 0) {
			changed_lines += 1
			if changed_lines == 1 {
				line_number, old_line, new_line = number, old_current, new_current
			}
		}
		old_rest, new_rest = old_after, new_after
	}
	if changed_lines != 1 {
		return changed_lines, 0, nil, nil
	}
	return changed_lines, line_number, old_line, new_line
}

@(private = "file")
line_split :: proc "contextless" (text: []u8) -> (line, rest: []u8) {
	for value, index in text {
		if value == '\n' {
			return text[:index], text[index + 1:]
		}
	}
	return text, nil
}

// project_declaration_of_evaluation is the border of the evaluation of a
// project.lex: the canonical output of the evaluation process
// (modus:contract/declaration_eval), whose value is a project. It keeps the
// field `source` as the tree of the project and the field `console` with
// its lists `modules` and `stores`, and skips each other field, which a
// later command reads. The name of the project comes from its tree, as Lex
// gives a project no name. On a refusal, out is zero.
project_declaration_of_evaluation :: proc "contextless" (name: []u8, evaluation: []u8, out: ^Project_Declaration) -> Project_Refusal {
	if out == nil {
		return .Buffer_Too_Small
	}
	out^ = {}
	if !lex_field_name_valid(name) {
		return .Unknown_Project
	}
	header, validate_refusal := declaration_eval.output_validate(evaluation)
	if validate_refusal != .None {
		return .Bad_Evaluation
	}
	if header.status != .Ok {
		return .Evaluation_Refused
	}
	refusal := project_declaration_read(evaluation, out)
	if refusal != .None {
		out^ = {}
		return refusal
	}
	copy(out.name_bytes[:len(name)], name)
	out.name_length = u8(len(name))
	return .None
}

@(private = "file")
project_declaration_read :: proc "contextless" (evaluation: []u8, out: ^Project_Declaration) -> Project_Refusal {
	_, reader, header_refusal := declaration_eval.output_read_header(evaluation)
	if header_refusal != .None {
		return .Bad_Evaluation
	}
	if tag, tag_refusal := declaration_eval.output_read_tag(&reader); tag_refusal != .None || tag != .Project {
		return .Not_A_Project
	}
	if tag, tag_refusal := declaration_eval.output_read_tag(&reader); tag_refusal != .None || tag != .Record {
		return .Not_A_Project
	}
	field_count, count_refusal := declaration_eval.output_read_u32(&reader)
	if count_refusal != .None {
		return .Bad_Evaluation
	}
	has_source := false
	for _ in 0 ..< field_count {
		field_name, name_refusal := declaration_eval.output_read_string(&reader)
		if name_refusal != .None {
			return .Bad_Evaluation
		}
		switch field_name {
		case "source":
			// The source is a tree, as here() gives it: a bare hash names
			// no kind (src/md/features/application_projects.md).
			tag, tag_refusal := declaration_eval.output_read_tag(&reader)
			if tag_refusal != .None || tag != .Tree_Ref {
				return .Missing_Field
			}
			source_hash, hash_refusal := declaration_eval.output_read_hash(&reader)
			if hash_refusal != .None {
				return .Bad_Evaluation
			}
			if hash_is_zero(source_hash) {
				return .Zero_Hash
			}
			out.project_tree_hash = source_hash
			has_source = true
		case "console":
			if refusal := project_console_read(&reader, out); refusal != .None {
				return refusal
			}
		case:
			if declaration_eval.output_skip_value(&reader, 2) != .None {
				return .Bad_Evaluation
			}
		}
	}
	if !has_source {
		return .Missing_Field
	}
	if reader.offset != len(evaluation) {
		return .Trailing_Tokens
	}
	return .None
}

@(private = "file")
project_console_read :: proc "contextless" (reader: ^declaration_eval.Output_Reader, out: ^Project_Declaration) -> Project_Refusal {
	if tag, tag_refusal := declaration_eval.output_read_tag(reader); tag_refusal != .None || tag != .Record {
		return .Empty_Console
	}
	field_count, count_refusal := declaration_eval.output_read_u32(reader)
	if count_refusal != .None {
		return .Bad_Evaluation
	}
	out.has_console_field = true
	for _ in 0 ..< field_count {
		field_name, name_refusal := declaration_eval.output_read_string(reader)
		if name_refusal != .None {
			return .Bad_Evaluation
		}
		switch field_name {
		case "modules":
			if refusal := console_modules_read(reader, out); refusal != .None {
				return refusal
			}
		case "stores":
			if refusal := console_stores_read(reader, out); refusal != .None {
				return refusal
			}
		case:
			return .Unknown_Field
		}
	}
	if out.console_module_count == 0 && out.console_store_count == 0 {
		return .Empty_Console
	}
	return .None
}

@(private = "file")
console_modules_read :: proc "contextless" (reader: ^declaration_eval.Output_Reader, out: ^Project_Declaration) -> Project_Refusal {
	if tag, tag_refusal := declaration_eval.output_read_tag(reader); tag_refusal != .None || tag != .List {
		return .Invalid_Module_Name
	}
	count, count_refusal := declaration_eval.output_read_u32(reader)
	if count_refusal != .None {
		return .Bad_Evaluation
	}
	if count > MAX_CONSOLE_MODULES {
		return .Too_Many_Modules
	}
	for index in 0 ..< int(count) {
		tag, tag_refusal := declaration_eval.output_read_tag(reader)
		// A module of the console is a module file: a bare hash names no
		// kind (src/md/features/application_projects.md).
		if tag_refusal != .None || tag != .Module_Ref {
			return .Invalid_Module_Name
		}
		module_hash, hash_refusal := declaration_eval.output_read_hash(reader)
		if hash_refusal != .None {
			return .Bad_Evaluation
		}
		name := console_module_name(module_hash)
		module, module_refusal := project_console_module_make(string(name[:]), module_hash)
		if module_refusal != .None {
			return module_refusal
		}
		for earlier in out.console_modules[:index] {
			if earlier.module_hash == module_hash {
				return .Duplicate_Module
			}
		}
		out.console_modules[index] = module
		out.console_module_count = u32(index + 1)
	}
	return .None
}

// console_module_name gives the name of a console module from its hash: Lex
// gives a module of a list as its hash only, and the console names its
// commands by a name.
console_module_name :: proc "contextless" (module_hash: blake3.Hash) -> (name: [len(CONSOLE_MODULE_NAME_PREFIX) + CONSOLE_MODULE_NAME_DIGITS]u8) {
	prefix := CONSOLE_MODULE_NAME_PREFIX
	copy(name[:len(prefix)], prefix)
	digits := "0123456789abcdef"
	for index in 0 ..< CONSOLE_MODULE_NAME_DIGITS / 2 {
		value := module_hash[index]
		name[len(prefix) + index * 2] = digits[value >> 4]
		name[len(prefix) + index * 2 + 1] = digits[value & 0x0F]
	}
	return name
}

@(private = "file")
console_stores_read :: proc "contextless" (reader: ^declaration_eval.Output_Reader, out: ^Project_Declaration) -> Project_Refusal {
	if tag, tag_refusal := declaration_eval.output_read_tag(reader); tag_refusal != .None || tag != .List {
		return .Invalid_Store_Name
	}
	count, count_refusal := declaration_eval.output_read_u32(reader)
	if count_refusal != .None {
		return .Bad_Evaluation
	}
	if count > MAX_CONSOLE_STORES {
		return .Too_Many_Stores
	}
	for index in 0 ..< int(count) {
		tag, tag_refusal := declaration_eval.output_read_tag(reader)
		if tag_refusal != .None || tag != .Store_Ref {
			return .Invalid_Store_Name
		}
		store_name, name_refusal := declaration_eval.output_read_string(reader)
		if name_refusal != .None {
			return .Bad_Evaluation
		}
		right_count, right_refusal := declaration_eval.output_read_u32(reader)
		if right_refusal != .None {
			return .Bad_Evaluation
		}
		reads, writes := false, false
		for _ in 0 ..< right_count {
			right, text_refusal := declaration_eval.output_read_string(reader)
			if text_refusal != .None {
				return .Bad_Evaluation
			}
			switch right {
			case "Read":
				if reads {
					return .Bad_Store_Rights
				}
				reads = true
			case "Write":
				if writes {
					return .Bad_Store_Rights
				}
				writes = true
			case:
				return .Bad_Store_Rights
			}
		}
		// A store that writes and does not read is no right of the plan.
		rights := Plan_Store_Rights.None
		if reads && writes {
			rights = .Read_Write
		} else if reads {
			rights = .Read_Only
		} else {
			return .Bad_Store_Rights
		}
		store, store_refusal := project_console_store_make(store_name, rights)
		if store_refusal != .None {
			return store_refusal
		}
		for &earlier in out.console_stores[:index] {
			if bytes_equal(earlier.name_bytes[:earlier.name_length], store.name_bytes[:store.name_length]) {
				return .Duplicate_Store
			}
		}
		out.console_stores[index] = store
		out.console_store_count = u32(index + 1)
	}
	return .None
}
