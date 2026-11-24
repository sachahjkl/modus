package settings_process

// Dynamic module settings discovery and background service worker
// (src/md/features/module_settings.md and src/md/features/settings_window.md).
//
// Reads module descriptions from the boot image (`module.parameter_setting`,
// `module.enum_type`, `choices_export`, `instances_export`, `settings_state`)
// and exposes one card per discovered module alongside the four core cards.
// All cross-process calls (connect, settings_state, choices/instances tables,
// and set) execute on a dedicated worker thread so the interface loop never
// blocks.

import "base:intrinsics"
import "modus:contract/chosen_values"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

// Plan value: holds up to 8 discovered modules beside the 4 core sections
// (currently compositor, monitor, browser, leaving room for 5 more).
DISCOVERED_MODULE_CAPACITY :: 8
// Format property: matches module.PARAMETER_CAPACITY.
DISCOVERED_PARAM_CAPACITY :: module.PARAMETER_CAPACITY
// Plan value: up to 12 selectable values per discovered parameter (enum
// members, range stops, or open choices).
DISCOVERED_VALUE_CAPACITY :: 12
// Plan value: up to 8 instances from an instances_export table.
DISCOVERED_INSTANCE_CAPACITY :: 8
// Format property: matches module.NAME_CAPACITY / chosen_values.NAME_CAPACITY.
DISCOVERED_NAME_BYTES :: 32
// Plan value: display label of a value button or instance button.
DISCOVERED_LABEL_BYTES :: 32
// Plan value: explanatory caption line under a discovered parameter title.
DISCOVERED_CAPTION_BYTES :: 96
// Plan value: stack pages for the settings worker thread.
SETTINGS_WORKER_STACK_PAGES :: 16
// Plan value: buffer for table rows read from settings_state / choices / instances.
DISCOVERED_TABLE_BUFFER_BYTES :: 2048

// Control kind derived from a module export parameter's description.
Discovered_Param_Kind :: enum u8 {
	Enum      = 0, // Enum parameter: one button per member.
	Range     = 1, // Ranged Integer parameter: stops computed via module.range_stops.
	Choices   = 2, // Integer parameter with choices_export: buttons populated from the table export.
	Instances = 3, // First Integer parameter with instances_export: instance selector row.
	Text      = 4, // Bounded Text parameter (such as browser.home).
}

// One setting parameter discovered from a module's `set` export.
Discovered_Param :: struct {
	kind:              Discovered_Param_Kind,
	param_index:       int, // Index in the `set` export's parameters (0 ..< parameter_count).
	optional:          bool,
	name:              [DISCOVERED_NAME_BYTES]u8,
	name_length:       int,
	caption:           [DISCOVERED_CAPTION_BYTES]u8,
	caption_length:    int,
	range_least:       i64,
	range_most:        i64,
	choices_export:    u32,
	instances_export:  u32,
	value_count:       int,
	values:            [DISCOVERED_VALUE_CAPACITY]i64,
	value_labels:      [DISCOVERED_VALUE_CAPACITY][DISCOVERED_LABEL_BYTES]u8,
	value_label_lens:  [DISCOVERED_VALUE_CAPACITY]u8,
	current_value:     i64,
	current_known:     bool,
	layer:             chosen_values.Layer,
}

// One module discovered from the boot image that declares a `set` export with
// optional settings parameters.
Discovered_Module :: struct {
	name:                    [DISCOVERED_NAME_BYTES]u8,
	name_length:             int,
	title:                   [DISCOVERED_NAME_BYTES]u8, // Uppercase card heading.
	title_length:            int,
	file:                    []u8, // Read-only validated module bytes in the boot image.
	set_export:              u32,
	settings_state_export:   u32,
	param_count:             int,
	params:                  [DISCOVERED_PARAM_CAPACITY]Discovered_Param,
	has_instances:           bool,
	instance_param_index:    int, // Index in `params` of the .Instances entry.
	selected_instance_index: int, // Chosen index in params[instance_param_index].values.
	state_loaded:            bool,
}

