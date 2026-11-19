package build

import "core:testing"
import "modustool:foundation"

// A fact type of this test: a record type of the package scope with the
// attribute of a fact type. The compile of the host tests gives the flag
// of the attribute (foundation.LOG_FACT_ATTRIBUTE_FLAG), or the compiler
// refuses this declaration ("Unknown attribute element name").
@(log_fact = "build: the probe {value} of the fact key")
Fact_Key_Probe :: struct {
	value: u64,
}

// A second record type of the same package, with no attribute: its key
// must differ from the key of the probe.
Fact_Key_Other :: struct {
	value: u64,
}

// SipHash-2-4 gives the vectors of its paper (Aumasson and Bernstein,
// appendix A): the key 00..0F, and the messages of 15 bytes 00..0E and of
// no byte. The edges of the last word: 7, 8 and 9 bytes differ from each
// other.
@(test)
siphash_gives_the_vectors_of_its_paper :: proc(t: ^testing.T) {
	k0 := u64(0x0706_0504_0302_0100)
	k1 := u64(0x0f0e_0d0c_0b0a_0908)
	message: [16]u8
	for &byte_value, index in message {
		byte_value = u8(index)
	}
	testing.expect_value(t, siphash_2_4(message[:15], k0, k1), u64(0xa129_ca61_49be_45e5))
	testing.expect_value(t, siphash_2_4(message[:0], k0, k1), u64(0x726f_db47_dd0e_0e31))
	seven, eight, nine := siphash_2_4(message[:7], k0, k1), siphash_2_4(message[:8], k0, k1), siphash_2_4(message[:9], k0, k1)
	testing.expect(t, seven != eight && eight != nine && seven != nine)
}

// The name of the package of this file, as the compiler writes it in the
// canonical name of its types.
@(private = "file")
FACT_KEY_TEST_PACKAGE :: "build"

// The key that the tool computes for a fact type is the typeid that the
// compiler gives it. A compiler with another seed of SipHash or another
// canonical name of a type fails here, before a module is built. Another
// name of the type, another package and a case of the name give another
// key, and no key is 0: a key of 0 names no fact type.
@(test)
the_fact_key_is_the_typeid_of_the_compiler :: proc(t: ^testing.T) {
	probe := fact_key(FACT_KEY_TEST_PACKAGE, "Fact_Key_Probe")
	testing.expect_value(t, probe, transmute(u64)typeid_of(Fact_Key_Probe))
	testing.expect_value(t, fact_key(FACT_KEY_TEST_PACKAGE, "Fact_Key_Other"), transmute(u64)typeid_of(Fact_Key_Other))
	testing.expect(t, probe != 0)
	others := [?][2]string {
		{FACT_KEY_TEST_PACKAGE, "Fact_Key_Other"},
		{"storage", "Fact_Key_Probe"},
		{FACT_KEY_TEST_PACKAGE, "fact_key_probe"},
		{FACT_KEY_TEST_PACKAGE, ""},
		{"", "Fact_Key_Probe"},
		{"", ""},
	}
	for other in others {
		key := fact_key(other[0], other[1])
		testing.expectf(t, key != probe, "the name %s::%s has the key of the probe", other[0], other[1])
		testing.expectf(t, key != 0, "the name %s::%s has the key 0", other[0], other[1])
	}
}

// The value that the compiler of the flake gave for storage.Bad_Block in
// two builds (src/md/features/log_facts.md, "The fact key: why the
// typeid"): the tool gives the same with no compile of that package.
@(test)
the_fact_key_of_a_type_of_another_package :: proc(t: ^testing.T) {
	testing.expect_value(t, fact_key("storage", "Bad_Block"), 18017458693634389201)
}

// Each command of the tool that compiles a package of src/ accepts the
// attribute of a fact type: the compile of a module and of the kernel, of
// the boot program, and of the tool. A command without the flag would
// refuse the first fact type that a source declares.
@(test)
each_compile_accepts_the_attribute_of_a_fact_type :: proc(t: ^testing.T) {
	count_of_flag :: proc(command: []string) -> int {
		count := 0
		for word in command {
			count += int(word == foundation.LOG_FACT_ATTRIBUTE_FLAG)
		}
		return count
	}
	module_build := foundation.Module_Build{name = "sample", source = "src/modules/demonstrations/sample"}
	testing.expect_value(t, count_of_flag(module_compile_command(module_build)), 1)
	kernel_build := foundation.Module_Build{name = "kernel", source = foundation.SOURCE_FOLDER_KERNEL, kernel = true}
	testing.expect_value(t, count_of_flag(module_compile_command(kernel_build)), 1)
	testing.expect_value(t, count_of_flag(boot_program_compile_command(release_boot_volume())), 1)
	tool := TOOL_COMPILE_COMMAND
	testing.expect_value(t, count_of_flag(tool[:]), 1)
	testing.expect_value(t, foundation.LOG_FACT_ATTRIBUTE_FLAG, "-custom-attribute:log_fact")
}
