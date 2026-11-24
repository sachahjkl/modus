// Pure built-in standard library functions, string interpolation formatting,
// list concatenation, record destructuring, and OSA diagnostic suggestions for
// the Lex v2 VM (src/md/features/declarations.md, "Lex v2 engine").
package lex_evaluator

import "modus:console_language"
import module "modus:contract/module"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:lex_parser"

// ---- OSA Levenshtein nearest-name suggestions for diagnostics.

@(private)
suggest_shape_fields :: proc "contextless" (eval: ^Evaluation, shape_id: u32, wanted: string, record: ^Refusal_Record) {
	if int(shape_id) >= eval.shape_count || len(wanted) == 0 {
		return
	}
	nearest := console_language.nearest_names_start(wanted)
	shape := &eval.shapes[shape_id]
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + int(shape.field_count)]
	for sym in fields {
		console_language.nearest_name_offer(&nearest, lex_parser.sym_text(&eval.interner, sym))
	}
	record.suggestion_count = nearest.count
	for i in 0 ..< nearest.count {
		record.suggestions[i] = nearest.names[i]
	}
}

@(private)
record_shape_dep :: proc "contextless" (eval: ^Evaluation, rec_val: Value, shape_id: u32) {
	if eval.on_shape_dep != nil && int(shape_id) < eval.shape_count {
		eval.on_shape_dep(eval.dep_data, lazy_record_import_owner(eval, rec_val), eval.shapes[shape_id].shape_hash)
	}
}

// ---- List concatenation (`++`).

@(private)
vm_list_concat :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if left.kind != .List || right.kind != .List {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, operator = .List_Concat, left_kind = left.kind, right_kind = right.kind})
	}
	l_items := list_items_of(eval, left)
	r_items := list_items_of(eval, right)
	total := len(l_items) + len(r_items)
	if !charge_steps(eval, u32(1 + total / 8), chunk_id, node_idx) {
		return {}, false
	}
	if total > len(eval.list_items) - eval.list_item_count {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	first := eval.list_item_count
	copy(eval.list_items[first:], l_items)
	copy(eval.list_items[first + len(l_items):], r_items)
	eval.list_item_count += total
	return {kind = .List, data = u64(first), meta = u32(total)}, true
}

// ---- String interpolation (`"${expr}"`) single-pass arena builder.

@(private)
format_i64_into :: proc "contextless" (v: i64, buf: []u8) -> string {
	if len(buf) < 24 {
		return ""
	}
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	neg := v < 0
	u := neg ? (~u64(v) + 1) : u64(v)
	tmp: [24]u8
	n := 0
	for u > 0 {
		tmp[n] = u8('0' + (u % 10))
		n += 1
		u /= 10
	}
	pos := 0
	if neg {
		buf[pos] = '-'
		pos += 1
	}
	for i := n - 1; i >= 0; i -= 1 {
		buf[pos] = tmp[i]
		pos += 1
	}
	return string(buf[:pos])
}