// Collection of all discovered modules rendered alongside the core cards.
Discovered_Set :: struct {
	modules:      [DISCOVERED_MODULE_CAPACITY]Discovered_Module,
	module_count: int,
}

// Boxes allocated in the layout tree for one discovered parameter.
Discovered_Param_Boxes :: struct {
	title:       layout.Box_Index,
	explanation: layout.Box_Index,
	values:      [DISCOVERED_VALUE_CAPACITY]layout.Box_Index,
}

// Boxes allocated in the layout tree for one discovered module card.
Discovered_Card_Boxes :: struct {
	card:   layout.Box_Index,
	params: [DISCOVERED_PARAM_CAPACITY]Discovered_Param_Boxes,
}

// discovered_param_name returns the parameter name slice.
discovered_param_name :: proc "contextless" (param: ^Discovered_Param) -> string {
	return string(param.name[:min(param.name_length, DISCOVERED_NAME_BYTES)])
}

// discovered_param_caption returns the parameter caption slice.
discovered_param_caption :: proc "contextless" (param: ^Discovered_Param) -> string {
	return string(param.caption[:min(param.caption_length, DISCOVERED_CAPTION_BYTES)])
}

// discovered_value_label returns the display label of value index.
discovered_value_label :: proc "contextless" (param: ^Discovered_Param, index: int) -> string {
	if index < 0 || index >= param.value_count {
		return ""
	}
	return string(param.value_labels[index][:min(int(param.value_label_lens[index]), DISCOVERED_LABEL_BYTES)])
}

// discovered_module_name returns the module's canonical lowercase name.
discovered_module_name :: proc "contextless" (mod: ^Discovered_Module) -> string {
	return string(mod.name[:min(mod.name_length, DISCOVERED_NAME_BYTES)])
}

// discovered_module_title returns the module's uppercase card title.
discovered_module_title :: proc "contextless" (mod: ^Discovered_Module) -> string {
	return string(mod.title[:min(mod.title_length, DISCOVERED_NAME_BYTES)])
}

// write_signed_i64 formats a signed 64-bit integer into buf.
@(private = "file")
write_signed_i64 :: proc "contextless" (buf: []u8, value: i64) -> int {
	if len(buf) == 0 {
		return 0
	}
	digits: [24]u8
	place := len(digits)
	neg := value < 0
	mag := neg ? u64(-value) : u64(value)
	for mag > 0 || place == len(digits) {
		place -= 1
		digits[place] = u8('0' + mag % 10)
		mag /= 10
	}
	if neg {
		place -= 1
		digits[place] = '-'
	}
	return copy(buf, digits[place:])
}

// format_param_caption builds a concise single-line description of a
// discovered parameter from its kind, range, or export links.
@(private = "file")
format_param_caption :: proc "contextless" (param: ^Discovered_Param) {
	pos := 0
	put :: proc "contextless" (dst: []u8, pos: ^int, s: string) {
		pos^ += copy(dst[pos^:], s)
	}
	switch param.kind {
	case .Enum:
		put(param.caption[:], &pos, "Choose a value.")
	case .Range:
		put(param.caption[:], &pos, "Range ")
		pos += write_signed_i64(param.caption[pos:], param.range_least)
		put(param.caption[:], &pos, " to ")
		pos += write_signed_i64(param.caption[pos:], param.range_most)
		put(param.caption[:], &pos, ".")
	case .Choices:
		put(param.caption[:], &pos, "Choices reported by the module.")
	case .Instances:
		put(param.caption[:], &pos, "Instance to configure.")
	case .Text:
		put(param.caption[:], &pos, "Text, ")
		pos += write_signed_i64(param.caption[pos:], param.range_least)
		put(param.caption[:], &pos, " to ")
		pos += write_signed_i64(param.caption[pos:], param.range_most)
		put(param.caption[:], &pos, " bytes.")
	}
	param.caption_length = pos
}

@(rodata)
discovered_language_en := [1]string{"en"}

