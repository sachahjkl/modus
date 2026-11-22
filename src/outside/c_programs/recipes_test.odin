#+build !freestanding
// The test of the recipes of the C programs (recipes/README.md): each recipe
// names a pinned source by its hash, the files of this folder that exist, and
// the flags of a module of C.
package c_programs

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Recipe_Key :: enum {
	Recipe,
	Version,
	Source,
	Source_Hash,
	Unpack,
	Root,
	Compile,
	Adapter,
	Include,
	Patch,
	Force_Include,
	Define,
	Flag,
	Test,
}

RECIPE_KEY_WORDS := [Recipe_Key]string {
	.Recipe        = "recipe",
	.Version       = "version",
	.Source        = "source",
	.Source_Hash   = "source_hash",
	.Unpack        = "unpack",
	.Root          = "root",
	.Compile       = "compile",
	.Adapter       = "adapter",
	.Include       = "include",
	.Patch         = "patch",
	.Force_Include = "force_include",
	.Define        = "define",
	.Flag          = "flag",
	.Test          = "test",
}

RECIPE_SINGLE_KEYS :: bit_set[Recipe_Key]{.Recipe, .Version, .Source, .Source_Hash, .Unpack, .Root}
RECIPE_REQUIRED_KEYS :: bit_set[Recipe_Key]{.Recipe, .Version, .Source, .Source_Hash, .Unpack, .Root, .Compile, .Adapter, .Flag, .Test}
// The keys whose values are paths of this folder.
RECIPE_PATH_KEYS :: bit_set[Recipe_Key]{.Adapter, .Include, .Patch, .Force_Include}

// The flags without which a C file reaches the host or its headers.
RECIPE_REQUIRED_FLAGS := [?]string{"--target=x86_64-unknown-none-elf", "-ffreestanding", "-nostdinc", "-fPIC", "-mlong-double-64", "-fno-stack-protector"}

Recipe_Text :: struct {
	file: string,
	text: string,
}

