// Browser machine configuration border (src/md/features/browser_machine.md,
// "Several processors as workers").
//
// Validates browser-supplied machine parameters before booting the kernel:
//   - automatic single-worker fallback when `cross_origin_isolated` is false;
//   - bounded multi-worker execution on shared memory when isolated;
//   - optional bring-your-own link relay URL (empty by default, which yields
//     a machine with no network device);
//   - fixed physical memory size aligned to 4 KiB and strictly below 4 GiB
//     so 32-bit `wasm64p32` linear-memory offsets address every byte.
package software_machine

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Bounds on browser machine physical RAM (1 MiB ..= 4 GiB - 4 KiB).
MIN_BROWSER_MEMORY_BYTES :: u64(1) << 20
MAX_BROWSER_MEMORY_BYTES :: u64(0xFFFF_F000)

// Maximum browser worker processors per engine class.
MAX_CHROMIUM_DESKTOP_PROCESSORS :: u32(4)
MAX_FIREFOX_DESKTOP_PROCESSORS :: u32(2)
MAX_SAFARI_OR_MOBILE_PROCESSORS :: u32(1)

// Maximum byte length of a bring-your-own link relay URL.
MAX_RELAY_URL_BYTES :: 256

// Execution topology chosen for the browser machine.
Execution_Mode :: enum u32 {
	Single_Worker_Fallback     = 1,
	Multi_Worker_Shared_Memory = 2,
}

// Browser engine class that bounds default worker count.
Browser_Engine_Kind :: enum u32 {
	Chromium_Desktop = 1,
	Firefox_Desktop  = 2,
	Safari_Or_Mobile = 3,
}

// Transport protocol inferred from a validated link relay URL.
Relay_Transport_Kind :: enum u32 {
	None               = 0,
	WebTransport_Https = 1,
	WebSocket_Secure   = 2,
	WebSocket_Loopback = 3,
}

// Result of validating a `Browser_Machine_Config`.
Config_Validation_Status :: enum u32 {
	Ok                              = 0,
	Invalid_Engine_Kind             = 1,
	Invalid_Memory_Size             = 2,
	Invalid_Processor_Count         = 3,
	Invalid_Relay_Url               = 4,
	Insecure_Relay_Scheme           = 5,
	Relay_Url_Too_Long              = 6,
	Multi_Worker_Requires_Isolation = 7,
}

// Caller-supplied configuration before validation at the border.
// Leave `requested_processors == 0` to apply the default engine/isolation rule
// and `relay_url_length == 0` for no network device.
Browser_Machine_Config :: struct {
	cross_origin_isolated: bool,
	engine_kind:           Browser_Engine_Kind,
	hardware_threads:      u32,
	requested_processors:  u32,
	memory_bytes:          u64,
	relay_url:             [MAX_RELAY_URL_BYTES]u8,
	relay_url_length:      u32,
}

// Resolved configuration produced after `validate_browser_machine_config`.
Resolved_Browser_Machine_Config :: struct {
	execution_mode:     Execution_Mode,
	engine_kind:        Browser_Engine_Kind,
	processor_count:    u32,
	uses_shared_memory: bool,
	uses_jspi_idle:     bool,
	memory_bytes:       u64,
	network_enabled:    bool,
	relay_transport:    Relay_Transport_Kind,
}

// browser_engine_kind_from_word converts a transport word into a
// `Browser_Engine_Kind` and refuses any value that names no member.
browser_engine_kind_from_word :: proc "contextless" (word: u64) -> (kind: Browser_Engine_Kind, ok: bool) {
	return enum_word.member_of_word(Browser_Engine_Kind, word)
}

// execution_mode_from_word converts a transport word into an `Execution_Mode`
// and refuses any value that names no member.
execution_mode_from_word :: proc "contextless" (word: u64) -> (mode: Execution_Mode, ok: bool) {
	return enum_word.member_of_word(Execution_Mode, word)
}

// relay_transport_kind_from_word converts a transport word into a
// `Relay_Transport_Kind` and refuses any value that names no member.
relay_transport_kind_from_word :: proc "contextless" (word: u64) -> (kind: Relay_Transport_Kind, ok: bool) {
	return enum_word.member_of_word(Relay_Transport_Kind, word)
}

