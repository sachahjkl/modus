#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import ilp "modus:contract/interface_language_pack"

@(private = "file")
hash_of :: proc(value: u8) -> (hash: blake3.Hash) {
	hash[0] = value
	return hash
}

// A plan names a set before the read; a later plan with no entry, still
// before the read, gives the set back to the boot image (the rollback);
// with no set in the boot image, none. After the read began, each choice
// waits for the next start, and the set of this start stays.
@(test)
a_plan_with_no_entry_gives_the_set_back_to_the_image :: proc(t: ^testing.T) {
	image, planned := hash_of(1), hash_of(2)
	stage, named, outcome := script_fonts_plan_choice(.Named, image, image, planned)
	testing.expect(t, stage == .Named && named == planned && outcome == .Named_By_Plan)
	// The rollback before the read.
	stage, named, outcome = script_fonts_plan_choice(stage, named, image, {})
	testing.expect(t, stage == .Named && named == image && outcome == .Back_To_Image)
	// The same plan again changes nothing.
	_, _, outcome = script_fonts_plan_choice(stage, named, image, {})
	testing.expect_value(t, outcome, Script_Fonts_Outcome.Unchanged)
	_, _, outcome = script_fonts_plan_choice(.Named, planned, image, planned)
	testing.expect_value(t, outcome, Script_Fonts_Outcome.Unchanged)
	// No set in the image: a plan names one, then none.
	stage, named, outcome = script_fonts_plan_choice(.Unnamed, {}, {}, planned)
	testing.expect(t, stage == .Named && named == planned && outcome == .Named_By_Plan)
	stage, named, outcome = script_fonts_plan_choice(stage, named, {}, {})
	testing.expect(t, stage == .Unnamed && named == {} && outcome == .Unnamed_Again)
	// After the read began (including Fetch_Pending and Fetching): the next start, and nothing changes now.
	for later in ([5]Script_Fonts_Stage{.Reading, .Fetch_Pending, .Fetching, .Mapped, .Absent}) {
		stage, named, outcome = script_fonts_plan_choice(later, planned, image, {})
		testing.expectf(t, stage == later && named == planned && outcome == .Next_Start, "%v: %v %v", later, stage, outcome)
		stage, named, outcome = script_fonts_plan_choice(later, image, image, planned)
		testing.expectf(t, stage == later && named == image && outcome == .Next_Start, "%v: %v %v", later, stage, outcome)
	}
}

// Target precedence: Plan_Entry > Plan_Manifest > Boot_Image > None.
@(test)
script_fonts_target_precedence :: proc(t: ^testing.T) {
	entry_h, manifest_h, image_h := hash_of(10), hash_of(20), hash_of(30)

	target, exp_m, src := script_fonts_effective_target({}, {}, {})
	testing.expect(t, target == {} && !exp_m && src == .None)

	target, exp_m, src = script_fonts_effective_target({}, {}, image_h)
	testing.expect(t, target == image_h && !exp_m && src == .Boot_Image)

	target, exp_m, src = script_fonts_effective_target({}, manifest_h, image_h)
	testing.expect(t, target == manifest_h && exp_m && src == .Plan_Manifest)

	target, exp_m, src = script_fonts_effective_target(entry_h, manifest_h, image_h)
	testing.expect(t, target == entry_h && !exp_m && src == .Plan_Entry)
}