@(private)
vm_str_interp_push :: proc "contextless" (eval: ^Evaluation, val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> bool {
	switch val.kind {
	case .Text, .Integer, .Boolean, .Hash, .Member:
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Function, .List, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
		refuse(eval, {refusal = .Interpolation_Kind, chunk_id = chunk_id, node = node_idx, left_kind = val.kind})
		return false
	}
	if int(eval.list_scratch_top) >= len(eval.list_scratch) {
		refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
		return false
	}
	eval.list_scratch[eval.list_scratch_top] = val
	eval.list_scratch_top += 1
	return true
}

@(private)
vm_str_interp_end :: proc "contextless" (eval: ^Evaluation, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	eval.list_mark_count -= 1
	mark := eval.list_marks[eval.list_mark_count]
	pieces := eval.list_scratch[mark:eval.list_scratch_top]
	eval.list_scratch_top = mark

	start := eval.text_used
	cur := start
	num_buf: [24]u8
	hash_buf: [console_language.HASH_LITERAL_BYTES]u8

	for piece in pieces {
		seg: string
		switch piece.kind {
		case .Text:
			seg = value_text(eval, piece)
		case .Integer:
			seg = format_i64_into(value_integer(piece), num_buf[:])
			if u := value_unit(piece); u.kind != .None {
				if len(seg) > len(eval.text_arena) - cur {
					return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
				}
				copy(eval.text_arena[cur:], seg)
				cur += len(seg)
				utxt := value_kinds.integer_unit_text(u)
				if len(utxt) > len(eval.text_arena) - cur {
					return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
				}
				copy(eval.text_arena[cur:], utxt)
				cur += len(utxt)
				continue
			}
		case .Boolean:
			seg = value_boolean(piece) ? "true" : "false"
		case .Hash:
			h, hok := hash_of(eval, piece)
			if !hok {
				return refuse(eval, {refusal = .Interpolation_Kind, chunk_id = chunk_id, node = node_idx, left_kind = piece.kind})
			}
			seg = console_language.hash_format(h, &hash_buf)
		case .Member:
			seg = member_name_of(eval, piece)
		case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum,
		     .Function, .List, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref,
		     .Plan_Value, .Project_Value, .Tree_Ref:
			return refuse(eval, {refusal = .Interpolation_Kind, chunk_id = chunk_id, node = node_idx, left_kind = piece.kind})
		}
		if len(seg) > len(eval.text_arena) - cur {
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		copy(eval.text_arena[cur:], seg)
		cur += len(seg)
	}
	total_bytes := cur - start
	if !charge_steps(eval, u32(1 + total_bytes / 64), chunk_id, node_idx) {
		return {}, false
	}
	eval.text_used = cur
	return value_text_arena(u32(start), u32(total_bytes)), true
}

// ---- Strict record destructuring (`{ a, b = 10, ... }`, `r @ { a, b }`).

@(private)
alloc_forced_thunk :: proc "contextless" (eval: ^Evaluation, val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Thunk_Ref, bool) {
	if eval.thunk_count >= len(eval.thunks) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		return NO_THUNK, false
	}
	tref := Thunk_Ref(eval.thunk_count)
	eval.thunk_count += 1
	eval.thunks[tref] = {
		state   = .Forced,
		site_id = u32(node_idx),
		payload = {value = val},
	}
	if eval.profile != nil {
		eval.profile.thunks_created += 1
	}
	return tref, true
}

@(private)
vm_destructure :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, src_val: Value, pat_desc_rel: u32, node_idx: lex_parser.Node_Index) -> bool {
	chunk := &eval.chunks[frame.chunk_id]
	desc := eval.pat_descs[int(chunk.pat_desc_start) + int(pat_desc_rel)]
	pfields := eval.pat_fields[int(desc.fields_start):int(desc.fields_start) + int(desc.field_count)]

	if !charge_steps(eval, u32(1 + len(pfields)), frame.chunk_id, node_idx) {
		return false
	}

	if is_lazy_record(src_val.kind) {
		shape_id, shape_ok := lazy_record_base_shape(eval, src_val)
		if !shape_ok {
			refuse(eval, {refusal = .Pattern_Not_A_Record, chunk_id = frame.chunk_id, node = node_idx, left_kind = src_val.kind})
			return false
		}
		record_shape_dep(eval, src_val, shape_id)
		// Strict check (default when no `...`): refuse any extra field in src's shape
		// without forcing a single field value!
		if !desc.has_rest {
			shape := &eval.shapes[shape_id]
			sfields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + int(shape.field_count)]
			for ssym in sfields {
				matched := false
				for pf in pfields {
					if pf.sym == ssym {
						matched = true
						break
					}
				}
				if !matched {
					refuse(eval, {
						refusal   = .Pattern_Extra_Field,
						chunk_id  = frame.chunk_id,
						node      = desc.node_idx,
						field     = lex_parser.sym_text(&eval.interner, ssym),
						left_kind = src_val.kind,
					})
					return false
				}
			}
		}

		if desc.has_as {
			tref, tok := alloc_forced_thunk(eval, src_val, frame.chunk_id, desc.node_idx)
			if !tok {
				return false
			}
			eval.let_slots[int(frame.let_base) + int(desc.as_let_slot)] = tref
		}

		for pf in pfields {
			bound_tref: Thunk_Ref
			if tref, found := lazy_record_lookup_thunk(eval, src_val, pf.sym); found {
				bound_tref = tref
			} else if pf.has_default {
				eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, pf.default_proto, pf.node_idx)
				if !eok {
					return false
				}
				if eval.thunk_count >= len(eval.thunks) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = pf.node_idx})
					return false
				}
				def_tref := Thunk_Ref(eval.thunk_count)
				eval.thunk_count += 1
				eval.thunks[def_tref] = {
					state   = .Unforced,
					site_id = u32(pf.node_idx),
					payload = {code = {chunk_id = frame.chunk_id, proto_id = pf.default_proto, env_off = eoff, env_len = u32(elen)}},
				}
				if eval.profile != nil {
					eval.profile.thunks_created += 1
				}
				if eval.mode == .Console {
					if _, fok := vm_force_thunk(eval, def_tref, frame.chunk_id, pf.node_idx); !fok {
						return false
					}
				}
				bound_tref = def_tref
			} else {
				fname := lex_parser.sym_text(&eval.interner, pf.sym)
				refuse_field_unknown_with_suggestions(eval, shape_id, frame.chunk_id, pf.node_idx, fname, src_val.kind)
				return false
			}
			if pf.kind_annot != .None {
				fv, fok := vm_force_thunk(eval, bound_tref, frame.chunk_id, pf.node_idx)
				if !fok {
					return false
				}
				checked, cok := vm_check_param_annot(eval, fv, pf.kind_annot, pf.unit, frame.chunk_id, pf.node_idx, "", 0, lex_parser.sym_text(&eval.interner, pf.sym))
				if !cok {
					return false
				}
				if checked != fv {
					ctref, ctok := alloc_forced_thunk(eval, checked, frame.chunk_id, pf.node_idx)
					if !ctok {
						return false
					}
					bound_tref = ctref
				}
			}
			eval.let_slots[int(frame.let_base) + int(pf.let_slot)] = bound_tref
		}
		return true
	}

	if src_val.kind == .Record {
		hv := value_to_host(eval, src_val)
		if !desc.has_rest {
			if described, dok := module.record_type(hv.file, hv.detail); dok {
				for fi in u32(0) ..< described.field_count {
					item := module.field(hv.file, described, fi) or_continue
					fname := module.string_at(hv.file, item.name_offset, item.name_count)
					matched := false
					for pf in pfields {
						if lex_parser.sym_text(&eval.interner, pf.sym) == fname {
							matched = true
							break
						}
					}
					if !matched {
						refuse(eval, {refusal = .Pattern_Extra_Field, chunk_id = frame.chunk_id, node = desc.node_idx, field = fname, left_kind = .Record})
						return false
					}
				}
			}
		}
		if desc.has_as {
			tref, tok := alloc_forced_thunk(eval, src_val, frame.chunk_id, desc.node_idx)
			if !tok {
				return false
			}
			eval.let_slots[int(frame.let_base) + int(desc.as_let_slot)] = tref
		}
		for pf in pfields {
			fname := lex_parser.sym_text(&eval.interner, pf.sym)
			bound_tref: Thunk_Ref
			if fhv, found := record_field_value(hv, fname); found {
				fvm, vok := host_to_value(eval, fhv)
				if !vok {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = pf.node_idx})
					return false
				}
				if pf.kind_annot != .None {
					checked, cok := vm_check_param_annot(eval, fvm, pf.kind_annot, pf.unit, frame.chunk_id, pf.node_idx, "", 0, fname)
					if !cok {
						return false
					}
					fvm = checked
				}
				tref, tok := alloc_forced_thunk(eval, fvm, frame.chunk_id, pf.node_idx)
				if !tok {
					return false
				}
				bound_tref = tref
			} else if pf.has_default {
				eoff, elen, eok := capture_upvals(eval, frame, frame.chunk_id, pf.default_proto, pf.node_idx)
				if !eok {
					return false
				}
				if eval.thunk_count >= len(eval.thunks) {
					refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = pf.node_idx})
					return false
				}
				tref := Thunk_Ref(eval.thunk_count)
				eval.thunk_count += 1
				eval.thunks[tref] = {
					state   = .Unforced,
					site_id = u32(pf.node_idx),
					payload = {code = {chunk_id = frame.chunk_id, proto_id = pf.default_proto, env_off = eoff, env_len = u32(elen)}},
				}
				if eval.mode == .Console || pf.kind_annot != .None {
					fv, fok := vm_force_thunk(eval, tref, frame.chunk_id, pf.node_idx)
					if !fok {
						return false
					}
					if pf.kind_annot != .None {
						checked, cok := vm_check_param_annot(eval, fv, pf.kind_annot, pf.unit, frame.chunk_id, pf.node_idx, "", 0, fname)
						if !cok {
							return false
						}
						if checked != fv {
							ctref, ctok := alloc_forced_thunk(eval, checked, frame.chunk_id, pf.node_idx)
							if !ctok {
								return false
							}
							tref = ctref
						}
					}
				}
				bound_tref = tref
			} else {
				refuse(eval, {refusal = .Field_Unknown, chunk_id = frame.chunk_id, node = pf.node_idx, field = fname, left_kind = .Record, file = hv.file, detail = hv.detail})
				return false
			}
			eval.let_slots[int(frame.let_base) + int(pf.let_slot)] = bound_tref
		}
		return true
	}

	refuse(eval, {refusal = .Pattern_Not_A_Record, chunk_id = frame.chunk_id, node = node_idx, left_kind = src_val.kind})
	return false
}

// ---- Pure stdlib built-ins (collision-free with console commands).

