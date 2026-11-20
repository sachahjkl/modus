package build

import "modus:contract/value_kinds"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the device services, of the network service, of remote
// and of remote_display against the lines that they replaced
// (src/md/features/log_facts.md, "The facts of the device services and of
// the network"). The fact types come from the extraction of the tool on
// the sources of each module: a host test does not depend on a build. Each
// sentence is compared with the parts of the old line written by
// sentence.format, at the edges of each field.

// The longest address of a host, as address_text writes it, and a short
// one.
@(private = "file")
PEER_LONGEST :: "255.255.255.255 port 65535"
@(private = "file")
PEER_SHORT :: "10.0.2.2 port 7100"
// A whole key in 64 hexadecimal digits, and the head of a key in 16.
@(private = "file")
KEY_WHOLE :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
@(private = "file")
KEY_HEAD :: "fedcba9876543210"

// The most bytes of the text of each Text field of these modules, which
// its field holds with a zero byte after it.
@(private = "file")
device_text_bytes_most :: proc() -> map[string]u32 {
	most := make(map[string]u32, context.temp_allocator)
	most["client_key"] = len(KEY_WHOLE)
	most["viewer_key"] = len(KEY_WHOLE)
	most["client_key_head"] = len(KEY_HEAD)
	most["viewer_key_head"] = len(KEY_HEAD)
	most["peer"] = len(PEER_LONGEST)
	most["service"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["owner"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["remote_address"] = len("255.255.255.255")
	most["command"] = len("Read_Region_Remove")
	most["hardware_address"] = len("52:54:00:12:34:56")
	most["request"] = len("PCM_SET_PARAMS")
	most["step"] = len("the wait until the TPM is ready")
	most["properties"] = len("the state of the hierarchies")
	most["cause"] = len("it names an empty rectangle, or a screen piece larger than 128 x 64")
	most["error_code"] = len("Input_Not_Allowed")
	most["missed_step"] = len("did not let the stream take the records of its viewer frame")
	most["failure"] = len("no handle of the frame service with the right Read: a wait for the device would have no end")
	most["public_key"] = len(KEY_WHOLE)
	most["interface_address"] = len("255.255.255.255/24 ff:ff:ff:ff:ff:ff")
	most["protocol"] = len("TCP")
	return most
}

// The folders of the modules of these tests.
@(private = "file")
DEVICE_FACT_FOLDERS := [?]string{"remote", "remote_display", "network", "frame", "entropy", "input", "sound", "tpm"}

// Each fact type of these modules with a Text field ends with its Text
// fields, and each Text field holds the longest text of its writer and a
// zero byte.
@(test)
the_texts_of_the_device_facts_come_last_and_whole :: proc(t: ^testing.T) {
	most := device_text_bytes_most()
	for folder in DEVICE_FACT_FOLDERS {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if ok {
			facts_expect_text_fields_last(t, file, most)
		}
	}
}

// Each fact type of remote writes the line of before, byte for byte: the
// principals 0, 1 and max(u64); the longest address of a host and a short
// one; the times 0 and max(i64), the largest that a time field holds.
@(test)
the_facts_of_remote_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "remote")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "remote_service", type_name, values)
	}
	service := strings.repeat("s", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	largest := u64(max(i64))
	principals := [3]u64{0, 1, max(u64)}
	peers := [2]string{PEER_LONGEST, PEER_SHORT}
	times := [2]u64{0, largest}
	refused_end :: "; the handshake ends before any call"

	for principal in principals {
		other := max(u64) - principal
		facts_expect_line(t, render(t, file, "Client_Key_Refused_Contested", {{"principal", principal}, {"other_principal", other}, {"client_key", KEY_WHOLE}}), line_of_before("remote: refused the client key ", KEY_WHOLE, ": it is contested: principal ", principal, " and principal ", other, " both allowed it, and it acts for neither until one of them revokes it", refused_end))
		facts_expect_line(t, render(t, file, "Client_Key_Refused_For_Display_Only", {{"principal", principal}, {"client_key", KEY_WHOLE}}), line_of_before("remote: refused the client key ", KEY_WHOLE, ": principal ", principal, " allowed it for the remote display, and not for calls", refused_end))
		facts_expect_line(t, render(t, file, "Client_Key_Refused_Session_Locked", {{"principal", principal}, {"client_key", KEY_WHOLE}}), line_of_before("remote: refused the client key ", KEY_WHOLE, ": the session of its principal ", principal, " is locked", refused_end))
		for peer in peers {
			facts_expect_line(t, render(t, file, "Client_Key_Proved", {{"principal", principal}, {"client_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote: ", peer, " proved the client key ", KEY_HEAD, ": its calls act for principal ", principal))
			facts_expect_line(t, render(t, file, "Client_Key_Contested", {{"principal", principal}, {"other_principal", other}, {"client_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote: the client key ", KEY_HEAD, " of principal ", principal, " is contested: principal ", other, " allowed it too, and it acts for neither; the connection from ", peer, " ends with the code Revoked"))
			facts_expect_line(t, render(t, file, "Client_Key_Grant_Ended", {{"principal", principal}, {"client_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote: the grant of the client key ", KEY_HEAD, " of principal ", principal, " ended (a revocation, or a lock of its session): the connection from ", peer, " ends with the code Revoked"))
		}
		facts_expect_line(t, render(t, file, "Service_Connected", {{"principal", principal}, {"service", service}}), line_of_before("remote: connected to the service ", service, ", for principal ", principal))
	}
	facts_expect_line(t, render(t, file, "Client_Key_Refused", {{"client_key", KEY_WHOLE}}), line_of_before("remote: refused the client key ", KEY_WHOLE, ": no principal allowed it", refused_end))

	for peer in peers {
		facts_expect_line(t, render(t, file, "Client_Key_Grant_Ended_In_Handshake", {{"client_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote: ", peer, ": the grant of the client key ", KEY_HEAD, " ended during the handshake: the connection ends with the code Revoked, before any call"))
		facts_expect_line(t, render(t, file, "Connection_Arrived", {{"peer", peer}}), line_of_before("remote: a connection from ", peer))
		for time in times {
			other := largest - time
			facts_expect_line(t, render(t, file, "Idle_End_Held", {{"silence", time}, {"idle_timeout", other}, {"bound", time}, {"after_bound", other}, {"peer", peer}}), line_of_before("remote: ", peer, ": the idle end held its bound: ", time, " ms with no packet of the host, the idle timeout ", other, " ms, the bound ", time, " ms, ", other, " ms after the bound"))
			facts_expect_line(t, render(t, file, "Idle_End_Not_Held", {{"silence", other}, {"idle_timeout", time}, {"bound", other}, {"after_bound", time}, {"peer", peer}}), line_of_before("remote: ", peer, ": the idle end did NOT hold its bound: ", other, " ms with no packet of the host, the idle timeout ", time, " ms, the bound ", other, " ms, ", time, " ms after the bound"))
			facts_expect_line(t, render(t, file, "Request_Timeout", {{"stream_identifier", max(u64)}, {"bound", u64(10_000)}, {"bytes_received", time}, {"elapsed", other}, {"peer", peer}}), line_of_before("remote: ", peer, ", the stream ", max(u64), ": no whole request in ", u64(10_000), " ms (", time, " bytes came): reset with the code Timeout after ", other, " ms of the machine; the bound of a request held"))
			facts_expect_line(t, render(t, file, "Answer_Timeout", {{"stream_identifier", u64(0)}, {"bound", u64(10_000)}, {"bytes_written", max(u64)}, {"answer_length", time}, {"elapsed", other}, {"peer", peer}}), line_of_before("remote: ", peer, ", the stream ", u64(0), ": the host did not take the answer in ", u64(10_000), " ms (", max(u64), " of ", time, " bytes in the stream): reset with the code Timeout after ", other, " ms of the machine; the bound of an answer held"))
			facts_expect_line(t, render(t, file, "Stream_Not_Ended_After_Reset", {{"stream_identifier", u64(1)}, {"bound", time}, {"elapsed", other}, {"peer", peer}}), line_of_before("remote: ", peer, ", the stream ", u64(1), ": the host did not end it ", time, " ms after its reset: the connection ends with the code Timeout after ", other, " ms of the machine"))
		}
		facts_expect_line(t, render(t, file, "Request_Too_Large", {{"stream_identifier", max(u64)}, {"request_limit", u64(65640)}, {"peer", peer}}), line_of_before("remote: ", peer, ", the stream ", max(u64), ": a request of more than ", u64(65640), " bytes: reset with the code Too_Large, and no call"))
	}

	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, render(t, file, "Service_Connections_Ended", {{"ended", count}, {"in_use", max(u64) - count}, {"capacity", u64(24)}}), line_of_before("remote: the grants of ", count, " connections to services ended (a revocation, or a lock or an unlock of a session): their slots are free; ", max(u64) - count, " of ", u64(24), " slots in use"))
	}
	facts_expect_line(t, render(t, file, "Service_Stopped_During_Call", {{"service", service}}), line_of_before("remote: the service ", service, " stopped during a call"))
	for time in times {
		facts_expect_line(t, render(t, file, "Service_Silent", {{"bound", time}, {"service", "monitor"}}), line_of_before("remote: the service ", "monitor", " did not answer in ", time, " ms: the connection ends"))
	}
}

// Each fact type of remote_display writes the line of before, byte for
// byte: the principals 0 and max(u64); each cause of a refused record and
// each code; each bound of a viewer.
@(test)
the_facts_of_remote_display_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "remote_display")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "remote_display_service", type_name, values)
	}
	principals := [2]u64{0, max(u64)}
	peers := [2]string{PEER_LONGEST, PEER_SHORT}
	facts_expect_line(t, render(t, file, "Viewer_Key_Refused", {{"viewer_key", KEY_WHOLE}}), line_of_before("remote_display: refused the viewer key ", KEY_WHOLE, ": no principal allowed it for the view, or the session of its principal is locked; the handshake ends before any viewer frame"))
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, render(t, file, "Viewer_Input_Records_Dropped", {{"dropped", count}, {"viewer_key_head", KEY_HEAD}}), line_of_before("remote_display: the end of the viewer key ", KEY_HEAD, " dropped ", count, " of its input records that waited for the compositor"))
		facts_expect_line(t, render(t, file, "Viewer_Damage_Full", {{"merges", count}, {"viewer_key_head", KEY_HEAD}}), line_of_before("remote_display: the damage of the viewer key ", KEY_HEAD, " was full: ", count, " rectangles joined another, and the viewer receives more pixels"))
		facts_expect_line(t, render(t, file, "Compositor_Word_Refused", {{"word", count}}), line_of_before("remote_display: the compositor sent the word ", count, ", which names no event; the next ones are counted"))
		facts_expect_line(t, render(t, file, "Capture_Picture_Refused", {{"picture", count}}), line_of_before("remote_display: the compositor named the picture ", count, " of no capture face, or a second one while this process holds one: the record is refused"))
	}
	for peer in peers {
		facts_expect_line(t, render(t, file, "Viewer_Key_Grant_Ended_In_Handshake", {{"viewer_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote_display: ", peer, ": the grant of the viewer key ", KEY_HEAD, " ended during the handshake: the connection ends with the code Revoked"))
		for principal in principals {
			facts_expect_line(t, render(t, file, "Viewer_Key_Proved_With_Input", {{"principal", principal}, {"viewer_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote_display: ", peer, " proved the viewer key ", KEY_HEAD, ": it sees the screen for principal ", principal, ", and its keys and its pointer go to the desktop"))
			facts_expect_line(t, render(t, file, "Viewer_Key_Proved_Without_Input", {{"principal", principal}, {"viewer_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote_display: ", peer, " proved the viewer key ", KEY_HEAD, ": it sees the screen for principal ", principal, ", with no input"))
			facts_expect_line(t, render(t, file, "Viewer_Key_Grant_Ended", {{"principal", principal}, {"viewer_key_head", KEY_HEAD}, {"peer", peer}}), line_of_before("remote_display: the grant of the viewer key ", KEY_HEAD, " of principal ", principal, " ended (a revocation, a lock of its session, or another session in front): the connection from ", peer, " ends with the code Revoked"))
		}
	}
	for principal in principals {
		facts_expect_line(t, render(t, file, "Viewer_Input_Not_Allowed", {{"principal", principal}, {"viewer_key_head", KEY_HEAD}}), line_of_before("remote_display: the viewer key ", KEY_HEAD, " sent input, and principal ", principal, " allowed it for the view only: nothing reaches the desktop, and the connection ends with the code Input_Not_Allowed"))
	}
	// The causes of a refused record: the sentences of the protocol and
	// the three of the service, each with a code.
	causes := [?]string{"its kind names no record", "it is past its bound", "it names an empty rectangle, or a screen piece larger than 128 x 64", "a second Session_Start", "a record before Session_Start", "a Viewer_Frame_Taken of no viewer frame in flight"}
	codes := [?]string{"Too_Large", "Bad_Record", "Out_Of_Order", "Input_Not_Allowed"}
	for cause in causes {
		for code in codes {
			facts_expect_line(t, render(t, file, "Viewer_Record_Refused", {{"viewer_key_head", KEY_HEAD}, {"cause", cause}, {"error_code", code}}), line_of_before("remote_display: refused a record of the viewer key ", KEY_HEAD, ": ", cause, ": the connection ends with the code ", code))
		}
	}
	// The bounds of a viewer, each with its own words.
	bounds := [?]string{"did not let the stream take the records of its viewer frame", "did not take its viewer frame", "did not send the rest of its record"}
	limits := [2]u64{0, u64(max(i64))}
	for bound in bounds {
		for limit in limits {
			facts_expect_line(t, render(t, file, "Viewer_Bound_Passed", {{"bound", limit}, {"viewer_key_head", KEY_HEAD}, {"missed_step", bound}}), line_of_before("remote_display: the viewer key ", KEY_HEAD, " ", bound, " in its bound of ", limit, " ms: the connection ends with the code Timeout"))
		}
	}
}

// Each fact type of the network service writes the line of before, byte
// for byte: a process name of 31 bytes, the longest address and the
// address 0.0.0.0, the ports 0 and 65535, and the counts 0 and max(u64).
@(test)
the_facts_of_the_network_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "network")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "network_service", type_name, values)
	}
	owner := strings.repeat("n", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	addresses := [2]string{"255.255.255.255", "0.0.0.0"}
	ports := [2]u64{0, 65535}
	for port in ports {
		facts_expect_line(t, render(t, file, "Endpoint_Listens_Tcp", {{"listen_port", port}, {"owner", owner}}), line_of_before("network: an endpoint for ", owner, ": TCP, the listen port ", port, ", the remotes that send to it"))
		facts_expect_line(t, render(t, file, "Endpoint_Listens_Udp", {{"listen_port", port}, {"owner", owner}}), line_of_before("network: an endpoint for ", owner, ": UDP, the listen port ", port, ", the remotes that send 1200 bytes to it"))
		for address in addresses {
			facts_expect_line(t, render(t, file, "Endpoint_Listens_Udp_From_Address", {{"listen_port", port}, {"owner", owner}, {"remote_address", address}}), line_of_before("network: an endpoint for ", owner, ": UDP, the listen port ", port, ", the remotes of the address ", address, " only that send 1200 bytes to it"))
			facts_expect_line(t, render(t, file, "Endpoint_Connects_Tcp", {{"first_local_port", port}, {"last_local_port", u64(65535) - port}, {"remote_port", port}, {"owner", owner}, {"remote_address", address}}), line_of_before("network: an endpoint for ", owner, ": TCP, the local ports ", port, " to ", u64(65535) - port, ", the grant ", address, " port ", port))
			facts_expect_line(t, render(t, file, "Endpoint_Connects_Udp", {{"local_port", u64(65535) - port}, {"remote_port", port}, {"owner", owner}, {"remote_address", address}}), line_of_before("network: an endpoint for ", owner, ": the local port ", u64(65535) - port, ", the grant ", address, " port ", port))
		}
	}
	facts_expect_line(t, render(t, file, "Endpoint_Grant_Changed_To_Remote", {{"owner", owner}}), line_of_before("network: the grant of the endpoint of ", owner, " changed: ", "a new remote"))
	facts_expect_line(t, render(t, file, "Endpoint_Grant_Changed_To_None", {{"owner", "net"}}), line_of_before("network: the grant of the endpoint of ", "net", " changed: ", "none"))
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, render(t, file, "Endpoint_Ended", {{"datagrams_sent", count}, {"datagrams_received", max(u64) - count}, {"owner", owner}}), line_of_before("network: the endpoint of ", owner, " ended: ", count, " datagrams sent, ", max(u64) - count, " received"))
		facts_expect_line(t, render(t, file, "Read_Region_Refused", {{"status_word", count}, {"owner", owner}}), line_of_before("network: the frame service refused the datagram region of ", owner, " as a read region: status ", count))
	}
	// The longest name of a command, and the words of a command that names
	// no member (frame.command_name).
	commands := [?]string{"Read_Region_Remove", "an unknown command", "Info"}
	bounds := [2]u64{60_000, u64(max(i64))}
	for command in commands {
		for bound in bounds {
			facts_expect_line(t, render(t, file, "Frame_Service_Silent", {{"bound", bound}, {"command", command}}), line_of_before("network: the frame service did not answer the command ", command, " in ", bound, " ms: this service stops"))
		}
	}
}

// Each fact type of the frame service, of the entropy service and of the
// input service writes the line of before, byte for byte: the counts 0, 1
// and max(u64), and each state of the link.
@(test)
the_facts_of_the_frame_entropy_and_input_services_write_the_lines_of_before :: proc(t: ^testing.T) {
	frame_file, frame_ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "frame")
	entropy_file, entropy_ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "entropy")
	input_file, input_ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "input")
	if !frame_ok || !entropy_ok || !input_ok {
		return
	}
	hardware := "52:54:00:12:34:56"
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, fact_test_render(t, frame_file, "frame_service", "Device_Ready_Link_Up", {{"receive_queue", count}, {"send_queue", max(u64) - count}, {"places", count}, {"hardware_address", hardware}}), line_of_before("frame: ok, the hardware address ", hardware, ", the link is ", "up", ", queues of ", count, " and ", max(u64) - count, ", ", count, " places for frames that arrive"))
		facts_expect_line(t, fact_test_render(t, frame_file, "frame_service", "Device_Ready_Link_Down", {{"receive_queue", count}, {"send_queue", count}, {"places", max(u64) - count}, {"hardware_address", hardware}}), line_of_before("frame: ok, the hardware address ", hardware, ", the link is ", "down", ", queues of ", count, " and ", count, ", ", max(u64) - count, " places for frames that arrive"))
		facts_expect_line(t, fact_test_render(t, entropy_file, "entropy_device_service", "Device_Ready", {{"queue_size", count}}), line_of_before("entropy: ok, a queue of ", count))
		facts_expect_line(t, fact_test_render(t, input_file, "input", "Keyboard_Bytes_Lost_At_Start", {{"keyboard_bytes", count}}), line_of_before("input: ", count, " bytes of the keyboard came during the start of the mouse and are lost"))
		facts_expect_line(t, fact_test_render(t, input_file, "input", "Key_Records_Lost", {{"key_records", count}}), line_of_before("input: the input ring refused a key record that had a place: ", count, " key records are lost"))
		facts_expect_line(t, fact_test_render(t, input_file, "input", "Pointer_Records_Lost", {{"pointer_records", count}}), line_of_before("input: no entry for a change of a button of the pointer: ", count, " pointer records are lost"))
	}
}