// Step state machine covers busy collisions, missing cache, disk-to-cache
// fallback, non-looping cache failure, and post-map disk persistence.
@(test)
script_fonts_step_and_fallback_transitions :: proc(t: ^testing.T) {
	// Not usable or disk_processes busy always waits regardless of stage.
	for st in Script_Fonts_Stage {
		testing.expect_value(t, script_fonts_step_decide(st, false, false, true, true, true), Script_Fonts_Step_Action.Wait)
		testing.expect_value(t, script_fonts_step_decide(st, true, true, true, true, true), Script_Fonts_Step_Action.Wait)
	}

	// Named with data disk reads disk first even if cache key is configured.
	testing.expect_value(t, script_fonts_step_decide(.Named, true, false, true, true, false), Script_Fonts_Step_Action.Read_Disk)
	testing.expect_value(t, script_fonts_step_decide(.Named, true, false, true, false, false), Script_Fonts_Step_Action.Read_Disk)

	// Named without data disk fetches directly from cache if configured, else Absent_Without_Disk.
	testing.expect_value(t, script_fonts_step_decide(.Named, true, false, false, true, false), Script_Fonts_Step_Action.Fetch_Cache)
	testing.expect_value(t, script_fonts_step_decide(.Named, true, false, false, false, false), Script_Fonts_Step_Action.Absent_Without_Disk)

	// Fetch_Pending fetches if cache configured, else Absent_Without_Cache.
	testing.expect_value(t, script_fonts_step_decide(.Fetch_Pending, true, false, true, true, false), Script_Fonts_Step_Action.Fetch_Cache)
	testing.expect_value(t, script_fonts_step_decide(.Fetch_Pending, true, false, true, false, false), Script_Fonts_Step_Action.Absent_Without_Cache)

	// Mapped with pending disk persistence stores only when data disk exists.
	testing.expect_value(t, script_fonts_step_decide(.Mapped, true, false, true, true, true), Script_Fonts_Step_Action.Store_Disk)
	testing.expect_value(t, script_fonts_step_decide(.Mapped, true, false, false, true, true), Script_Fonts_Step_Action.Wait)
	testing.expect_value(t, script_fonts_step_decide(.Mapped, true, false, true, true, false), Script_Fonts_Step_Action.Wait)

	// Disk miss fallback: Not_On_Disk and Hash_Differs fall back ONLY when cache key exists;
	// Read_Failed never falls back; non-Reading stages never change.
	next, fb := script_fonts_after_disk_miss(.Reading, false, .Not_On_Disk)
	testing.expect(t, next == .Absent && !fb)
	next, fb = script_fonts_after_disk_miss(.Reading, false, .Hash_Differs)
	testing.expect(t, next == .Absent && !fb)
	next, fb = script_fonts_after_disk_miss(.Reading, true, .Not_On_Disk)
	testing.expect(t, next == .Fetch_Pending && fb)
	next, fb = script_fonts_after_disk_miss(.Reading, true, .Hash_Differs)
	testing.expect(t, next == .Fetch_Pending && fb)
	next, fb = script_fonts_after_disk_miss(.Reading, true, .Read_Failed)
	testing.expect(t, next == .Absent && !fb)
	next, fb = script_fonts_after_disk_miss(.Fetching, true, .Not_On_Disk)
	testing.expect(t, next == .Fetching && !fb)

	// Cache failure settles permanently into Absent (never loops).
	testing.expect_value(t, script_fonts_after_cache_failure(.Fetching), Script_Fonts_Stage.Absent)
	testing.expect_value(t, script_fonts_after_cache_failure(.Mapped), Script_Fonts_Stage.Mapped)
}