// module_settings_discover_file inspects one validated module binary and
// populates out if it declares a `set` export with optional parameters
// (Enum, ranged Integer, choices_export, instances_export, or bounded Text).
// Refuses invalid binaries or modules with no discoverable settings, leaving
// out zeroed.
module_settings_discover_file :: proc "contextless" (name: string, file: []u8, out: ^Discovered_Module) -> bool {
	out^ = {}
	if len(name) == 0 || len(name) > DISCOVERED_NAME_BYTES || len(file) == 0 {
		return false
	}
	if module.validate(file) != .None {
		return false
	}
	export_count := module.count(file, .Exports)
	set_export: u32 = 0
	set_fn: module.Function
	state_export: u32 = 0
	for idx in u32(1) ..< export_count {
		fn, ok := module.function(file, idx)
		if !ok {
			continue
		}
		fn_name := module.string_at(file, fn.name_offset, fn.name_count)
		if fn_name == "set" && fn.parameter_count > 0 {
			set_export = idx
			set_fn = fn
		} else if fn_name == "settings_state" && fn.parameter_count == 0 && fn.result == u8(module.Type.Table) {
			state_export = idx
		}
	}
	if set_export == 0 {
		return false
	}
	// Require at least one optional parameter so non-settings `set` exports
	// (such as set(index, value)) are not mistaken for module settings.
	has_optional := false
	pcount := min(int(set_fn.parameter_count), DISCOVERED_PARAM_CAPACITY)
	for p in 0 ..< pcount {
		if module.parameter_optional(set_fn, p) {
			has_optional = true
			break
		}
	}
	if !has_optional {
		return false
	}

	out.name_length = copy(out.name[:], name)
	for i in 0 ..< out.name_length {
		ch := out.name[i]
		if ch >= 'a' && ch <= 'z' {
			ch -= 'a' - 'A'
		} else if ch == '_' {
			ch = ' '
		}
		out.title[i] = ch
	}
	out.title_length = out.name_length
	out.file = file
	out.set_export = set_export
	out.settings_state_export = state_export

	for p in 0 ..< pcount {
		ptype, ptype_ok := module.function_parameter_type(set_fn, p)
		if !ptype_ok {
			continue
		}
		pname := module.string_at(file, set_fn.parameter_names[p], u32(set_fn.parameter_name_counts[p]))
		if len(pname) == 0 || len(pname) > DISCOVERED_NAME_BYTES {
			continue
		}
		setting, has_setting := module.parameter_setting(file, set_export, p)
		param := &out.params[out.param_count]
		param^ = {}
		param.param_index = p
		param.optional = module.parameter_optional(set_fn, p)
		param.name_length = copy(param.name[:], pname)
		recognized := false

		switch ptype {
		case .Enum:
			enum_idx, _ := module.enum_detail_of(set_fn.parameter_details[p])
			described, problem := module.enum_type(file, enum_idx)
			if problem == .None && described.member_count > 0 {
				param.kind = .Enum
				limit := min(int(described.member_count), DISCOVERED_VALUE_CAPACITY)
				for m in 0 ..< limit {
					member, m_ok := module.enum_member(file, described, u32(m))
					if !m_ok {
						continue
					}
					display_text := module.member_display_text(file, enum_idx, described, u32(m), discovered_language_en[:])
					if len(display_text) == 0 || len(display_text) > DISCOVERED_LABEL_BYTES {
						continue
					}
					vi := param.value_count
					param.values[vi] = member.value
					param.value_label_lens[vi] = u8(copy(param.value_labels[vi][:], display_text))
					param.value_count += 1
				}
				recognized = param.value_count > 0
			}
		case .Integer:
			if has_setting {
				if p == 0 && setting.instances_export != 0 {
					param.kind = .Instances
					param.instances_export = setting.instances_export
					out.has_instances = true
					out.instance_param_index = out.param_count
					recognized = true
				} else if setting.choices_export != 0 {
					param.kind = .Choices
					param.choices_export = setting.choices_export
					recognized = true
				} else if module.parameter_setting_ranged(setting) {
					param.kind = .Range
					param.range_least = setting.least
					param.range_most = setting.most
					stops: [module.RANGE_STOP_CAPACITY]i64
					stop_count := module.range_stops(setting.least, setting.most, stops[:])
					for i in 0 ..< min(stop_count, DISCOVERED_VALUE_CAPACITY) {
						param.values[i] = stops[i]
						param.value_label_lens[i] = u8(write_signed_i64(param.value_labels[i][:], stops[i]))
						param.value_count += 1
					}
					recognized = param.value_count > 0
				}
			}
		case .Text:
			if has_setting && module.parameter_setting_ranged(setting) {
				param.kind = .Text
				param.range_least = setting.least
				param.range_most = setting.most
				recognized = true
			}
		case .None, .Record, .Handle, .Table, .Bytes:
		}
		if recognized {
			format_param_caption(param)
			out.param_count += 1
		}
	}
	if out.param_count == 0 {
		out^ = {}
		return false
	}
	return true
}