@(private)
vm_exec_builtin :: proc "contextless" (
	eval: ^Evaluation,
	frame: ^VM_Frame,
	bid: Builtin_Id,
	args: []Value,
	dst_reg: u8,
	node_idx: lex_parser.Node_Index,
) -> bool {
	switch bid {
	case .None:
		return false
	case .Map, .Filter:
		return vm_start_map_filter(eval, frame, bid, args[0], args[1], dst_reg, node_idx)
	case .Fold:
		return vm_start_fold(eval, frame, args[0], args[1], args[2], dst_reg, node_idx)
	case .Zip:
		res, ok := vm_builtin_zip(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Fields:
		res, ok := vm_builtin_fields(eval, args[0], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Values:
		res, ok := vm_builtin_values(eval, args[0], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Has:
		res, ok := vm_builtin_has(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Extend:
		res, ok := vm_builtin_extend(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Merge_Deep:
		res, ok := vm_builtin_merge_deep(eval, args[0], args[1], frame.chunk_id, node_idx, 0)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .From_Entries:
		res, ok := vm_builtin_from_entries(eval, args[0], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Len:
		res, ok := vm_builtin_len(eval, args[0], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .At:
		res, ok := vm_builtin_at(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Slice:
		res, ok := vm_builtin_slice(eval, args[0], args[1], args[2], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Any, .All:
		return vm_start_any_all(eval, frame, bid, args[0], args[1], dst_reg, node_idx)
	case .Flat_Map:
		return vm_start_flat_map(eval, frame, args[0], args[1], dst_reg, node_idx)
	case .Unique:
		res, ok := vm_builtin_unique(eval, args[0], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Sort_By:
		return vm_start_sort_by(eval, frame, args[0], args[1], dst_reg, node_idx)
	case .Split:
		res, ok := vm_builtin_split(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Join_Text:
		res, ok := vm_builtin_join_text(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Starts_With:
		res, ok := vm_builtin_starts_with(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Ends_With:
		res, ok := vm_builtin_ends_with(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Contains:
		res, ok := vm_builtin_contains(eval, args[0], args[1], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	case .Replace_Text:
		res, ok := vm_builtin_replace_text(eval, args[0], args[1], args[2], frame.chunk_id, node_idx)
		if !ok {
			return false
		}
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = res
		return true
	}
	return false
}

// fold(list, init, fn): iterative left fold over a flat VM continuation frame.
@(private)
vm_start_fold :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, list_val, init_val, fn_val: Value, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	if list_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, command = FOLD_NAME, parameter = 1, left_kind = list_val.kind})
		return false
	}
	if fn_val.kind != .Function {
		refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = FOLD_NAME, parameter = 3, left_kind = fn_val.kind})
		return false
	}
	cl := eval.closures[int(fn_val.data)]
	cchunk := &eval.chunks[cl.chunk_id]
	cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
	if !fn_arity_accepts_positional(cproto, 2) {
		refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = FOLD_NAME, parameter = 3, left = 2, right = i64(cproto.param_count)})
		return false
	}
	cnt := list_val.meta
	if cnt == 0 {
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = init_val
		return true
	}
	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 1 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 1
	eval.reg_stack[reg_base] = init_val
	f := &eval.frames[eval.frame_count]
	f^ = {
		kind          = .Fold,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(list_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_fn       = fn_val,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
}

// zip(left, right): produces List of `{ first = left[i], second = right[i] }`
// records up to min(len(left), len(right)).
@(private)
ensure_zip_shape :: proc "contextless" (eval: ^Evaluation, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (u32, bool) {
	if eval.has_zip_shape {
		return eval.zip_shape_id, true
	}
	first_sym, ok1 := lex_parser.intern(&eval.interner, "first")
	second_sym, ok2 := lex_parser.intern(&eval.interner, "second")
	if !ok1 || !ok2 || eval.shape_count >= len(eval.shapes) || eval.shape_field_count + 2 > len(eval.shape_fields) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		return 0, false
	}
	foff := u32(eval.shape_field_count)
	eval.shape_fields[foff] = first_sym
	eval.shape_fields[foff + 1] = second_sym
	eval.shape_field_count += 2
	// Deterministic shape hash for ["first", "second"].
	sh := shape_hash_of_fields(&eval.interner, eval.shape_fields[foff:foff + 2])
	sid := u32(eval.shape_count)
	eval.shapes[sid] = {
		fields_off  = foff,
		field_count = 2,
		shape_hash  = sh,
	}
	eval.shape_count += 1
	eval.zip_shape_id = sid
	eval.has_zip_shape = true
	return sid, true
}

@(private)
shape_hash_of_fields :: proc "contextless" (interner: ^lex_parser.String_Interner, fields: []lex_parser.Sym_Id) -> u64 {
	h := u64(0xcbf29ce484222325)
	for sym in fields {
		txt := lex_parser.sym_text(interner, sym)
		for b in transmute([]u8)txt {
			h = (h ~ u64(b)) * 0x100000001b3
		}
		h = (h ~ 0xff) * 0x100000001b3
	}
	return h
}

@(private)
vm_builtin_zip :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if left.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = ZIP_NAME, parameter = 1, left_kind = left.kind})
	}
	if right.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = ZIP_NAME, parameter = 2, left_kind = right.kind})
	}
	l_items := list_items_of(eval, left)
	r_items := list_items_of(eval, right)
	n := min(len(l_items), len(r_items))
	if !charge_steps(eval, u32(1 + n), chunk_id, node_idx) {
		return {}, false
	}
	if n == 0 {
		return {kind = .List, data = u64(eval.list_item_count), meta = 0}, true
	}
	shape_id, sok := ensure_zip_shape(eval, chunk_id, node_idx)
	if !sok {
		return {}, false
	}
	if n > len(eval.list_items) - eval.list_item_count {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	if eval.record_count + n > len(eval.records) || eval.record_thunk_ref_count + 2 * n > len(eval.record_thunk_refs) || eval.thunk_count + 2 * n > len(eval.thunks) {
		return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
	}
	first := eval.list_item_count
	for i in 0 ..< n {
		t0, _ := alloc_forced_thunk(eval, l_items[i], chunk_id, node_idx)
		t1, _ := alloc_forced_thunk(eval, r_items[i], chunk_id, node_idx)
		roff := u32(eval.record_thunk_ref_count)
		eval.record_thunk_refs[roff] = t0
		eval.record_thunk_refs[roff + 1] = t1
		eval.record_thunk_ref_count += 2
		ridx := u32(eval.record_count)
		eval.records[ridx] = {shape_id = shape_id, refs_off = roff, chunk_id = chunk_id, node_idx = node_idx}
		eval.record_count += 1
		eval.list_items[first + i] = {kind = .Record_Literal, data = u64(ridx), meta = shape_id}
	}
	eval.list_item_count += n
	return {kind = .List, data = u64(first), meta = u32(n)}, true
}

// fields(rec): returns canonical UTF-8 sorted List of Text field names without
// forcing any field value!
@(private)
vm_builtin_fields :: proc "contextless" (eval: ^Evaluation, rec_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if is_lazy_record(rec_val.kind) {
		shape_id, sok := lazy_record_base_shape(eval, rec_val)
		if !sok {
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = FIELDS_NAME, left_kind = rec_val.kind})
		}
		record_shape_dep(eval, rec_val, shape_id)
		shape := &eval.shapes[shape_id]
		fcount := int(shape.field_count)
		if !charge_steps(eval, u32(1 + fcount), chunk_id, node_idx) {
			return {}, false
		}
		if fcount > len(eval.list_items) - eval.list_item_count {
			return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
		}
		first := eval.list_item_count
		fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + fcount]
		for sym, i in fields {
			eval.list_items[first + i] = value_text_sym(sym)
		}
		eval.list_item_count += fcount
		return {kind = .List, data = u64(first), meta = u32(fcount)}, true
	}
	if rec_val.kind == .Record {
		hv := value_to_host(eval, rec_val)
		described, dok := module.record_type(hv.file, hv.detail)
		if !dok {
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = FIELDS_NAME, left_kind = rec_val.kind})
		}
		fcount := int(described.field_count)
		if !charge_steps(eval, u32(1 + fcount), chunk_id, node_idx) {
			return {}, false
		}
		if fcount > len(eval.list_items) - eval.list_item_count {
			return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
		}
		first := eval.list_item_count
		for i in 0 ..< fcount {
			item, ok := module.field(hv.file, described, u32(i))
			if !ok {
				return refuse(eval, {refusal = .Host_Refused, chunk_id = chunk_id, node = node_idx})
			}
			fname := module.string_at(hv.file, item.name_offset, item.name_count)
			tv, tok := text_arena_alloc(eval, fname)
			if !tok {
				return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
			}
			eval.list_items[first + i] = tv
		}
		eval.list_item_count += fcount
		return {kind = .List, data = u64(first), meta = u32(fcount)}, true
	}
	return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = FIELDS_NAME, left_kind = rec_val.kind})
}

// values(rec): forces all fields of `rec` in canonical UTF-8 key order and
// returns them as a List.
@(private)
vm_builtin_values :: proc "contextless" (eval: ^Evaluation, rec_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if !is_lazy_record(rec_val.kind) {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = VALUES_NAME, left_kind = rec_val.kind})
	}
	shape_id, sok := lazy_record_base_shape(eval, rec_val)
	if !sok {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = VALUES_NAME, left_kind = rec_val.kind})
	}
	record_shape_dep(eval, rec_val, shape_id)
	shape := &eval.shapes[shape_id]
	fcount := int(shape.field_count)
	if !charge_steps(eval, u32(1 + fcount), chunk_id, node_idx) {
		return {}, false
	}
	if fcount == 0 {
		return {kind = .List, data = u64(eval.list_item_count), meta = 0}, true
	}
	if int(eval.list_scratch_top) + fcount > len(eval.list_scratch) {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	mark := eval.list_scratch_top
	eval.list_scratch_top += u32(fcount)
	fields := eval.shape_fields[int(shape.fields_off):int(shape.fields_off) + fcount]
	for sym, i in fields {
		tref, found := lazy_record_lookup_thunk(eval, rec_val, sym)
		if !found {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, field = lex_parser.sym_text(&eval.interner, sym)})
		}
		fv, fok := vm_force_thunk(eval, tref, chunk_id, node_idx)
		if !fok {
			eval.list_scratch_top = mark
			return {}, false
		}
		eval.list_scratch[mark + u32(i)] = fv
	}
	if fcount > len(eval.list_items) - eval.list_item_count {
		eval.list_scratch_top = mark
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	first := eval.list_item_count
	copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(fcount)])
	eval.list_scratch_top = mark
	eval.list_item_count += fcount
	return {kind = .List, data = u64(first), meta = u32(fcount)}, true
}