// browser_machine_config_set_relay_url copies a relay URL string into a config
// record. Returns false if the URL exceeds `MAX_RELAY_URL_BYTES`.
browser_machine_config_set_relay_url :: proc "contextless" (config: ^Browser_Machine_Config, url: string) -> bool {
	if len(url) > MAX_RELAY_URL_BYTES {
		config.relay_url_length = u32(len(url))
		return false
	}
	for &byte in config.relay_url {
		byte = 0
	}
	for index in 0 ..< len(url) {
		config.relay_url[index] = url[index]
	}
	config.relay_url_length = u32(len(url))
	return true
}

@(private = "file")
bytes_have_prefix :: proc "contextless" (data: []u8, prefix: string) -> bool {
	if len(data) < len(prefix) {
		return false
	}
	for index in 0 ..< len(prefix) {
		if data[index] != prefix[index] {
			return false
		}
	}
	return true
}

@(private = "file")
bytes_equal_string :: proc "contextless" (data: []u8, text: string) -> bool {
	if len(data) != len(text) {
		return false
	}
	for index in 0 ..< len(text) {
		if data[index] != text[index] {
			return false
		}
	}
	return true
}

@(private = "file")
is_valid_host_byte :: proc "contextless" (byte: u8) -> bool {
	is_lower := byte >= 'a' && byte <= 'z'
	is_upper := byte >= 'A' && byte <= 'Z'
	is_digit := byte >= '0' && byte <= '9'
	return is_lower || is_upper || is_digit || byte == '.' || byte == '-' || byte == ':' || byte == '[' || byte == ']'
}

@(private = "file")
is_loopback_host :: proc "contextless" (host: []u8) -> bool {
	return bytes_equal_string(host, "127.0.0.1") ||
		bytes_equal_string(host, "localhost") ||
		bytes_equal_string(host, "[::1]")
}

// validate_relay_url parses and validates the optional bring-your-own link
// relay URL. Empty input disables networking; `https://` selects WebTransport;
// `wss://` selects secure WebSocket; `ws://` is allowed only on loopback hosts
// for headless local machine tests.
@(private = "file")
validate_relay_url :: proc "contextless" (raw_url: []u8) -> (transport: Relay_Transport_Kind, status: Config_Validation_Status) {
	if len(raw_url) == 0 {
		return .None, .Ok
	}
	if !text_encoding.text_valid(raw_url) {
		return .None, .Invalid_Relay_Url
	}
	for byte in raw_url {
		// Reject whitespace, control characters, and non-ASCII bytes in URLs.
		if byte <= 0x20 || byte >= 0x7F {
			return .None, .Invalid_Relay_Url
		}
	}

	scheme_length := 0
	is_plaintext_ws := false
	switch {
	case bytes_have_prefix(raw_url, "https://"):
		scheme_length = len("https://")
		transport = .WebTransport_Https
	case bytes_have_prefix(raw_url, "wss://"):
		scheme_length = len("wss://")
		transport = .WebSocket_Secure
	case bytes_have_prefix(raw_url, "ws://"):
		scheme_length = len("ws://")
		is_plaintext_ws = true
		transport = .WebSocket_Loopback
	case bytes_have_prefix(raw_url, "http://"):
		return .None, .Insecure_Relay_Scheme
	case:
		return .None, .Invalid_Relay_Url
	}

	authority := raw_url[scheme_length:]
	if len(authority) == 0 {
		return .None, .Invalid_Relay_Url
	}

	// Cut authority before path, query, or fragment.
	authority_end := len(authority)
	for index in 0 ..< len(authority) {
		byte := authority[index]
		if byte == '/' || byte == '?' || byte == '#' {
			authority_end = index
			break
		}
		if byte == '@' {
			// Refuse embedded credentials in relay URLs.
			return .None, .Invalid_Relay_Url
		}
	}
	authority = authority[:authority_end]
	if len(authority) == 0 {
		return .None, .Invalid_Relay_Url
	}

	// Separate host from optional :port.
	host := authority
	port := authority[len(authority):]
	if authority[0] == '[' {
		close_bracket := -1
		for index in 1 ..< len(authority) {
			if authority[index] == ']' {
				close_bracket = index
				break
			}
		}
		if close_bracket < 2 {
			return .None, .Invalid_Relay_Url
		}
		host = authority[:close_bracket + 1]
		if close_bracket + 1 < len(authority) {
			if authority[close_bracket + 1] != ':' {
				return .None, .Invalid_Relay_Url
			}
			port = authority[close_bracket + 2:]
			if len(port) == 0 {
				return .None, .Invalid_Relay_Url
			}
		}
	} else {
		colon_index := -1
		for index in 0 ..< len(authority) {
			if authority[index] == ':' {
				if colon_index >= 0 {
					return .None, .Invalid_Relay_Url
				}
				colon_index = index
			}
		}
		if colon_index >= 0 {
			host = authority[:colon_index]
			port = authority[colon_index + 1:]
			if len(port) == 0 {
				return .None, .Invalid_Relay_Url
			}
		}
	}

	if len(host) == 0 {
		return .None, .Invalid_Relay_Url
	}
	for byte in host {
		if !is_valid_host_byte(byte) {
			return .None, .Invalid_Relay_Url
		}
	}
	if len(port) > 0 {
		port_value := u32(0)
		for byte in port {
			if byte < '0' || byte > '9' {
				return .None, .Invalid_Relay_Url
			}
			port_value = port_value * 10 + u32(byte - '0')
			if port_value > 65535 {
				return .None, .Invalid_Relay_Url
			}
		}
		if port_value == 0 {
			return .None, .Invalid_Relay_Url
		}
	}

	if is_plaintext_ws && !is_loopback_host(host) {
		return .None, .Insecure_Relay_Scheme
	}

	return transport, .Ok
}