// discovered_table_choices_decode decodes a Table export (choices_export or
// instances_export) into param.values and param.value_labels. Reads the first
// Integer field as identity and the first Text field as display label (falling
// back to decimal identity when no Text field exists).
discovered_table_choices_decode :: proc "contextless" (file: []u8, table_export: u32, row_bytes: []u8, row_count: int, param: ^Discovered_Param) -> int {
	if table_export == 0 || row_count <= 0 || len(row_bytes) == 0 {
		return 0
	}
	fn, fn_ok := module.function(file, table_export)
	if !fn_ok || fn.result != u8(module.Type.Table) {
		return 0
	}
	rec, rec_ok := module.record_type(file, fn.result_detail)
	if !rec_ok || rec.size == 0 {
		return 0
	}
	id_field: module.Field
	has_id := false
	label_field: module.Field
	has_label := false
	for idx in 0 ..< rec.field_count {
		f, f_ok := module.field(file, rec, idx)
		if !f_ok {
			continue
		}
		if !has_id && f.type == u8(module.Type.Integer) {
			id_field = f
			has_id = true
		} else if !has_label && f.type == u8(module.Type.Text) {
			label_field = f
			has_label = true
		}
	}
	if !has_id {
		return 0
	}
	row_size := int(rec.size)
	max_rows := min(row_count, len(row_bytes) / row_size)
	cap_limit := param.kind == .Instances ? DISCOVERED_INSTANCE_CAPACITY : DISCOVERED_VALUE_CAPACITY
	count := 0
	for i in 0 ..< min(max_rows, cap_limit) {
		row := row_bytes[i * row_size:][:row_size]
		id := module.field_integer(row, id_field)
		param.values[count] = id
		if has_label {
			txt := module.field_text(row, label_field)
			if len(txt) > 0 && len(txt) <= DISCOVERED_LABEL_BYTES && text_encoding.display_text_valid(transmute([]u8)txt) {
				param.value_label_lens[count] = u8(copy(param.value_labels[count][:], txt))
				count += 1
				continue
			}
		}
		param.value_label_lens[count] = u8(write_signed_i64(param.value_labels[count][:], id))
		count += 1
	}
	param.value_count = count
	return count
}

// discovered_state_apply applies rows returned by a module's `settings_state`
// export (records with Integer fields `layer` and `value`, and optional
// `setting`) to mod's parameters. Refuses unknown layer words cleanly.
discovered_state_apply :: proc "contextless" (mod: ^Discovered_Module, row_bytes: []u8, row_count: int) -> bool {
	if mod.settings_state_export == 0 || row_count <= 0 || len(row_bytes) == 0 {
		return false
	}
	fn, fn_ok := module.function(mod.file, mod.settings_state_export)
	if !fn_ok || fn.result != u8(module.Type.Table) {
		return false
	}
	rec, rec_ok := module.record_type(mod.file, fn.result_detail)
	if !rec_ok || rec.size == 0 {
		return false
	}
	layer_field, value_field: module.Field
	has_layer, has_value := false, false
	for idx in 0 ..< rec.field_count {
		f, f_ok := module.field(mod.file, rec, idx)
		if !f_ok || f.type != u8(module.Type.Integer) {
			continue
		}
		fname := module.string_at(mod.file, f.name_offset, f.name_count)
		if fname == "layer" {
			layer_field = f
			has_layer = true
		} else if fname == "value" {
			value_field = f
			has_value = true
		}
	}
	if !has_layer || !has_value {
		return false
	}
	row_size := int(rec.size)
	max_rows := min(row_count, len(row_bytes) / row_size)
	// Map each row in order to non-instance parameters of mod.
	row_idx := 0
	applied := false
	for p in 0 ..< mod.param_count {
		if mod.params[p].kind == .Instances {
			continue
		}
		if row_idx >= max_rows {
			break
		}
		row := row_bytes[row_idx * row_size:][:row_size]
		layer_raw := module.field_integer(row, layer_field)
		if layer_raw < 0 {
			return false
		}
		layer, layer_ok := enum_word.member_of_word(chosen_values.Layer, u64(layer_raw))
		if !layer_ok {
			return false
		}
		val := module.field_integer(row, value_field)
		mod.params[p].layer = layer
		mod.params[p].current_value = val
		mod.params[p].current_known = true
		applied = true
		row_idx += 1
	}
	if applied {
		mod.state_loaded = true
	}
	return applied
}