// Each fact type of the sound service writes the line of before, byte for
// byte: each control request, the counts 0, 1 and max(u64), and the
// largest u32 that a code and a length of the device have.
@(test)
the_facts_of_the_sound_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "sound")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "sound_device_service", type_name, values)
	}
	requests := [?]string{"PCM_INFO", "PCM_SET_PARAMS", "PCM_PREPARE"}
	words := [3]u64{0, 1, u64(max(u32))}
	for request in requests {
		facts_expect_line(t, render(t, file, "Device_Silent", {{"bound", u64(60_000)}, {"request", request}}), line_of_before("sound: the device did not answer ", request, " in ", u64(60_000), " ms"))
		for word in words {
			facts_expect_line(t, render(t, file, "Answer_Too_Short", {{"answer_length", word}, {"request", request}}), line_of_before("sound: the device answered ", request, " with ", word, " bytes, fewer than its code"))
			facts_expect_line(t, render(t, file, "Request_Refused", {{"answer_code", word}, {"request", request}}), line_of_before("sound: the device refused ", request, " with the code ", word))
		}
	}
	for word in words {
		facts_expect_line(t, render(t, file, "Stream_Information_Too_Short", {{"streams", word}, {"answer_length", u64(max(u32)) - word}}), line_of_before("sound: the device answered PCM_INFO for ", word, " streams with ", u64(max(u32)) - word, " bytes"))
		facts_expect_line(t, render(t, file, "Stream_Information_Refused", {{"answer_code", word}}), line_of_before("sound: the device refused PCM_INFO with the code ", word))
		facts_expect_line(t, render(t, file, "No_Stream_Of_The_Format", {{"streams", word}}), line_of_before("sound: the device has ", word, " streams, and none plays 48000 frames in one second of 2 channels of signed 16-bit samples"))
		facts_expect_line(t, render(t, file, "Period_Refused", {{"answer_code", word}}), line_of_before("sound: the device answered a period with the code ", word))
	}
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, render(t, file, "Device_Ready", {{"stream", count}, {"streams", max(u64) - count}, {"periods", count}, {"period_frames", u64(480)}, {"transmit_queue", max(u64) - count}}), line_of_before("sound: ok, the output stream ", count, " of ", max(u64) - count, ", 48000 frames in one second, 2 channels of signed 16-bit samples; ", count, " periods of ", u64(480), " frames with the device; a transmit queue of ", max(u64) - count))
	}
}

