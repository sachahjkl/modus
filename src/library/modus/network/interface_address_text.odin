package network

// The address of an interface as a plan of principal 0 writes it
// (src/md/features/dhcp_client.md, "The static address of the plan"): the
// address and its prefix, "10.0.2.15/24", and the gateway, "10.0.2.2". The
// texts are read here, then checked by interface_address_check, the one
// border of an address of an interface. Pure code: the host tests check it
// (interface_address_text_test.odin).
//
// Merge note: interface_address.odin and interface_address_test.odin are
// the files of work/limits_remote_and_network, byte for byte, so the merge
// adds them once and keeps one border. This file is of this branch only.

// The longest texts: "255.255.255.255" and "255.255.255.255/32".
ADDRESS_TEXT_BYTES_MOST :: 15
INTERFACE_TEXT_BYTES_MOST :: 18

// Why interface_address_of_text refused the texts of an interface.
Interface_Text_Problem :: enum u8 {
	None          = 0,
	Address_Text  = 1, // The address is not four numbers of 0 to 255 with a period between them, each with no zero before its first digit.
	Prefix_Text   = 2, // The address has no "/" and a number of 1 or 2 digits after it.
	Gateway_Text  = 3, // The gateway is not four numbers of 0 to 255 with a period between them.
	Prefix_Length = 4, // interface_address_check: a prefix of 0 bits, or past 32.
	Local_Address = 5, // interface_address_check: the address cannot be the address of a machine of its prefix.
	Gateway       = 6, // interface_address_check: the gateway is not on the link, or is the address.
}

// The words of each problem, for a line of the log and a sentence.
@(rodata)
INTERFACE_TEXT_PROBLEM_TEXTS := [Interface_Text_Problem]string {
	.None          = "",
	.Address_Text  = "the address is not written as 10.0.2.15/24",
	.Prefix_Text   = "the address has no prefix: write it as 10.0.2.15/24",
	.Gateway_Text  = "the gateway is not written as 10.0.2.2",
	.Prefix_Length = "the prefix is not 1 to 32 bits",
	.Local_Address = "no machine of its prefix can hold the address",
	.Gateway       = "the gateway is not on the link of the address, or is the address",
}

// address_of_text reads an IPv4 address: four numbers of 0 to 255, each of
// 1 to 3 digits with no zero before its first digit, a period between two
// of them, and nothing else.
address_of_text :: proc "contextless" (text: string) -> (address: u32, ok: bool) {
	if len(text) == 0 || len(text) > ADDRESS_TEXT_BYTES_MOST {
		return 0, false
	}
	part, digits, parts := u32(0), 0, 0
	for index in 0 ..= len(text) {
		if index == len(text) || text[index] == '.' {
			if digits == 0 || parts == 4 {
				return 0, false
			}
			address = address << 8 | part
			part, digits, parts = 0, 0, parts + 1
			continue
		}
		character := text[index]
		if character < '0' || character > '9' || digits == 3 || digits == 1 && part == 0 {
			return 0, false
		}
		part = part * 10 + u32(character - '0')
		digits += 1
		if part > 255 {
			return 0, false
		}
	}
	return address, parts == 4
}

// interface_address_of_text reads the address with its prefix and the
// gateway, then checks them with interface_address_check. mask is the mask
// of the prefix when problem is None.
interface_address_of_text :: proc "contextless" (address_text, gateway_text: string) -> (address: Interface_Address, mask: u32, problem: Interface_Text_Problem) {
	if len(address_text) > INTERFACE_TEXT_BYTES_MOST {
		return {}, 0, .Address_Text
	}
	slash := -1
	for index in 0 ..< len(address_text) {
		if address_text[index] == '/' {
			slash = index
			break
		}
	}
	if slash < 0 {
		_, is_address := address_of_text(address_text)
		return {}, 0, is_address ? .Prefix_Text : .Address_Text
	}
	local, local_ok := address_of_text(address_text[:slash])
	if !local_ok {
		return {}, 0, .Address_Text
	}
	prefix_text := address_text[slash + 1:]
	if len(prefix_text) == 0 || len(prefix_text) > 2 || len(prefix_text) == 2 && prefix_text[0] == '0' {
		return {}, 0, .Prefix_Text
	}
	prefix := 0
	for character in transmute([]u8)prefix_text {
		if character < '0' || character > '9' {
			return {}, 0, .Prefix_Text
		}
		prefix = prefix * 10 + int(character - '0')
	}
	gateway, gateway_ok := address_of_text(gateway_text)
	if !gateway_ok {
		return {}, 0, .Gateway_Text
	}
	address = {local = local, gateway = gateway, prefix_length = u8(prefix)}
	checked_mask, checked := interface_address_check(address)
	switch checked {
	case .None:
	case .Prefix_Length:
		return {}, 0, .Prefix_Length
	case .Local_Address:
		return {}, 0, .Local_Address
	case .Gateway:
		return {}, 0, .Gateway
	}
	return address, checked_mask, .None
}