// discovered_set_arguments_build encodes the isolated.Argument slice for
// calling mod.set_export with one target parameter set to value (and the
// selected instance id when mod has an instances parameter).
discovered_set_arguments_build :: proc "contextless" (mod: ^Discovered_Module, target_param_index: int, value: i64, out: []isolated.Argument) -> (count: int, ok: bool) {
	fn, fn_ok := module.function(mod.file, mod.set_export)
	if !fn_ok {
		return 0, false
	}
	pcount := int(fn.parameter_count)
	if target_param_index < 0 || target_param_index >= pcount || pcount > len(out) {
		return 0, false
	}
	for p in 0 ..< pcount {
		if p == target_param_index {
			out[p] = {presence = .Given, integer = u64(value)}
		} else if mod.has_instances && p == 0 {
			inst := &mod.params[mod.instance_param_index]
			if mod.selected_instance_index < 0 || mod.selected_instance_index >= inst.value_count {
				return 0, false
			}
			out[p] = {presence = .Given, integer = u64(inst.values[mod.selected_instance_index])}
		} else {
			out[p] = {presence = .Absent, integer = 0}
		}
	}
	return pcount, true
}

// discovered_modules_scan populates set from the boot image, skipping the
// `settings` module itself (which owns the four primary cards).
discovered_modules_scan :: proc "contextless" (image: []u8, set: ^Discovered_Set) {
	set.module_count = 0
	if len(image) == 0 {
		return
	}
	for &entry in system.image_entries(image) {
		if set.module_count >= DISCOVERED_MODULE_CAPACITY {
			break
		}
		name := system.name_of(entry.name[:])
		if name == "settings" {
			continue
		}
		if entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		file := image[entry.offset:][:entry.size]
		if module_settings_discover_file(name, file, &set.modules[set.module_count]) {
			set.module_count += 1
		}
	}
}

// ---- Background worker thread for external module setters & state reads ----

// Plan value: holds 16 queued UI setting clicks while cross-process connect
// and call_isolated run on the background worker thread, so rapid clicks never
// overwrite earlier clicks.
DISCOVERED_REQUEST_QUEUE_CAPACITY :: 16

Discovered_Request :: struct {
	module_idx: int,
	param_idx:  int, // Index in mod.params (not mod.set_export).
	value:      i64,
}

discovered_set: Discovered_Set
// Module-static UI snapshot refreshed only when discovered_dirty advances
// (avoids allocating and copying a ~70 KiB Discovered_Set on the UI stack each frame).
discovered_ui_snapshot: Discovered_Set
discovered_ui_seen: u32 = max(u32)
// Module-static worker scratch owned exclusively by the single worker thread
// (avoids copying ~8.8 KiB Discovered_Module and 4 KiB table buffer onto the 64 KiB worker stack).
discovered_worker_mod: Discovered_Module
discovered_worker_table_buf: [DISCOVERED_TABLE_BUFFER_BYTES]u8