// Adversarial Script_Font_Pack_Manifest resolution: refuses chained manifests,
// corrupt wire bytes, empty manifests, oversized byte_size, multiple distinct
// hashes, and mismatched sizes; accepts valid edges and multi-script sets.
@(test)
script_fonts_manifest_resolve_adversarial :: proc(t: ^testing.T) {
	wire: [4096]u8

	// 1. Magic detection refuses short or wrong prefix.
	testing.expect(t, !script_fonts_is_manifest_bytes(nil))
	testing.expect(t, !script_fonts_is_manifest_bytes(transmute([]u8)string("MODSFP0")))
	testing.expect(t, !script_fonts_is_manifest_bytes(transmute([]u8)string("OUTLINES")))

	// 2. Corrupted/truncated wire bytes refused with Decode_Failed.
	_, _, _, dec, ref := script_fonts_manifest_resolve(transmute([]u8)string("MODSFP01bad"), false)
	testing.expect(t, ref == .Decode_Failed && dec == .Buffer_Too_Small)

	// 3. Empty manifest (0 entries) refused with Empty_Manifest.
	empty := ilp.Script_Font_Pack_Manifest{unicode_version = 17, entry_count = 0}
	n, enc_ref := ilp.script_font_manifest_encode(&empty, wire[:])
	testing.expect_value(t, enc_ref, ilp.Pack_Manifest_Refusal.None)
	testing.expect(t, script_fonts_is_manifest_bytes(wire[:n]))
	_, _, _, _, ref = script_fonts_manifest_resolve(wire[:n], false)
	testing.expect_value(t, ref, Script_Fonts_Manifest_Refusal.Empty_Manifest)

	// 4. Oversized byte_size (SCRIPT_FONTS_BYTES_LIMIT + 1) refused.
	set_hash := hash_of(0x42)
	oversized := ilp.Script_Font_Pack_Manifest{
		unicode_version = 17,
		entry_count     = 1,
		entries         = {0 = {script = .Hebrew, object_hash = set_hash, byte_size = font_outlines.SCRIPT_FONTS_BYTES_LIMIT + 1}},
	}
	n, enc_ref = ilp.script_font_manifest_encode(&oversized, wire[:])
	testing.expect_value(t, enc_ref, ilp.Pack_Manifest_Refusal.None)
	_, _, _, _, ref = script_fonts_manifest_resolve(wire[:n], false)
	testing.expect_value(t, ref, Script_Fonts_Manifest_Refusal.Size_Over_Limit)

	// 5. Multiple distinct object hashes refused.
	multi := ilp.Script_Font_Pack_Manifest{
		unicode_version = 17,
		entry_count     = 2,
		entries         = {
			0 = {script = .Hebrew, object_hash = set_hash, byte_size = 4096},
			1 = {script = .Arabic, object_hash = hash_of(0x99), byte_size = 4096},
		},
	}
	n, enc_ref = ilp.script_font_manifest_encode(&multi, wire[:])
	testing.expect_value(t, enc_ref, ilp.Pack_Manifest_Refusal.None)
	_, _, _, _, ref = script_fonts_manifest_resolve(wire[:n], false)
	testing.expect_value(t, ref, Script_Fonts_Manifest_Refusal.Multiple_Distinct_Objects)

	// 6. Same hash with disagreeing byte_size refused.
	mismatch := ilp.Script_Font_Pack_Manifest{
		unicode_version = 17,
		entry_count     = 2,
		entries         = {
			0 = {script = .Hebrew, object_hash = set_hash, byte_size = 4096},
			1 = {script = .Arabic, object_hash = set_hash, byte_size = 8192},
		},
	}
	n, enc_ref = ilp.script_font_manifest_encode(&mismatch, wire[:])
	testing.expect_value(t, enc_ref, ilp.Pack_Manifest_Refusal.None)
	_, _, _, _, ref = script_fonts_manifest_resolve(wire[:n], false)
	testing.expect_value(t, ref, Script_Fonts_Manifest_Refusal.Size_Mismatch)

	// 7. Valid manifest at exact SCRIPT_FONTS_BYTES_LIMIT accepted, and refused if already_resolved (chain).
	valid := ilp.Script_Font_Pack_Manifest{
		unicode_version = 17,
		entry_count     = 4,
		entries         = {
			0 = {script = .Hebrew, object_hash = set_hash, byte_size = font_outlines.SCRIPT_FONTS_BYTES_LIMIT},
			1 = {script = .Arabic, object_hash = set_hash, byte_size = font_outlines.SCRIPT_FONTS_BYTES_LIMIT},
			2 = {script = .Han_Cjk, object_hash = set_hash, byte_size = font_outlines.SCRIPT_FONTS_BYTES_LIMIT},
			3 = {script = .Emoji, object_hash = set_hash, byte_size = font_outlines.SCRIPT_FONTS_BYTES_LIMIT},
		},
	}
	n, enc_ref = ilp.script_font_manifest_encode(&valid, wire[:])
	testing.expect_value(t, enc_ref, ilp.Pack_Manifest_Refusal.None)

	_, _, _, _, chain_ref := script_fonts_manifest_resolve(wire[:n], true)
	testing.expect_value(t, chain_ref, Script_Fonts_Manifest_Refusal.Manifest_Chain_Forbidden)

	got_hash, got_size, got_scripts, got_dec, got_ref := script_fonts_manifest_resolve(wire[:n], false)
	testing.expect(t, got_ref == .None && got_dec == .None)
	testing.expect_value(t, got_hash, set_hash)
	testing.expect_value(t, got_size, u64(font_outlines.SCRIPT_FONTS_BYTES_LIMIT))
	testing.expect_value(t, got_scripts, u32(4))
}