// has(rec, name): non-forcing Boolean check against `rec`'s shape.
@(private)
vm_builtin_has :: proc "contextless" (eval: ^Evaluation, rec_val, name_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if name_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = HAS_NAME, left_kind = rec_val.kind, right_kind = name_val.kind})
	}
	name := value_text(eval, name_val)
	if is_lazy_record(rec_val.kind) {
		shape_id, sok := lazy_record_base_shape(eval, rec_val)
		if !sok {
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = HAS_NAME, left_kind = rec_val.kind, right_kind = name_val.kind})
		}
		record_shape_dep(eval, rec_val, shape_id)
		sym, has_sym := lex_parser.intern_lookup(&eval.interner, name)
		if !has_sym {
			return value_bool(false), true
		}
		_, found := shape_lookup_sym(eval, shape_id, sym)
		return value_bool(found), true
	}
	if rec_val.kind == .Record {
		hv := value_to_host(eval, rec_val)
		_, found := record_field_value(hv, name)
		return value_bool(found), true
	}
	return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = HAS_NAME, left_kind = rec_val.kind, right_kind = name_val.kind})
}

// extend(a, b): shallow lazy field addition and override. Merges two UTF-8
// sorted Record_Shapes in O(Fa + Fb) and copies Thunk_Refs without forcing any
// field value. Step-charged.
@(private)
vm_builtin_extend :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if !is_lazy_record(left.kind) || !is_lazy_record(right.kind) {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, command = EXTEND_NAME, left_kind = left.kind, right_kind = right.kind})
	}
	l_shape_id, lok := lazy_record_base_shape(eval, left)
	r_shape_id, rok := lazy_record_base_shape(eval, right)
	if !lok || !rok {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, command = EXTEND_NAME, left_kind = left.kind, right_kind = right.kind})
	}
	record_shape_dep(eval, left, l_shape_id)
	record_shape_dep(eval, right, r_shape_id)
	l_shape := &eval.shapes[l_shape_id]
	r_shape := &eval.shapes[r_shape_id]
	lf := eval.shape_fields[int(l_shape.fields_off):int(l_shape.fields_off) + int(l_shape.field_count)]
	rf := eval.shape_fields[int(r_shape.fields_off):int(r_shape.fields_off) + int(r_shape.field_count)]
	if !charge_steps(eval, u32(1 + len(lf) + len(rf)), chunk_id, node_idx) {
		return {}, false
	}

	max_out := len(lf) + len(rf)
	if eval.shape_count >= len(eval.shapes) ||
	   eval.shape_field_count + max_out > len(eval.shape_fields) ||
	   eval.record_count >= len(eval.records) ||
	   eval.record_thunk_ref_count + max_out > len(eval.record_thunk_refs) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}

	foff := u32(eval.shape_field_count)
	roff := u32(eval.record_thunk_ref_count)
	out_n := 0
	li, ri := 0, 0
	for li < len(lf) || ri < len(rf) {
		take_right := false
		advance_both := false
		if li >= len(lf) {
			take_right = true
		} else if ri >= len(rf) {
			take_right = false
		} else if lf[li] == rf[ri] {
			take_right = true
			advance_both = true
		} else {
			cmp := str_cmp(lex_parser.sym_text(&eval.interner, lf[li]), lex_parser.sym_text(&eval.interner, rf[ri]))
			if cmp == 0 {
				take_right = true
				advance_both = true
			} else if cmp > 0 {
				take_right = true
			}
		}
		if take_right {
			sym := rf[ri]
			tref, _ := lazy_record_lookup_thunk(eval, right, sym)
			eval.shape_fields[int(foff) + out_n] = sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			ri += 1
			if advance_both {
				li += 1
			}
		} else {
			sym := lf[li]
			tref, _ := lazy_record_lookup_thunk(eval, left, sym)
			eval.shape_fields[int(foff) + out_n] = sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			li += 1
		}
		out_n += 1
	}
	eval.shape_field_count += out_n
	eval.record_thunk_ref_count += out_n

	sid := u32(eval.shape_count)
	eval.shapes[sid] = {
		fields_off  = foff,
		field_count = u32(out_n),
		shape_hash  = shape_hash_of_fields(&eval.interner, eval.shape_fields[int(foff):int(foff) + out_n]),
	}
	eval.shape_count += 1
	build_shape_hash_index(eval, sid)

	ridx := u32(eval.record_count)
	eval.records[ridx] = {shape_id = sid, refs_off = roff, chunk_id = chunk_id, node_idx = node_idx}
	eval.record_count += 1
	return {kind = .Record_Literal, data = u64(ridx), meta = sid}, true
}

// merge_deep(a, b): recursive lazy merge of two records (depth- and step-bounded).
// Keys only in `a` or only in `b` copy Thunk_Refs without forcing. For shared
// keys, `b.k` is forced to WHNF first: if `b.k` is not a lazy record, `b.k`
// wins without forcing `a.k`; if both are lazy records, they merge recursively.
@(private)
vm_builtin_merge_deep :: proc "contextless" (eval: ^Evaluation, left, right: Value, chunk_id: u16, node_idx: lex_parser.Node_Index, depth: int) -> (Value, bool) {
	if depth >= MERGE_DEEP_DEPTH_LIMIT {
		return refuse(eval, {refusal = .Depth_Exceeded, chunk_id = chunk_id, node = node_idx, command = MERGE_DEEP_NAME})
	}
	if !is_lazy_record(left.kind) || !is_lazy_record(right.kind) {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, command = MERGE_DEEP_NAME, left_kind = left.kind, right_kind = right.kind})
	}
	l_shape_id, lok := lazy_record_base_shape(eval, left)
	r_shape_id, rok := lazy_record_base_shape(eval, right)
	if !lok || !rok {
		return refuse(eval, {refusal = .With_Kinds, chunk_id = chunk_id, node = node_idx, command = MERGE_DEEP_NAME, left_kind = left.kind, right_kind = right.kind})
	}
	record_shape_dep(eval, left, l_shape_id)
	record_shape_dep(eval, right, r_shape_id)
	l_shape := &eval.shapes[l_shape_id]
	r_shape := &eval.shapes[r_shape_id]
	l_count := int(l_shape.field_count)
	r_count := int(r_shape.field_count)
	l_off := int(l_shape.fields_off)
	r_off := int(r_shape.fields_off)
	if !charge_steps(eval, u32(1 + l_count + r_count), chunk_id, node_idx) {
		return {}, false
	}

	// Reserve worst-case output slice BEFORE recursive calls so nested merges
	// do not overlap our shape_fields / record_thunk_refs slice!
	max_out := l_count + r_count
	if eval.shape_count >= len(eval.shapes) ||
	   eval.shape_field_count + max_out > len(eval.shape_fields) ||
	   eval.record_count >= len(eval.records) ||
	   eval.record_thunk_ref_count + max_out > len(eval.record_thunk_refs) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}
	foff := u32(eval.shape_field_count)
	roff := u32(eval.record_thunk_ref_count)
	eval.shape_field_count += max_out
	eval.record_thunk_ref_count += max_out

	out_n := 0
	li, ri := 0, 0
	for li < l_count || ri < r_count {
		l_sym := li < l_count ? eval.shape_fields[l_off + li] : lex_parser.NO_SYM
		r_sym := ri < r_count ? eval.shape_fields[r_off + ri] : lex_parser.NO_SYM
		if li >= l_count {
			tref, _ := lazy_record_lookup_thunk(eval, right, r_sym)
			eval.shape_fields[int(foff) + out_n] = r_sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			ri += 1
			out_n += 1
			continue
		}
		if ri >= r_count {
			tref, _ := lazy_record_lookup_thunk(eval, left, l_sym)
			eval.shape_fields[int(foff) + out_n] = l_sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			li += 1
			out_n += 1
			continue
		}
		cmp := l_sym == r_sym ? 0 : str_cmp(lex_parser.sym_text(&eval.interner, l_sym), lex_parser.sym_text(&eval.interner, r_sym))
		if cmp < 0 {
			tref, _ := lazy_record_lookup_thunk(eval, left, l_sym)
			eval.shape_fields[int(foff) + out_n] = l_sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			li += 1
			out_n += 1
		} else if cmp > 0 {
			tref, _ := lazy_record_lookup_thunk(eval, right, r_sym)
			eval.shape_fields[int(foff) + out_n] = r_sym
			eval.record_thunk_refs[int(roff) + out_n] = tref
			ri += 1
			out_n += 1
		} else {
			// Shared key: force right to WHNF first so scalar override skips left.
			r_tref, _ := lazy_record_lookup_thunk(eval, right, r_sym)
			r_val, rv_ok := vm_force_thunk(eval, r_tref, chunk_id, node_idx)
			if !rv_ok {
				return {}, false
			}
			chosen_tref := r_tref
			if is_lazy_record(r_val.kind) {
				l_tref, _ := lazy_record_lookup_thunk(eval, left, l_sym)
				l_val, lv_ok := vm_force_thunk(eval, l_tref, chunk_id, node_idx)
				if !lv_ok {
					return {}, false
				}
				if is_lazy_record(l_val.kind) {
					merged, mok := vm_builtin_merge_deep(eval, l_val, r_val, chunk_id, node_idx, depth + 1)
					if !mok {
						return {}, false
					}
					mtref, tok := alloc_forced_thunk(eval, merged, chunk_id, node_idx)
					if !tok {
						return {}, false
					}
					chosen_tref = mtref
				}
			}
			eval.shape_fields[int(foff) + out_n] = r_sym
			eval.record_thunk_refs[int(roff) + out_n] = chosen_tref
			li += 1
			ri += 1
			out_n += 1
		}
	}

	if eval.shape_count >= len(eval.shapes) || eval.record_count >= len(eval.records) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}
	sid := u32(eval.shape_count)
	eval.shapes[sid] = {
		fields_off  = foff,
		field_count = u32(out_n),
		shape_hash  = shape_hash_of_fields(&eval.interner, eval.shape_fields[int(foff):int(foff) + out_n]),
	}
	eval.shape_count += 1
	build_shape_hash_index(eval, sid)

	ridx := u32(eval.record_count)
	eval.records[ridx] = {shape_id = sid, refs_off = roff, chunk_id = chunk_id, node_idx = node_idx}
	eval.record_count += 1
	return {kind = .Record_Literal, data = u64(ridx), meta = sid}, true
}