discovered_lock: system.Lock
discovered_dirty: u32
discovered_worker_wake: u32
discovered_requests: [DISCOVERED_REQUEST_QUEUE_CAPACITY]Discovered_Request
discovered_req_head: int
discovered_req_count: int
discovered_req_dropped: u64
discovered_root_ring: ring.Ring
discovered_has_root: bool
discovered_connections: [DISCOVERED_MODULE_CAPACITY]system.Call_Connection
discovered_connected: [DISCOVERED_MODULE_CAPACITY]bool
discovered_connect_tags: u32 = 1

// discovered_ui_sync refreshes the module-static UI snapshot only when
// discovered_dirty changed since the last frame.
discovered_ui_sync :: proc "contextless" () -> ^Discovered_Set {
	dirty := intrinsics.atomic_load_explicit(&discovered_dirty, .Acquire)
	if dirty != discovered_ui_seen {
		system.lock(&discovered_lock)
		discovered_ui_snapshot = discovered_set
		system.unlock(&discovered_lock)
		discovered_ui_seen = dirty
	}
	return &discovered_ui_snapshot
}

// discovered_queue_push appends a request to the bounded FIFO ring without
// waking the kernel (pure helper so host tests exercise the exact queue logic).
discovered_queue_push :: proc "contextless" (module_idx, param_idx: int, value: i64) -> bool {
	queued := false
	system.lock(&discovered_lock)
	if discovered_req_count < DISCOVERED_REQUEST_QUEUE_CAPACITY {
		tail := (discovered_req_head + discovered_req_count) % DISCOVERED_REQUEST_QUEUE_CAPACITY
		discovered_requests[tail] = {module_idx = module_idx, param_idx = param_idx, value = value}
		discovered_req_count += 1
		queued = true
	} else {
		discovered_req_dropped += 1
	}
	system.unlock(&discovered_lock)
	return queued
}

// discovered_enqueue pushes a setter call onto the bounded FIFO worker queue
// without ever blocking the main interface thread or overwriting queued clicks.
discovered_enqueue :: proc "contextless" (module_idx, param_idx: int, value: i64) -> bool {
	queued := discovered_queue_push(module_idx, param_idx, value)
	if queued {
		intrinsics.atomic_add(&discovered_worker_wake, 1)
		system.word_wake(&discovered_worker_wake)
	}
	return queued
}

// discovered_dequeue pops the oldest pending setter request in FIFO order.
discovered_dequeue :: proc "contextless" () -> (req: Discovered_Request, ok: bool) {
	system.lock(&discovered_lock)
	if discovered_req_count > 0 {
		req = discovered_requests[discovered_req_head]
		discovered_req_head = (discovered_req_head + 1) % DISCOVERED_REQUEST_QUEUE_CAPACITY
		discovered_req_count -= 1
		ok = true
	}
	system.unlock(&discovered_lock)
	return req, ok
}

// discovered_instance_index_clamp clamps mod.selected_instance_index to the
// current count of decoded instances (0 when empty).
discovered_instance_index_clamp :: proc "contextless" (mod: ^Discovered_Module) {
	if !mod.has_instances || mod.instance_param_index < 0 || mod.instance_param_index >= mod.param_count {
		mod.selected_instance_index = 0
		return
	}
	count := mod.params[mod.instance_param_index].value_count
	if count <= 0 {
		mod.selected_instance_index = 0
	} else {
		mod.selected_instance_index = clamp(mod.selected_instance_index, 0, count - 1)
	}
}

@(private = "file")
discovered_connect :: proc "contextless" (idx: int, name: string) -> bool {
	if !discovered_has_root || idx < 0 || idx >= DISCOVERED_MODULE_CAPACITY {
		return false
	}
	if discovered_connected[idx] {
		return true
	}
	discovered_connect_tags += 1
	conn, outcome := system.service_connection(&discovered_root_ring, discovered_connect_tags, name)
	if outcome != .Succeeded {
		return false
	}
	discovered_connections[idx] = conn
	discovered_connected[idx] = true
	return true
}

