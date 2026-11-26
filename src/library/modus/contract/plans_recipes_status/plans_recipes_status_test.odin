#+build !freestanding
#+build !modus
package plans_recipes_status

import "core:testing"

@(test)
status_word_borders_refuse_zero_and_out_of_range :: proc(t: ^testing.T) {
	for bad in ([?]u64{0, u64(max(Generation_Standing)) + 1, max(u64)}) {
		_, ok := generation_standing_of_word(bad)
		testing.expectf(t, !ok, "generation_standing_of_word must refuse %d", bad)
	}
	for bad in ([?]u64{0, u64(max(Plan_Consent)) + 1, max(u64)}) {
		_, ok := plan_consent_of_word(bad)
		testing.expectf(t, !ok, "plan_consent_of_word must refuse %d", bad)
	}
	for bad in ([?]u64{0, u64(max(Recipe_Object_Kind)) + 1, max(u64)}) {
		_, ok := recipe_object_kind_of_word(bad)
		testing.expectf(t, !ok, "recipe_object_kind_of_word must refuse %d", bad)
	}
	for bad in ([?]u64{0, u64(max(Recipe_Build_Outcome)) + 1, max(u64)}) {
		_, ok := recipe_build_outcome_of_word(bad)
		testing.expectf(t, !ok, "recipe_build_outcome_of_word must refuse %d", bad)
	}
	for bad in ([?]u64{0, u64(max(Provenance_Origin)) + 1, max(u64)}) {
		_, ok := provenance_origin_of_word(bad)
		testing.expectf(t, !ok, "provenance_origin_of_word must refuse %d", bad)
	}
	for bad in ([?]u64{0, u64(max(Recipe_Refusal)) + 1, max(u64)}) {
		_, ok := recipe_refusal_of_word(bad)
		testing.expectf(t, !ok, "recipe_refusal_of_word must refuse %d", bad)
	}

	standing, sok := generation_standing_of_word(u64(Generation_Standing.Current))
	testing.expect(t, sok && standing == .Current)
	consent, cok := plan_consent_of_word(u64(Plan_Consent.Needed))
	testing.expect(t, cok && consent == .Needed)
	kind, kok := recipe_object_kind_of_word(u64(Recipe_Object_Kind.Tree))
	testing.expect(t, kok && kind == .Tree)
	outcome, ook := recipe_build_outcome_of_word(u64(Recipe_Build_Outcome.Built_Locally))
	testing.expect(t, ook && outcome == .Built_Locally)
	origin, pok := provenance_origin_of_word(u64(Provenance_Origin.Remote_Cache))
	testing.expect(t, pok && origin == .Remote_Cache)
	refusal, rok := recipe_refusal_of_word(u64(Recipe_Refusal.Build_Cancelled))
	testing.expect(t, rok && refusal == .Build_Cancelled)
}