// ---- Dynamic O(N) record construction (`from_entries` and `{ for ... }`).

@(private)
sort_shape_and_thunks_utf8 :: proc "contextless" (interner: ^lex_parser.String_Interner, syms: []lex_parser.Sym_Id, thunks: []Thunk_Ref) {
	less :: proc "contextless" (interner: ^lex_parser.String_Interner, a, b: lex_parser.Sym_Id) -> bool {
		if a == b {
			return false
		}
		return str_cmp(lex_parser.sym_text(interner, a), lex_parser.sym_text(interner, b)) < 0
	}
	sift_down :: proc "contextless" (interner: ^lex_parser.String_Interner, syms: []lex_parser.Sym_Id, thunks: []Thunk_Ref, start, end: int) {
		root := start
		for root * 2 + 1 < end {
			child := root * 2 + 1
			swap_idx := root
			if less(interner, syms[swap_idx], syms[child]) {
				swap_idx = child
			}
			if child + 1 < end && less(interner, syms[swap_idx], syms[child + 1]) {
				swap_idx = child + 1
			}
			if swap_idx == root {
				return
			}
			syms[root], syms[swap_idx] = syms[swap_idx], syms[root]
			thunks[root], thunks[swap_idx] = thunks[swap_idx], thunks[root]
			root = swap_idx
		}
	}
	n := len(syms)
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift_down(interner, syms, thunks, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		syms[0], syms[end] = syms[end], syms[0]
		thunks[0], thunks[end] = thunks[end], thunks[0]
		sift_down(interner, syms, thunks, 0, end)
	}
}

// build_dynamic_record_from_pairs constructs one canonical UTF-8 sorted
// Record_Shape (attaching a Slice_Hash_Index past 16 fields) and Lazy_Record
// from interleaved `[key_text, thunk_ref_carrier, ...]` pairs.
@(private)
build_dynamic_record_from_pairs :: proc "contextless" (eval: ^Evaluation, pairs: []Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	count := len(pairs) / 2
	if !charge_steps(eval, u32(1 + count), chunk_id, node_idx) {
		return {}, false
	}
	if eval.shape_count >= len(eval.shapes) ||
	   eval.shape_field_count + count > len(eval.shape_fields) ||
	   eval.record_count >= len(eval.records) ||
	   eval.record_thunk_ref_count + count > len(eval.record_thunk_refs) {
		return refuse(eval, {refusal = .With_Pairs_Full, chunk_id = chunk_id, node = node_idx})
	}
	foff := u32(eval.shape_field_count)
	roff := u32(eval.record_thunk_ref_count)
	for i in 0 ..< count {
		ktxt := value_text(eval, pairs[i * 2])
		sym, ok := lex_parser.intern(&eval.interner, ktxt)
		if !ok {
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		eval.shape_fields[int(foff) + i] = sym
		eval.record_thunk_refs[int(roff) + i] = Thunk_Ref(pairs[i * 2 + 1].data)
	}
	if count > 1 {
		if !charge_steps(eval, u32(count), chunk_id, node_idx) {
			return {}, false
		}
		syms_slice := eval.shape_fields[int(foff):int(foff) + count]
		refs_slice := eval.record_thunk_refs[int(roff):int(roff) + count]
		sort_shape_and_thunks_utf8(&eval.interner, syms_slice, refs_slice)
		for i in 0 ..< count - 1 {
			if syms_slice[i] == syms_slice[i + 1] {
				fname := lex_parser.sym_text(&eval.interner, syms_slice[i])
				return refuse(eval, {refusal = .Duplicate_Field, chunk_id = chunk_id, node = node_idx, field = fname})
			}
		}
	}
	eval.shape_field_count += count
	eval.record_thunk_ref_count += count
	sid := u32(eval.shape_count)
	eval.shapes[sid] = {
		fields_off  = foff,
		field_count = u32(count),
		shape_hash  = shape_hash_of_fields(&eval.interner, eval.shape_fields[int(foff):int(foff) + count]),
	}
	eval.shape_count += 1
	build_shape_hash_index(eval, sid)

	ridx := u32(eval.record_count)
	eval.records[ridx] = {shape_id = sid, refs_off = roff, chunk_id = chunk_id, node_idx = node_idx}
	eval.record_count += 1
	return {kind = .Record_Literal, data = u64(ridx), meta = sid}, true
}

// from_entries(list): builds a record from `[{ name = Text, value = any }, ...]`.
// Preserves lazy `value` thunks in Declaration mode.
@(private)
vm_builtin_from_entries :: proc "contextless" (eval: ^Evaluation, list_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if list_val.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, parameter = 1, left_kind = list_val.kind})
	}
	items := list_items_of(eval, list_val)
	n := len(items)
	if n == 0 {
		return build_dynamic_record_from_pairs(eval, nil, chunk_id, node_idx)
	}
	if !charge_steps(eval, u32(1 + n), chunk_id, node_idx) {
		return {}, false
	}
	name_sym, ok1 := lex_parser.intern(&eval.interner, "name")
	val_sym, ok2 := lex_parser.intern(&eval.interner, "value")
	if !ok1 || !ok2 {
		return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
	}
	if 2 * n > len(eval.list_scratch) - int(eval.list_scratch_top) {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	mark := eval.list_scratch_top
	for item in items {
		if !is_lazy_record(item.kind) {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, left_kind = item.kind})
		}
		if sid, sok := lazy_record_base_shape(eval, item); sok {
			record_shape_dep(eval, item, sid)
		}
		ntref, has_name := lazy_record_lookup_thunk(eval, item, name_sym)
		if !has_name {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, field = "name", left_kind = item.kind})
		}
		vtref, has_val := lazy_record_lookup_thunk(eval, item, val_sym)
		if !has_val {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Field_Unknown, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, field = "value", left_kind = item.kind})
		}
		nval, nok := vm_force_thunk(eval, ntref, chunk_id, node_idx)
		if !nok {
			eval.list_scratch_top = mark
			return {}, false
		}
		if nval.kind != .Text {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Field_Name_Invalid, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, left_kind = nval.kind})
		}
		ktxt := value_text(eval, nval)
		if !lex_parser.name_valid(ktxt) {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Field_Name_Invalid, chunk_id = chunk_id, node = node_idx, command = FROM_ENTRIES_NAME, field = ktxt, left_kind = .Text})
		}
		if eval.mode == .Console {
			if _, vok := vm_force_thunk(eval, vtref, chunk_id, node_idx); !vok {
				eval.list_scratch_top = mark
				return {}, false
			}
		}
		eval.list_scratch[eval.list_scratch_top] = nval
		eval.list_scratch[eval.list_scratch_top + 1] = Value{kind = .None, data = u64(vtref)}
		eval.list_scratch_top += 2
	}
	pairs := eval.list_scratch[mark:eval.list_scratch_top]
	eval.list_scratch_top = mark
	return build_dynamic_record_from_pairs(eval, pairs, chunk_id, node_idx)
}