@(private = "file")
discovered_refresh_module :: proc "contextless" (idx: int) {
	if !discovered_connected[idx] {
		return
	}
	system.lock(&discovered_lock)
	discovered_worker_mod = discovered_set.modules[idx]
	system.unlock(&discovered_lock)
	mod := &discovered_worker_mod

	// Fetch choices/instances tables first if declared.
	for p in 0 ..< mod.param_count {
		texp := mod.params[p].kind == .Instances ? mod.params[p].instances_export : mod.params[p].choices_export
		if texp == 0 {
			continue
		}
		err: errors.Error_Record
		rows_n, out := system.call_isolated(&discovered_connections[idx], mod.file, texp, nil, &err, rows = discovered_worker_table_buf[:], deadline = system.time() + system.ANSWER_BOUND_MILLISECONDS)
		if out == .Succeeded && rows_n > 0 {
			system.lock(&discovered_lock)
			_ = discovered_table_choices_decode(mod.file, texp, discovered_worker_table_buf[:], int(rows_n), &discovered_set.modules[idx].params[p])
			if discovered_set.modules[idx].params[p].kind == .Instances {
				discovered_instance_index_clamp(&discovered_set.modules[idx])
			}
			system.unlock(&discovered_lock)
		}
	}
	if mod.settings_state_export != 0 {
		err: errors.Error_Record
		rows_n, out := system.call_isolated(&discovered_connections[idx], mod.file, mod.settings_state_export, nil, &err, rows = discovered_worker_table_buf[:], deadline = system.time() + system.ANSWER_BOUND_MILLISECONDS)
		if out == .Succeeded && rows_n > 0 {
			system.lock(&discovered_lock)
			_ = discovered_state_apply(&discovered_set.modules[idx], discovered_worker_table_buf[:], int(rows_n))
			system.unlock(&discovered_lock)
		}
	}
	intrinsics.atomic_add(&discovered_dirty, 1)
	system.word_wake(&discovered_dirty)
}

@(private = "file")
discovered_worker_entry :: proc "c" (_: rawptr) -> ! {
	// Connect on startup only to the compositor (already running whenever the
	// settings window is open), never starting on-demand services like monitor
	// until the principal clicks a setting on their card.
	for idx in 0 ..< discovered_set.module_count {
		if discovered_module_name(&discovered_set.modules[idx]) == "compositor" {
			if discovered_connect(idx, "compositor") {
				discovered_refresh_module(idx)
			}
		}
	}
	seen := intrinsics.atomic_load_explicit(&discovered_worker_wake, .Acquire)
	for {
		if req, has_req := discovered_dequeue(); has_req {
			if req.module_idx >= 0 && req.module_idx < discovered_set.module_count {
				system.lock(&discovered_lock)
				discovered_worker_mod = discovered_set.modules[req.module_idx]
				system.unlock(&discovered_lock)
				mod := &discovered_worker_mod
				name := discovered_module_name(mod)
				was_connected := discovered_connected[req.module_idx]
				if discovered_connect(req.module_idx, name) {
					// On first connect (or before state/instances are loaded),
					// refresh the module first so instances/choices are populated
					// before encoding setter arguments.
					if !was_connected || !mod.state_loaded {
						discovered_refresh_module(req.module_idx)
						system.lock(&discovered_lock)
						discovered_worker_mod = discovered_set.modules[req.module_idx]
						system.unlock(&discovered_lock)
					}
					if req.param_idx >= 0 && req.param_idx < mod.param_count {
						args: [module.PARAMETER_CAPACITY]isolated.Argument
						if arg_count, ok := discovered_set_arguments_build(mod, mod.params[req.param_idx].param_index, req.value, args[:]); ok {
							err: errors.Error_Record
							_, out := system.call_isolated(&discovered_connections[req.module_idx], mod.file, mod.set_export, args[:arg_count], &err, deadline = system.time() + system.ANSWER_BOUND_MILLISECONDS)
							if out == .Succeeded {
								discovered_refresh_module(req.module_idx)
							}
						}
					}
				}
			}
			continue
		}
		if next := intrinsics.atomic_load_explicit(&discovered_worker_wake, .Acquire); next != seen {
			seen = next
			continue
		}
		wait := system.wait_begin()
		system.wait_word(&wait, &discovered_worker_wake, seen)
		system.wait_end(&wait, system.WAIT_FOREVER)
		seen = intrinsics.atomic_load_explicit(&discovered_worker_wake, .Acquire)
	}
}