// engine_processor_cap returns the default worker cap for a validated browser
// engine class.
@(private = "file")
engine_processor_cap :: proc "contextless" (engine_kind: Browser_Engine_Kind) -> u32 {
	switch engine_kind {
	case .Chromium_Desktop:
		return MAX_CHROMIUM_DESKTOP_PROCESSORS
	case .Firefox_Desktop:
		return MAX_FIREFOX_DESKTOP_PROCESSORS
	case .Safari_Or_Mobile:
		return MAX_SAFARI_OR_MOBILE_PROCESSORS
	}
	return 1
}

// validate_browser_machine_config validates every field of `config` at the
// browser border and resolves the execution topology, worker count, and
// network transport.
validate_browser_machine_config :: proc "contextless" (config: Browser_Machine_Config) -> (resolved: Resolved_Browser_Machine_Config, status: Config_Validation_Status) {
	config := config
	engine, engine_ok := browser_engine_kind_from_word(u64(config.engine_kind))
	if !engine_ok {
		return {}, .Invalid_Engine_Kind
	}

	if config.memory_bytes < MIN_BROWSER_MEMORY_BYTES ||
		config.memory_bytes > MAX_BROWSER_MEMORY_BYTES ||
		(config.memory_bytes & PAGE_OFFSET_MASK) != 0 {
		return {}, .Invalid_Memory_Size
	}

	if config.hardware_threads == 0 {
		return {}, .Invalid_Processor_Count
	}

	if config.relay_url_length > MAX_RELAY_URL_BYTES {
		return {}, .Relay_Url_Too_Long
	}

	relay_slice := config.relay_url[:config.relay_url_length]
	transport, relay_status := validate_relay_url(relay_slice)
	if relay_status != .Ok {
		return {}, relay_status
	}

	cap := engine_processor_cap(engine)
	processor_count := u32(1)
	execution_mode := Execution_Mode.Single_Worker_Fallback
	uses_shared_memory := false
	uses_jspi_idle := true

	if !config.cross_origin_isolated {
		if config.requested_processors > 1 {
			return {}, .Multi_Worker_Requires_Isolation
		}
		processor_count = 1
		execution_mode = .Single_Worker_Fallback
		uses_shared_memory = false
		uses_jspi_idle = true
	} else {
		if config.requested_processors > cap {
			return {}, .Invalid_Processor_Count
		}
		if config.requested_processors == 0 {
			half_threads := config.hardware_threads / 2
			processor_count = max(u32(1), min(half_threads, cap))
		} else {
			processor_count = config.requested_processors
		}
		execution_mode = .Multi_Worker_Shared_Memory
		uses_shared_memory = true
		uses_jspi_idle = false
	}

	return Resolved_Browser_Machine_Config {
		execution_mode     = execution_mode,
		engine_kind        = engine,
		processor_count    = processor_count,
		uses_shared_memory = uses_shared_memory,
		uses_jspi_idle     = uses_jspi_idle,
		memory_bytes       = config.memory_bytes,
		network_enabled    = transport != .None,
		relay_transport    = transport,
	}, .Ok
}