// ---- Core pure List stdlib functions (`len`, `at`, `slice`, `any`, `all`, `flat_map`, `unique`, `sort_by`).

// len(x): item count for List; UTF-8 Unicode codepoint count for Text.
@(private)
vm_builtin_len :: proc "contextless" (eval: ^Evaluation, val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if val.kind == .List {
		return value_int(i64(val.meta)), true
	}
	if val.kind == .Text {
		txt := value_text(eval, val)
		if !charge_steps(eval, u32(1 + len(txt) / 64), chunk_id, node_idx) {
			return {}, false
		}
		return value_int(i64(text_encoding.character_count(transmute([]u8)txt))), true
	}
	return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = LEN_NAME, left_kind = val.kind})
}

// at(list, index): 0-based indexing; refuses negative, out-of-bounds, or unit index.
@(private)
vm_builtin_at :: proc "contextless" (eval: ^Evaluation, list_val, idx_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if list_val.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = AT_NAME, parameter = 1, left_kind = list_val.kind})
	}
	if idx_val.kind != .Integer {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = AT_NAME, parameter = 2, left_kind = list_val.kind, right_kind = idx_val.kind})
	}
	if u := value_unit(idx_val); u.kind != .None {
		return refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, command = AT_NAME, parameter = 2, left_kind = .Integer, left_unit = u})
	}
	idx := value_integer(idx_val)
	n := i64(list_val.meta)
	if idx < 0 || idx >= n {
		return refuse(eval, {refusal = .Index_Out_Of_Bounds, chunk_id = chunk_id, node = node_idx, command = AT_NAME, left = idx, right = n})
	}
	return eval.list_items[int(list_val.data) + int(idx)], true
}

// slice(list, start, end): zero-copy sub-list `[start, end)`.
@(private)
vm_builtin_slice :: proc "contextless" (eval: ^Evaluation, list_val, start_val, end_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if list_val.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, parameter = 1, left_kind = list_val.kind})
	}
	if start_val.kind != .Integer {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, parameter = 2, left_kind = start_val.kind})
	}
	if end_val.kind != .Integer {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, parameter = 3, left_kind = end_val.kind})
	}
	if su := value_unit(start_val); su.kind != .None {
		return refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, parameter = 2, left_kind = .Integer, left_unit = su})
	}
	if eu := value_unit(end_val); eu.kind != .None {
		return refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, parameter = 3, left_kind = .Integer, left_unit = eu})
	}
	s := value_integer(start_val)
	e := value_integer(end_val)
	n := i64(list_val.meta)
	if s < 0 || e < s || e > n {
		bad := s < 0 ? s : e
		return refuse(eval, {refusal = .Index_Out_Of_Bounds, chunk_id = chunk_id, node = node_idx, command = SLICE_NAME, left = bad, right = n})
	}
	return {kind = .List, data = list_val.data + u64(s), meta = u32(e - s)}, true
}

@(private)
vm_start_any_all :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, bid: Builtin_Id, list_val, fn_val: Value, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	cmd := bid == .Any ? ANY_NAME : ALL_NAME
	if list_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 1, left_kind = list_val.kind})
		return false
	}
	if fn_val.kind != .Function {
		refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 2, left_kind = fn_val.kind})
		return false
	}
	cl := eval.closures[int(fn_val.data)]
	cchunk := &eval.chunks[cl.chunk_id]
	cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
	if !fn_arity_accepts_positional(cproto, 1) {
		refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = cmd, parameter = 2, left = 1, right = i64(cproto.param_count)})
		return false
	}
	cnt := list_val.meta
	if cnt == 0 {
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = value_bool(bid == .All)
		return true
	}
	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 1 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 1
	f := &eval.frames[eval.frame_count]
	f^ = {
		kind          = bid == .Any ? .Any : .All,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(list_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_fn       = fn_val,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
}

@(private)
vm_start_flat_map :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, list_val, fn_val: Value, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	if list_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, command = FLAT_MAP_NAME, parameter = 1, left_kind = list_val.kind})
		return false
	}
	if fn_val.kind != .Function {
		refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = FLAT_MAP_NAME, parameter = 2, left_kind = fn_val.kind})
		return false
	}
	cl := eval.closures[int(fn_val.data)]
	cchunk := &eval.chunks[cl.chunk_id]
	cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
	if !fn_arity_accepts_positional(cproto, 1) {
		refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = FLAT_MAP_NAME, parameter = 2, left = 1, right = i64(cproto.param_count)})
		return false
	}
	cnt := list_val.meta
	if cnt == 0 {
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = {kind = .List, data = u64(eval.list_item_count), meta = 0}
		return true
	}
	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 1 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 1
	f := &eval.frames[eval.frame_count]
	f^ = {
		kind          = .Flat_Map,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(list_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_out_off  = eval.list_scratch_top,
		cont_fn       = fn_val,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
}

// unique(list): deduplicates scalar items in first-seen order (step-charged).
@(private)
vm_builtin_unique :: proc "contextless" (eval: ^Evaluation, list_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if list_val.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = UNIQUE_NAME, parameter = 1, left_kind = list_val.kind})
	}
	items := list_items_of(eval, list_val)
	if len(items) == 0 {
		return {kind = .List, data = u64(eval.list_item_count), meta = 0}, true
	}
	mark := eval.list_scratch_top
	for item in items {
		switch item.kind {
		case .Integer, .Boolean, .Text, .Hash, .Module_Ref, .Tree_Ref, .Member:
		case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal,
		     .Enum, .Function, .List, .Record_With, .Recipe_Ref, .Follow_Ref, .Store_Ref,
		     .Plan_Value, .Project_Value:
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = UNIQUE_NAME, left_kind = item.kind})
		}
		seen := false
		for prev in eval.list_scratch[mark:eval.list_scratch_top] {
			if !charge_steps(eval, 1, chunk_id, node_idx) {
				eval.list_scratch_top = mark
				return {}, false
			}
			eq, ok := vm_match_eq(eval, prev, item, chunk_id, node_idx)
			if !ok {
				eval.list_scratch_top = mark
				return {}, false
			}
			if eq {
				seen = true
				break
			}
		}
		if !seen {
			if int(eval.list_scratch_top) >= len(eval.list_scratch) {
				eval.list_scratch_top = mark
				return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
			}
			eval.list_scratch[eval.list_scratch_top] = item
			eval.list_scratch_top += 1
		}
	}
	cnt := int(eval.list_scratch_top - mark)
	eval.list_scratch_top = mark
	if cnt > len(eval.list_items) - eval.list_item_count {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	first := eval.list_item_count
	copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(cnt)])
	eval.list_item_count += cnt
	return {kind = .List, data = u64(first), meta = u32(cnt)}, true
}

