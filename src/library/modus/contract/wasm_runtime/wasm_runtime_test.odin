#+build !freestanding
package wasm_runtime

import "core:testing"

@(test)
wasm_module_executes_arithmetic_memory_and_enforces_sandbox_bounds :: proc(t: ^testing.T) {
	_, bad_ref := wasm_refusal_of_word(99)
	testing.expect(t, !bad_ref)

	// Bad magic & version refused.
	mod: Wasm_Module
	testing.expect_value(t, wasm_module_parse([]u8{0, 0, 0, 0, 1, 0, 0, 0}, &mod), Wasm_Refusal.Bad_Magic)
	testing.expect_value(t, wasm_module_parse([]u8{0x00, 'a', 's', 'm', 2, 0, 0, 0}, &mod), Wasm_Refusal.Bad_Version)

	// Valid WASM module:
	//   type 0: (i32, i32) -> i32
	//   import 0: env.scale (type 0)
	//   func 1 (export "add_and_store"): stores (a + b) at linear memory[0], returns env.scale(a + b, 3)
	//   func 2 (export "oob"): loads from address 65534 (4 bytes -> OOB past 65536!)
	//   memory 0: min 1 page (65536 bytes)
	wasm := [?]u8{
		0x00, 'a', 's', 'm', 0x01, 0x00, 0x00, 0x00,
		// Section 1 (Type): 1 type: (i32, i32) -> i32
		0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
		// Section 2 (Import): 1 func import "env"."scale" type 0
		0x02, 0x0D, 0x01, 0x03, 'e', 'n', 'v', 0x05, 's', 'c', 'a', 'l', 'e', 0x00, 0x00,
		// Section 3 (Function): 2 defined funcs, both type 0
		0x03, 0x03, 0x02, 0x00, 0x00,
		// Section 5 (Memory): 1 memory, min 1 page
		0x05, 0x03, 0x01, 0x00, 0x01,
		// Section 7 (Export): "add_and_store" -> func 1, "oob" -> func 2 (1 + 16 + 6 = 23 = 0x17)
		0x07, 0x17, 0x02,
			0x0D, 'a', 'd', 'd', '_', 'a', 'n', 'd', '_', 's', 't', 'o', 'r', 'e', 0x00, 0x01,
			0x03, 'o', 'o', 'b', 0x00, 0x02,
		// Section 10 (Code): 2 bodies (1 + 25 + 10 = 36 = 0x24)
		0x0A, 0x24, 0x02,
			// Body 0 (func 1, 24 = 0x18 bytes):
			//   local.get 0; local.get 1; i32.add; local.set 2 (extra local)
			//   i32.const 0; local.get 2; i32.store align=2 offset=0
			//   local.get 2; i32.const 3; call 0; end
			0x18, 0x01, 0x01, 0x7F,
			0x20, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x02,
			0x41, 0x00, 0x20, 0x02, 0x36, 0x02, 0x00,
			0x20, 0x02, 0x41, 0x03, 0x10, 0x00, 0x0B,
			// Body 1 (func 2, 9 = 0x09 bytes): i32.const 0; i32.load align=2 offset=65534 (0xFE 0xFF 0x03); end
			0x09, 0x00, 0x41, 0x00, 0x28, 0x02, 0xFE, 0xFF, 0x03, 0x0B,
	}

	testing.expect_value(t, wasm_module_parse(wasm[:], &mod), Wasm_Refusal.None)
	testing.expect(t, mod.valid)

	mem := make([]u8, WASM_PAGE_SIZE)
	defer delete(mem)

	// Without granting env.scale import, execution is strictly refused!
	_, r_no_grant := wasm_execute_export(wasm[:], &mod, "add_and_store", []i64{10, 5}, mem, 1000, nil)
	testing.expect_value(t, r_no_grant, Wasm_Refusal.Import_Not_Granted)

	// Granting env.scale lets it run and write (10 + 5 = 15) to memory[0..4] and return 15 * 3 = 45!
	scale_cb :: proc "contextless" (m, f: string, args: []i64, _: rawptr) -> (i64, bool) {
		if m == "env" && f == "scale" && len(args) == 2 {
			return args[0] * args[1], true
		}
		return 0, false
	}
	res, r_ok := wasm_execute_export(wasm[:], &mod, "add_and_store", []i64{10, 5}, mem, 1000, scale_cb)
	testing.expect_value(t, r_ok, Wasm_Refusal.None)
	testing.expect_value(t, res, i64(45))
	testing.expect_value(t, mem[0], u8(15))

	// Linear memory OOB trapped cleanly.
	_, r_oob := wasm_execute_export(wasm[:], &mod, "oob", []i64{0, 0}, mem, 1000, scale_cb)
	testing.expect_value(t, r_oob, Wasm_Refusal.Trap_Memory_Oob)

	// Fuel exhaustion trapped cleanly.
	_, r_fuel := wasm_execute_export(wasm[:], &mod, "add_and_store", []i64{1, 2}, mem, 2, scale_cb)
	testing.expect_value(t, r_fuel, Wasm_Refusal.Trap_Out_Of_Fuel)
}
