#+build !freestanding
#+build !modus
package plans_recipes

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
loop_hash :: proc(tag: u8) -> blake3.Hash {
	data := [2]u8{'p', tag}
	return blake3.hash(data[:])
}

@(test)
c_build_recipe_refuses_a_name_that_no_tree_takes :: proc(t: ^testing.T) {
	long_name: [MAX_ENTRY_NAME_BYTES + 1]u8
	for &byte in long_name {
		byte = 'a'
	}
	names := [?]string{"", string(long_name[:]), "a/b.c", "..", "."}
	for name in names {
		spec: Recipe_Spec
		spec.input_count = 7
		refusal := c_build_recipe(loop_hash(1), loop_hash(2), name, loop_hash(3), &spec)
		testing.expectf(t, refusal != .None, "the name %q is refused", name)
		testing.expect_value(t, spec, Recipe_Spec{})
	}
	// A source of zero bytes has a hash; a zero hash names no input.
	spec: Recipe_Spec
	testing.expect_value(t, c_build_recipe(loop_hash(1), loop_hash(2), "hello.c", {}, &spec), Recipe_Refusal.Zero_Input_Hash)
}

@(test)
c_build_recipe_names_the_compiler_the_assembler_and_the_source :: proc(t: ^testing.T) {
	spec: Recipe_Spec
	testing.expect_value(t, c_build_recipe(loop_hash(1), loop_hash(2), "hello.c", loop_hash(3), &spec), Recipe_Refusal.None)
	base, refusal := recipe_hash(&spec)
	testing.expect_value(t, refusal, Recipe_Refusal.None)
	changed := [?][3]u8{{9, 2, 3}, {1, 9, 3}, {1, 2, 9}}
	for parts in changed {
		other: Recipe_Spec
		testing.expect_value(t, c_build_recipe(loop_hash(parts[0]), loop_hash(parts[1]), "hello.c", loop_hash(parts[2]), &other), Recipe_Refusal.None)
		other_hash, _ := recipe_hash(&other)
		testing.expectf(t, other_hash != base, "a change of %v changes the recipe", parts)
	}
	other: Recipe_Spec
	_ = c_build_recipe(loop_hash(1), loop_hash(2), "other.c", loop_hash(3), &other)
	other_hash, _ := recipe_hash(&other)
	testing.expect(t, other_hash != base, "another name of the source is another recipe")
	// The same parts give the same recipe, last.
	same: Recipe_Spec
	_ = c_build_recipe(loop_hash(1), loop_hash(2), "hello.c", loop_hash(3), &same)
	same_hash, _ := recipe_hash(&same)
	testing.expect_value(t, same_hash, base)
	testing.expect(t, c_builder_hash(loop_hash(1), loop_hash(2)) != c_builder_hash(loop_hash(2), loop_hash(1)), "the order of the compiler and the assembler counts")
}

@(test)
project_new_evaluation_is_a_project_with_its_store :: proc(t: ^testing.T) {
	small: [20]u8
	_, small_ok := project_new_evaluation("hello", small[:])
	testing.expect(t, !small_ok, "a buffer too small is refused")
	buffer: [PROJECT_NEW_EVALUATION_BYTES]u8
	written, ok := project_new_evaluation("hello", buffer[:])
	testing.expect(t, ok)
	name := "hello"
	declaration: Project_Declaration
	testing.expect_value(t, project_declaration_of_evaluation(transmute([]u8)name, buffer[:written], &declaration), Project_Refusal.None)
	testing.expect_value(t, declaration.console_store_count, u32(1))
	testing.expect(t, declaration.has_console_field)
	testing.expect(t, declaration.project_tree_hash != {}, "the empty tree has a hash")
}