@(private)
vm_start_sort_by :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, list_val, fn_val: Value, dst_reg: u8, node_idx: lex_parser.Node_Index) -> bool {
	if list_val.kind != .List {
		refuse(eval, {refusal = .Not_A_List, chunk_id = frame.chunk_id, node = node_idx, command = SORT_BY_NAME, parameter = 1, left_kind = list_val.kind})
		return false
	}
	if fn_val.kind != .Function {
		refuse(eval, {refusal = .Not_A_Function, chunk_id = frame.chunk_id, node = node_idx, command = SORT_BY_NAME, parameter = 2, left_kind = fn_val.kind})
		return false
	}
	cl := eval.closures[int(fn_val.data)]
	cchunk := &eval.chunks[cl.chunk_id]
	cproto := &eval.protos[int(cchunk.proto_start) + int(cl.proto_id)]
	if !fn_arity_accepts_positional(cproto, 1) {
		refuse(eval, {refusal = .Function_Arguments, chunk_id = frame.chunk_id, node = node_idx, command = SORT_BY_NAME, parameter = 2, left = 1, right = i64(cproto.param_count)})
		return false
	}
	cnt := list_val.meta
	if cnt == 0 {
		eval.reg_stack[int(frame.reg_base) + int(dst_reg)] = {kind = .List, data = u64(eval.list_item_count), meta = 0}
		return true
	}
	if eval.frame_count >= len(eval.frames) || int(eval.reg_top) + 1 > len(eval.reg_stack) {
		refuse(eval, {refusal = .Calls_Full, chunk_id = frame.chunk_id, node = node_idx})
		return false
	}
	reg_base := eval.reg_top
	eval.reg_top += 1
	f := &eval.frames[eval.frame_count]
	f^ = {
		kind          = .Sort_By,
		dst_reg       = dst_reg,
		chunk_id      = frame.chunk_id,
		reg_base      = reg_base,
		let_base      = eval.let_slot_top,
		return_thunk  = NO_THUNK,
		cont_list_off = u32(list_val.data),
		cont_count    = cnt,
		cont_index    = 0,
		cont_out_off  = eval.list_scratch_top,
		cont_fn       = fn_val,
		cont_node     = node_idx,
	}
	eval.frame_count += 1
	return true
}

@(private)
sort_keys_leq :: proc "contextless" (eval: ^Evaluation, a, b: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (leq: bool, ok: bool) {
	if a.kind == .Integer {
		lu, ru := value_unit(a), value_unit(b)
		la, ra, _, status := align_integer_units(value_integer(a), value_integer(b), lu, ru)
		switch status {
		case .Ok:
			return la <= ra, true
		case .Overflow:
			refuse(eval, {refusal = .Overflow, chunk_id = chunk_id, node = node_idx, command = SORT_BY_NAME, left = value_integer(a), right = value_integer(b)})
			return false, false
		case .Incompatible, .Non_Exact:
			refuse(eval, {refusal = .Unit_Mismatch, chunk_id = chunk_id, node = node_idx, command = SORT_BY_NAME, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
			return false, false
		}
	}
	lt := value_text(eval, a)
	rt := value_text(eval, b)
	if !charge_steps(eval, u32(min(len(lt), len(rt)) / 64), chunk_id, node_idx) {
		return false, false
	}
	return str_cmp(lt, rt) <= 0, true
}

// vm_finish_sort_by runs an iterative bottom-up stable merge sort over keys
// collected in `eval.list_scratch[mark : mark + n]` with zero stack recursion.
@(private)
vm_finish_sort_by :: proc "contextless" (eval: ^Evaluation, frame: ^VM_Frame, target_depth: int) -> bool {
	mark := frame.cont_out_off
	n := int(frame.cont_count)
	keys := eval.list_scratch[mark:mark + u32(n)]
	k0 := keys[0]
	if k0.kind != .Integer && k0.kind != .Text {
		eval.list_scratch_top = mark
		refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = frame.cont_node, command = SORT_BY_NAME, left_kind = k0.kind})
		return false
	}
	for i in 1 ..< n {
		if keys[i].kind != k0.kind {
			eval.list_scratch_top = mark
			refuse(eval, {refusal = .Operator_Kinds, chunk_id = frame.chunk_id, node = frame.cont_node, command = SORT_BY_NAME, left_kind = k0.kind, right_kind = keys[i].kind})
			return false
		}
		if k0.kind == .Integer {
			lu, ru := value_unit(k0), value_unit(keys[i])
			_, _, _, status := align_integer_units(value_integer(k0), value_integer(keys[i]), lu, ru)
			switch status {
			case .Ok:
			case .Overflow:
				eval.list_scratch_top = mark
				refuse(eval, {refusal = .Overflow, chunk_id = frame.chunk_id, node = frame.cont_node, command = SORT_BY_NAME, left = value_integer(k0), right = value_integer(keys[i])})
				return false
			case .Incompatible, .Non_Exact:
				eval.list_scratch_top = mark
				refuse(eval, {refusal = .Unit_Mismatch, chunk_id = frame.chunk_id, node = frame.cont_node, command = SORT_BY_NAME, left_kind = .Integer, right_kind = .Integer, left_unit = lu, right_unit = ru})
				return false
			}
		}
	}
	if n == 1 {
		eval.list_scratch_top = mark
		vm_return_to_caller(eval, target_depth, {kind = .List, data = u64(frame.cont_list_off), meta = 1})
		return true
	}
	// Pack two u32 index arrays (2*n u32s) into the remaining Value slots of list_scratch.
	idx_val_slots := (2 * n + 3) / 4
	if int(mark) + n + idx_val_slots > len(eval.list_scratch) || n > len(eval.list_items) - eval.list_item_count {
		eval.list_scratch_top = mark
		refuse(eval, {refusal = .Lists_Full, chunk_id = frame.chunk_id, node = frame.cont_node})
		return false
	}
	raw_u32 := ([^]u32)(&eval.list_scratch[int(mark) + n])
	src := raw_u32[:n]
	dst := raw_u32[n:2 * n]
	for i in 0 ..< n {
		src[i] = u32(i)
	}
	for width := 1; width < n; width *= 2 {
		if !charge_steps(eval, u32(1 + n), frame.chunk_id, frame.cont_node) {
			eval.list_scratch_top = mark
			return false
		}
		for left := 0; left < n; left += 2 * width {
			mid := min(left + width, n)
			right := min(left + 2 * width, n)
			i, j, k := left, mid, left
			for i < mid && j < right {
				leq, ok := sort_keys_leq(eval, keys[src[i]], keys[src[j]], frame.chunk_id, frame.cont_node)
				if !ok {
					eval.list_scratch_top = mark
					return false
				}
				if leq {
					dst[k] = src[i]
					i += 1
				} else {
					dst[k] = src[j]
					j += 1
				}
				k += 1
			}
			for i < mid {
				dst[k] = src[i]
				i += 1
				k += 1
			}
			for j < right {
				dst[k] = src[j]
				j += 1
				k += 1
			}
		}
		src, dst = dst, src
	}
	first := eval.list_item_count
	orig := eval.list_items[int(frame.cont_list_off):int(frame.cont_list_off) + n]
	for i in 0 ..< n {
		eval.list_items[first + i] = orig[src[i]]
	}
	eval.list_item_count += n
	eval.list_scratch_top = mark
	vm_return_to_caller(eval, target_depth, {kind = .List, data = u64(first), meta = u32(n)})
	return true
}

// ---- Core pure Text stdlib functions (`split`, `join_text`, `starts_with`, `ends_with`, `contains`, `replace_text`).

@(private)
find_substr :: proc "contextless" (eval: ^Evaluation, haystack, needle: string, start: int, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (pos: int, ok: bool) {
	if len(needle) == 0 {
		return start, true
	}
	if len(needle) > len(haystack) - start {
		return -1, true
	}
	limit := len(haystack) - len(needle)
	first := needle[0]
	comps := 0
	for i := start; i <= limit; i += 1 {
		comps += 1
		if haystack[i] == first {
			matched := true
			for k := 1; k < len(needle); k += 1 {
				comps += 1
				if haystack[i + k] != needle[k] {
					matched = false
					break
				}
				if comps >= 16 {
					if !charge_steps(eval, u32(comps >> 4), chunk_id, node_idx) {
						return -1, false
					}
					comps &= 15
				}
			}
			if matched {
				if comps > 0 {
					if !charge_steps(eval, u32((comps + 15) >> 4), chunk_id, node_idx) {
						return -1, false
					}
				}
				return i, true
			}
		}
		if comps >= 16 {
			if !charge_steps(eval, u32(comps >> 4), chunk_id, node_idx) {
				return -1, false
			}
			comps &= 15
		}
	}
	if comps > 0 {
		if !charge_steps(eval, u32((comps + 15) >> 4), chunk_id, node_idx) {
			return -1, false
		}
	}
	return -1, true
}

@(private)
vm_builtin_split :: proc "contextless" (eval: ^Evaluation, text_val, sep_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if text_val.kind != .Text || sep_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = SPLIT_NAME, left_kind = text_val.kind, right_kind = sep_val.kind})
	}
	txt := value_text(eval, text_val)
	sep := value_text(eval, sep_val)
	if len(sep) == 0 {
		return refuse(eval, {refusal = .Empty_Separator, chunk_id = chunk_id, node = node_idx, command = SPLIT_NAME})
	}
	if !charge_steps(eval, 1, chunk_id, node_idx) {
		return {}, false
	}
	mark := eval.list_scratch_top
	pos := 0
	for {
		hit, fok := find_substr(eval, txt, sep, pos, chunk_id, node_idx)
		if !fok {
			eval.list_scratch_top = mark
			return {}, false
		}
		seg := hit < 0 ? txt[pos:] : txt[pos:hit]
		if !charge_steps(eval, u32(1 + len(seg) / 64), chunk_id, node_idx) {
			eval.list_scratch_top = mark
			return {}, false
		}
		tv, tok := text_arena_alloc(eval, seg)
		if !tok {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		if int(eval.list_scratch_top) >= len(eval.list_scratch) {
			eval.list_scratch_top = mark
			return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
		}
		eval.list_scratch[eval.list_scratch_top] = tv
		eval.list_scratch_top += 1
		if hit < 0 {
			break
		}
		pos = hit + len(sep)
	}
	cnt := int(eval.list_scratch_top - mark)
	eval.list_scratch_top = mark
	if cnt > len(eval.list_items) - eval.list_item_count {
		return refuse(eval, {refusal = .Lists_Full, chunk_id = chunk_id, node = node_idx})
	}
	first := eval.list_item_count
	copy(eval.list_items[first:], eval.list_scratch[mark:mark + u32(cnt)])
	eval.list_item_count += cnt
	return {kind = .List, data = u64(first), meta = u32(cnt)}, true
}