// discovered_start discovers module settings from the boot image and launches
// the background worker thread when the window opens.
discovered_start :: proc "contextless" (ctx: ^system.Context) {
	if ctx.handles[system.GRANT_IMAGE] != 0 && ctx.values[system.GRANT_VALUE_IMAGE_SIZE] > 0 {
		if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Succeeded {
			image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
			discovered_modules_scan(image, &discovered_set)
		}
	}
	if ctx.handles[system.GRANT_ROOT] != 0 {
		if opened, status := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true); status == .Succeeded {
			discovered_root_ring = opened
			discovered_has_root = true
		}
	}
	if discovered_set.module_count > 0 && discovered_has_root {
		_, _ = system.thread_start(discovered_worker_entry, nil, stack_pages = SETTINGS_WORKER_STACK_PAGES)
	}
}

// discovered_section_add adds one discovered module card to the layout tree.
discovered_section_add :: proc "contextless" (builder: ^Layout_Builder, boxes: ^Discovered_Card_Boxes, table: ^interface.Draw_Table, mod: ^Discovered_Module, room: int, tokens: layout.Element_Tokens) {
	gap := int(tokens.gap)
	boxes.card = builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = tokens.margin, .Y = 0}, gap = SETTING_GAP})
	builder_add(builder, line_box(int(tokens.title) - SETTING_GAP))
	for p in 0 ..< mod.param_count {
		param := &mod.params[p]
		pboxes := &boxes.params[p]
		builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = SETTING_PART_GAP})
		pboxes.title, pboxes.explanation = setting_header_add(builder, table, discovered_param_caption(param), room)
		if param.value_count > 0 {
			flow := flow_begin(builder, room, gap)
			for v in 0 ..< param.value_count {
				label := discovered_value_label(param, v)
				pboxes.values[v] = flow_add(&flow, button_width(table, label))
			}
			flow_end(&flow)
		}
		builder_close(builder)
	}
	builder_add(builder, line_box(0))
	builder_close(builder)
}

// discovered_card_draw paints one discovered module card and dispatches button
// clicks to the background worker thread.
discovered_card_draw :: proc "contextless" (frame: ^interface.Frame, mod_idx: int, mod: ^Discovered_Module, boxes: ^Discovered_Card_Boxes, tokens: layout.Element_Tokens, focus_area: ^interface.Area) {
	tree := &layout_tree
	interface.card(frame, area_of(tree, boxes.card), discovered_module_title(mod), "", graphics.colors.kernel)
	for p in 0 ..< mod.param_count {
		param := &mod.params[p]
		pboxes := &boxes.params[p]
		setting_header_draw(frame, area_of(tree, pboxes.title), area_of(tree, pboxes.explanation), discovered_param_name(param), discovered_param_caption(param), tokens, param.layer == .Locked)
		for v in 0 ..< param.value_count {
			if pboxes.values[v] == layout.NO_BOX {
				continue
			}
			area := area_of(tree, pboxes.values[v])
			label := discovered_value_label(param, v)
			in_use := false
			if param.kind == .Instances {
				in_use = v == mod.selected_instance_index
			} else if param.current_known {
				in_use = param.values[v] == param.current_value
			}
			id_builder: interface.Text_Builder
			interface.text_put(&id_builder, discovered_module_name(mod))
			interface.text_put(&id_builder, ".")
			interface.text_put(&id_builder, discovered_param_name(param))
			interface.text_put(&id_builder, ":")
			interface.text_put(&id_builder, label)
			element := interface.identity(interface.text_of(&id_builder))
			result := interface.button(frame, area, element, label, in_use)
			if result.focused {
				focus_area^ = area
			}
			if result.activated && !in_use && param.layer != .Locked {
				if param.kind == .Instances {
					system.lock(&discovered_lock)
					discovered_set.modules[mod_idx].selected_instance_index = v
					system.unlock(&discovered_lock)
					intrinsics.atomic_add(&discovered_dirty, 1)
				} else {
					_ = discovered_enqueue(mod_idx, p, param.values[v])
				}
			}
		}
	}
}