RECIPES := [?]Recipe_Text {
	{"sqlite.recipe", #load("recipes/sqlite.recipe", string)},
	{"lua.recipe", #load("recipes/lua.recipe", string)},
	{"zstd.recipe", #load("recipes/zstd.recipe", string)},
}

recipe_key_of_word :: proc(word: string) -> (key: Recipe_Key, ok: bool) {
	for candidate in Recipe_Key {
		if RECIPE_KEY_WORDS[candidate] == word {
			return candidate, true
		}
	}
	return {}, false
}

// recipe_check gives the first fault of a recipe, or "".
recipe_check :: proc(name: string, text: string) -> string {
	counts: [Recipe_Key]int
	flags := make([dynamic]string, context.temp_allocator)
	for line, index in strings.split_lines(text, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		colon := strings.index(trimmed, ": ")
		if colon <= 0 {
			return fmt.tprintf("line %d: no key", index + 1)
		}
		key, known := recipe_key_of_word(trimmed[:colon])
		if !known {
			return fmt.tprintf("line %d: the key %q is unknown", index + 1, trimmed[:colon])
		}
		value := strings.trim_space(trimmed[colon + 2:])
		if value == "" {
			return fmt.tprintf("line %d: the key %s has no value", index + 1, trimmed[:colon])
		}
		counts[key] += 1
		if key in RECIPE_SINGLE_KEYS && counts[key] > 1 {
			return fmt.tprintf("line %d: the key %s is written twice", index + 1, trimmed[:colon])
		}
		switch key {
		case .Recipe:
			if value != name {
				return fmt.tprintf("the recipe %q is in the file of %q", value, name)
			}
		case .Source:
			if !strings.has_prefix(value, "https://") {
				return fmt.tprintf("the source %q is not fetched over https", value)
			}
		case .Source_Hash:
			if !strings.has_prefix(value, "sha256-") || len(value) != len("sha256-") + 44 {
				return fmt.tprintf("the hash %q is not the SRI form of a SHA-256", value)
			}
			digest, error := base64.decode(value[len("sha256-"):], allocator = context.temp_allocator)
			if error != nil || len(digest) != 32 {
				return fmt.tprintf("the hash %q is not 32 bytes of base64", value)
			}
		case .Unpack:
			if value != "tar.gz" && value != "zip" {
				return fmt.tprintf("the form %q is not tar.gz or zip", value)
			}
		case .Flag:
			append(&flags, value)
		case .Define:
			if strings.index_byte(value, '=') <= 0 {
				return fmt.tprintf("the definition %q is not NAME=VALUE", value)
			}
		case .Adapter, .Include, .Patch, .Force_Include:
			path := strings.concatenate({folder_of_programs(), "/", value}, context.temp_allocator)
			if strings.contains(value, "..") || !os.exists(path) {
				return fmt.tprintf("the file %q of this folder does not exist", value)
			}
		case .Version, .Root, .Compile, .Test:
		}
	}
	for key in RECIPE_REQUIRED_KEYS {
		if counts[key] == 0 {
			return fmt.tprintf("the key %s is missing", RECIPE_KEY_WORDS[key])
		}
	}
	for required in RECIPE_REQUIRED_FLAGS {
		found := false
		for flag in flags {
			found ||= flag == required
		}
		if !found {
			return fmt.tprintf("the flag %s is missing", required)
		}
	}
	return ""
}

@(test)
recipes_name_pinned_sources_and_files_that_exist :: proc(t: ^testing.T) {
	for recipe in RECIPES {
		name := strings.trim_suffix(recipe.file, ".recipe")
		problem := recipe_check(name, recipe.text)
		testing.expectf(t, problem == "", "%s: %s", recipe.file, problem)
	}
}

@(test)
recipes_refuse_a_bad_recipe :: proc(t: ^testing.T) {
	good := RECIPES[0].text
	Case :: struct {
		text:    string,
		problem: string,
	}
	replace :: proc(text, old, new: string) -> string {
		result, _ := strings.replace(text, old, new, 1, context.temp_allocator)
		return result
	}
	cases := [?]Case {
		{replace(good, "unpack: zip", "unpack: rar"), "the form \"rar\" is not tar.gz or zip"},
		{replace(good, "source_hash: sha256-CpyONDUtrUYAaqgoNtU4O/+dxryc5aYFU8Baow5q0fk=", "source_hash: sha256-CpyONDUtrUYAaqgoNtU4O/+dxryc5aYFU8Baow5q0f="), "the hash \"sha256-CpyONDUtrUYAaqgoNtU4O/+dxryc5aYFU8Baow5q0f=\" is not the SRI form of a SHA-256"},
		{replace(good, "source_hash: sha256-", "source_hash: md5-"), ""},
		{replace(good, "source: https://", "source: http://"), ""},
		{replace(good, "adapter: sqlite/modus_vfs.c", "adapter: sqlite/missing.c"), "the file \"sqlite/missing.c\" of this folder does not exist"},
		{replace(good, "adapter: sqlite/modus_vfs.c", "adapter: ../../../flake.nix"), "the file \"../../../flake.nix\" of this folder does not exist"},
		{replace(good, "flag: -nostdinc\n", ""), "the flag -nostdinc is missing"},
		{replace(good, "recipe: sqlite", "recipe: lua"), "the recipe \"lua\" is in the file of \"sqlite\""},
		{strings.concatenate({good, "version: 9\n"}, context.temp_allocator), ""},
		{strings.concatenate({good, "colour: blue\n"}, context.temp_allocator), ""},
		{replace(good, "define: SQLITE_OS_OTHER=1", "define: SQLITE_OS_OTHER"), "the definition \"SQLITE_OS_OTHER\" is not NAME=VALUE"},
	}
	for test_case in cases {
		problem := recipe_check("sqlite", test_case.text)
		testing.expectf(t, problem != "", "a bad recipe must be refused: %q", test_case.problem)
		if test_case.problem != "" {
			testing.expect_value(t, problem, test_case.problem)
		}
	}
	// No test: refused.
	no_test := good
	for strings.contains(no_test, "\ntest: ") {
		start := strings.index(no_test, "\ntest: ")
		end := strings.index_byte(no_test[start + 1:], '\n')
		no_test = strings.concatenate({no_test[:start], no_test[start + 1 + end:]}, context.temp_allocator)
	}
	testing.expect_value(t, recipe_check("sqlite", no_test), "the key test is missing")
}