@(private)
vm_builtin_join_text :: proc "contextless" (eval: ^Evaluation, list_val, sep_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if list_val.kind != .List {
		return refuse(eval, {refusal = .Not_A_List, chunk_id = chunk_id, node = node_idx, command = JOIN_TEXT_NAME, parameter = 1, left_kind = list_val.kind})
	}
	if sep_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = JOIN_TEXT_NAME, parameter = 2, left_kind = list_val.kind, right_kind = sep_val.kind})
	}
	items := list_items_of(eval, list_val)
	if len(items) == 0 {
		return value_text_arena(0, 0), true
	}
	sep := value_text(eval, sep_val)
	total := 0
	for item, i in items {
		if item.kind != .Text {
			return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = JOIN_TEXT_NAME, left_kind = item.kind})
		}
		seg := value_text(eval, item)
		if i > 0 {
			if len(sep) > len(eval.text_arena) - eval.text_used - total {
				return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
			}
			total += len(sep)
		}
		if len(seg) > len(eval.text_arena) - eval.text_used - total {
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		total += len(seg)
	}
	if !charge_steps(eval, u32(1 + len(items) + total / 64), chunk_id, node_idx) {
		return {}, false
	}
	start := eval.text_used
	cur := start
	for item, i in items {
		if i > 0 && len(sep) > 0 {
			copy(eval.text_arena[cur:], sep)
			cur += len(sep)
		}
		seg := value_text(eval, item)
		if len(seg) > 0 {
			copy(eval.text_arena[cur:], seg)
			cur += len(seg)
		}
	}
	eval.text_used = cur
	return value_text_arena(u32(start), u32(cur - start)), true
}

@(private)
vm_builtin_starts_with :: proc "contextless" (eval: ^Evaluation, text_val, prefix_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if text_val.kind != .Text || prefix_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = STARTS_WITH_NAME, left_kind = text_val.kind, right_kind = prefix_val.kind})
	}
	txt := value_text(eval, text_val)
	pre := value_text(eval, prefix_val)
	if !charge_steps(eval, u32(1 + len(pre) / 64), chunk_id, node_idx) {
		return {}, false
	}
	return value_bool(len(pre) <= len(txt) && txt[:len(pre)] == pre), true
}

@(private)
vm_builtin_ends_with :: proc "contextless" (eval: ^Evaluation, text_val, suffix_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if text_val.kind != .Text || suffix_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = ENDS_WITH_NAME, left_kind = text_val.kind, right_kind = suffix_val.kind})
	}
	txt := value_text(eval, text_val)
	suf := value_text(eval, suffix_val)
	if !charge_steps(eval, u32(1 + len(suf) / 64), chunk_id, node_idx) {
		return {}, false
	}
	return value_bool(len(suf) <= len(txt) && txt[len(txt) - len(suf):] == suf), true
}

@(private)
vm_builtin_contains :: proc "contextless" (eval: ^Evaluation, text_val, needle_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if text_val.kind != .Text || needle_val.kind != .Text {
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = CONTAINS_NAME, left_kind = text_val.kind, right_kind = needle_val.kind})
	}
	txt := value_text(eval, text_val)
	needle := value_text(eval, needle_val)
	if !charge_steps(eval, 1, chunk_id, node_idx) {
		return {}, false
	}
	hit, fok := find_substr(eval, txt, needle, 0, chunk_id, node_idx)
	if !fok {
		return {}, false
	}
	return value_bool(hit >= 0), true
}

@(private)
vm_builtin_replace_text :: proc "contextless" (eval: ^Evaluation, text_val, old_val, new_val: Value, chunk_id: u16, node_idx: lex_parser.Node_Index) -> (Value, bool) {
	if text_val.kind != .Text || old_val.kind != .Text || new_val.kind != .Text {
		bad := text_val.kind != .Text ? text_val.kind : (old_val.kind != .Text ? old_val.kind : new_val.kind)
		return refuse(eval, {refusal = .Operator_Kinds, chunk_id = chunk_id, node = node_idx, command = REPLACE_TEXT_NAME, left_kind = bad})
	}
	txt := value_text(eval, text_val)
	old_s := value_text(eval, old_val)
	new_s := value_text(eval, new_val)
	if len(old_s) == 0 {
		return refuse(eval, {refusal = .Empty_Separator, chunk_id = chunk_id, node = node_idx, command = REPLACE_TEXT_NAME})
	}
	if !charge_steps(eval, 1, chunk_id, node_idx) {
		return {}, false
	}
	start := eval.text_used
	cur := start
	pos := 0
	for {
		hit, fok := find_substr(eval, txt, old_s, pos, chunk_id, node_idx)
		if !fok {
			return {}, false
		}
		seg := hit < 0 ? txt[pos:] : txt[pos:hit]
		piece_bytes := len(seg) + (hit >= 0 ? len(new_s) : 0)
		if !charge_steps(eval, u32(1 + piece_bytes / 64), chunk_id, node_idx) {
			return {}, false
		}
		if len(seg) > len(eval.text_arena) - cur {
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		if len(seg) > 0 {
			copy(eval.text_arena[cur:], seg)
			cur += len(seg)
		}
		if hit < 0 {
			break
		}
		if len(new_s) > len(eval.text_arena) - cur {
			return refuse(eval, {refusal = .Calls_Full, chunk_id = chunk_id, node = node_idx})
		}
		if len(new_s) > 0 {
			copy(eval.text_arena[cur:], new_s)
			cur += len(new_s)
		}
		pos = hit + len(old_s)
	}
	eval.text_used = cur
	return value_text_arena(u32(start), u32(cur - start)), true
}
