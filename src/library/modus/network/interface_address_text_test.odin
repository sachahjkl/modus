#+build !freestanding
#+build !modus
package network

import "core:testing"

// The texts of an address at their edges: each part at 0 and 255, one past
// 255, a zero before a digit, a part of four digits, three or five parts, an
// empty part, a byte that is no digit, the longest text and one byte past
// it; the prefix missing, empty, of three digits, with a zero before it, 0,
// 32 and 33; then the rules of interface_address_check through the texts.
@(test)
an_address_of_a_plan_is_read_at_its_edges :: proc(t: ^testing.T) {
	for text in ([?]string{"", "1.2.3", "1.2.3.4.5", "1..3.4", ".1.2.3", "1.2.3.", "256.0.0.1", "1.2.3.256", "01.2.3.4", "1.2.3.0004", "1.2.3.a", "1.2.3.4 ", " 1.2.3.4", "1.2.3.-4", "1000.2.3.4"}) {
		_, ok := address_of_text(text)
		testing.expectf(t, !ok, "%q is read", text)
	}
	for item in ([?]struct {
			text:    string,
			address: u32,
		}{{"0.0.0.0", 0}, {"255.255.255.255", 0xFFFF_FFFF}, {"10.0.2.15", 0x0A00_020F}, {"192.168.100.1", 0xC0A8_6401}}) {
		address, ok := address_of_text(item.text)
		testing.expectf(t, ok && address == item.address, "%q gives %x", item.text, address)
	}
	Case :: struct {
		address, gateway: string,
		problem:          Interface_Text_Problem,
	}
	cases := [?]Case {
		{"10.0.2.15", "10.0.2.2", .Prefix_Text},
		{"10.0.2.15/", "10.0.2.2", .Prefix_Text},
		{"10.0.2.15/024", "10.0.2.2", .Prefix_Text}, // A prefix of three digits.
		{"192.168.100.200/240", "192.168.100.1", .Address_Text}, // 19 bytes: one past the longest text.
		{"10.0.2.15/04", "10.0.2.2", .Prefix_Text},
		{"10.0.2.15/2a", "10.0.2.2", .Prefix_Text},
		{"10.0.2.15/0", "10.0.2.2", .Prefix_Length},
		{"10.0.2.15/33", "10.0.2.2", .Prefix_Length},
		{"10.0.2.x/24", "10.0.2.2", .Address_Text},
		{"255.255.255.255/32x", "10.0.2.2", .Address_Text},
		{"10.0.2.15/24", "", .Gateway_Text},
		{"10.0.2.15/24", "10.0.2", .Gateway_Text},
		{"0.0.0.0/24", "10.0.2.2", .Local_Address},
		{"10.0.2.0/24", "10.0.2.2", .Local_Address},
		{"10.0.2.255/24", "10.0.2.2", .Local_Address},
		{"224.0.0.1/24", "224.0.0.2", .Local_Address},
		{"10.0.2.15/24", "10.0.3.2", .Gateway},
		{"10.0.2.15/24", "10.0.2.15", .Gateway},
		{"10.0.2.15/24", "0.0.0.0", .Gateway},
		{"10.0.2.15/24", "10.0.2.255", .Gateway},
		{"10.0.2.15/32", "10.0.2.2", .Gateway},
	}
	for item in cases {
		_, _, problem := interface_address_of_text(item.address, item.gateway)
		testing.expectf(t, problem == item.problem, "%q %q gives %v, not %v", item.address, item.gateway, problem, item.problem)
	}
	// The longest text, and networks of each kind.
	longest, longest_mask, longest_problem := interface_address_of_text("192.168.100.200/24", "192.168.100.1")
	testing.expect(t, longest_problem == .None && longest.local == 0xC0A8_64C8 && longest.prefix_length == 24 && longest_mask == 0xFFFF_FF00)
	for item in ([?][2]string{{"10.0.2.15/24", "10.0.2.2"}, {"10.1.2.3/16", "10.1.0.1"}, {"10.0.0.2/31", "10.0.0.3"}, {"172.16.5.4/22", "172.16.4.1"}}) {
		_, _, problem := interface_address_of_text(item[0], item[1])
		testing.expectf(t, problem == .None, "%v gives %v", item, problem)
	}
}