// Each fact type of the TPM service writes the line of before, byte for
// byte: each step of the interface, each set of properties, the sizes 0
// and max(i64), and the counts 0, 1 and max(u64).
@(test)
the_facts_of_the_tpm_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "tpm")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "tpm_device_service", type_name, values)
	}
	steps := [?]string{"the request of locality 0", "the wait until the TPM is ready", "the end of the command", "the read of the answer"}
	properties := [?]string{"the count limits", "the state of the hierarchies"}
	for step in steps {
		facts_expect_line(t, render(t, file, "Shutdown_Interface_Failed", {{"step", step}}), line_of_before("tpm: the interface failed at TPM2_Shutdown after a use of an authorization value: ", step, "; the next start of the TPM can count one failure"))
		facts_expect_line(t, render(t, file, "Extend_Read_Back_Interface_Failed", {{"step", step}}), line_of_before("tpm: extended PCR 12, and the interface failed at its read back: ", step))
		facts_expect_line(t, render(t, file, "Lockout_Change_Interface_Failed", {{"step", step}}), line_of_before("tpm: the interface failed at TPM2_HierarchyChangeAuth of the lockout hierarchy: ", step, "; it can keep its empty authorization value until the next start"))
		for asked in properties {
			facts_expect_line(t, render(t, file, "Capability_Interface_Failed", {{"properties", asked}, {"step", step}}), line_of_before("tpm: the interface failed at TPM2_GetCapability of ", asked, ": ", step))
		}
	}
	for asked in properties {
		facts_expect_line(t, render(t, file, "Capability_Answer_Malformed", {{"properties", asked}}), line_of_before("tpm: the answer of the TPM to TPM2_GetCapability of ", asked, " does not hold the properties asked, each in its place"))
	}
	sizes := [2]u64{0, u64(max(i64))}
	for size in sizes {
		other := u64(max(i64)) - size
		facts_expect_line(t, render(t, file, "Sealed_With_Authorization", {{"public_area", size}, {"private_area", other}}), line_of_before("tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", size, " bytes and a private area of ", other, " bytes, with its creation data and its ticket"))
		facts_expect_line(t, render(t, file, "Sealed", {{"public_area", other}, {"private_area", size}}), line_of_before("tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of ", other, " bytes and a private area of ", size, " bytes, with its creation data and its ticket"))
	}
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, render(t, file, "Extend_Refused_At_Limit", {{"extends", count}}), line_of_before("tpm: refused an extend of PCR 12: ", count, " extends ran in this start, the most that it takes"))
		facts_expect_line(t, render(t, file, "Start_Policy_Measured", {{"extend", count}, {"extend_limit", u64(2)}}), line_of_before("tpm: extended PCR 12 with the digest of a start policy: extend ", count, " of ", u64(2), " in this start"))
	}
}
