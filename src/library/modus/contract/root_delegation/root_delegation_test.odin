#+build !freestanding
package root_delegation

import "core:testing"
import "modus:contract/blake3"
import op "modus:contract/operation"
import "modus:contract/remote"
import "modus:contract/role_contract"
import "modus:contract/start_grant"

@(private = "file")
fill_nickname :: proc(dst: ^[NICKNAME_CAPACITY]u8, name: string) -> u8 {
	dst^ = {}
	n := copy(dst[:], name)
	return u8(n)
}

@(private = "file")
make_test_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = tag
	h[31] = tag ~ 0xA5
	return h
}

@(private = "file")
make_valid_start_request :: proc(payload: []u8) -> Start_From_Bytes_Request {
	req: Start_From_Bytes_Request
	req.principal = 1
	req.nickname_length = fill_nickname(&req.nickname, "visitor-app")
	req.expected_module_hash = blake3.hash(payload)
	req.module_byte_count = u64(len(payload))
	req.budget_pages = 256
	return req
}

@(test)
start_from_bytes_refuses_hostile_hashes_nicknames_imports_and_grants :: proc(t: ^testing.T) {
	payload := [?]u8{'M', 'O', 'D', 'U', 'S', 1, 2, 3, 4, 5, 6, 7, 8}

	// Nil request and empty payload edges.
	testing.expect_value(t, validate_start_from_bytes_request(nil, payload[:]).refusal, Start_From_Bytes_Refusal.Empty_Module_Bytes)

	empty_bytes_req := make_valid_start_request(payload[:])
	testing.expect_value(t, validate_start_from_bytes_request(&empty_bytes_req, nil).refusal, Start_From_Bytes_Refusal.Empty_Module_Bytes)

	// Nickname edges: empty, too long, bad bytes, reserved names, trailing non-zero bytes.
	bad_nick := make_valid_start_request(payload[:])
	bad_nick.nickname_length = 0
	testing.expect_value(t, validate_start_from_bytes_request(&bad_nick, payload[:]).refusal, Start_From_Bytes_Refusal.Empty_Nickname)

	bad_nick = make_valid_start_request(payload[:])
	bad_nick.nickname_length = NICKNAME_CAPACITY + 1
	testing.expect_value(t, validate_start_from_bytes_request(&bad_nick, payload[:]).refusal, Start_From_Bytes_Refusal.Nickname_Too_Long)

	for bad in ([?]string{"bad/path", "dot.name", "has space", "..", "."}) {
		testing.expect_value(t, validate_nickname(bad), Start_From_Bytes_Refusal.Bad_Nickname_Byte)
	}
	for reserved in ([?]string{"module_files", "grant_table", "root", "devices", "disk_processes", "principals"}) {
		testing.expect_value(t, validate_nickname(reserved), Start_From_Bytes_Refusal.Reserved_Nickname)
	}

	trailing_nick := make_valid_start_request(payload[:])
	trailing_nick.nickname[NICKNAME_CAPACITY - 1] = 'x'
	testing.expect_value(t, validate_start_from_bytes_request(&trailing_nick, payload[:]).refusal, Start_From_Bytes_Refusal.Trailing_Nickname_Bytes)

	// Budget edges: 0, bound+1, max(u64).
	for bad_budget in ([?]u64{0, DISK_PROCESS_BUDGET_PAGES_LIMIT + 1, max(u64)}) {
		req := make_valid_start_request(payload[:])
		req.budget_pages = bad_budget
		testing.expect_value(t, validate_start_from_bytes_request(&req, payload[:]).refusal, Start_From_Bytes_Refusal.Invalid_Budget)
	}

	// Zero expected hash, size mismatch, oversized module, tampered payload byte.
	zero_hash_req := make_valid_start_request(payload[:])
	zero_hash_req.expected_module_hash = {}
	testing.expect_value(t, validate_start_from_bytes_request(&zero_hash_req, payload[:]).refusal, Start_From_Bytes_Refusal.Zero_Module_Hash)

	size_mismatch := make_valid_start_request(payload[:])
	size_mismatch.module_byte_count += 1
	testing.expect_value(t, validate_start_from_bytes_request(&size_mismatch, payload[:]).refusal, Start_From_Bytes_Refusal.Module_Size_Mismatch)

	oversized := make_valid_start_request(payload[:])
	oversized.module_byte_count = MODULE_BYTES_LIMIT + 1
	testing.expect_value(t, validate_start_from_bytes_request(&oversized, payload[:]).refusal, Start_From_Bytes_Refusal.Module_Too_Large)

	tampered := payload
	tampered[0] ~= 0x01
	tampered_req := make_valid_start_request(payload[:])
	testing.expect_value(t, validate_start_from_bytes_request(&tampered_req, tampered[:]).refusal, Start_From_Bytes_Refusal.Hash_Mismatch)

	// Import hash edges: bound+1, zero hash, self-import, duplicate import.
	too_many_imp := make_valid_start_request(payload[:])
	too_many_imp.import_count = IMPORT_HASH_CAPACITY + 1
	testing.expect_value(t, validate_start_from_bytes_request(&too_many_imp, payload[:]).refusal, Start_From_Bytes_Refusal.Too_Many_Imports)

	zero_imp := make_valid_start_request(payload[:])
	zero_imp.import_count = 1
	testing.expect_value(t, validate_start_from_bytes_request(&zero_imp, payload[:]).refusal, Start_From_Bytes_Refusal.Zero_Import_Hash)

	self_imp := make_valid_start_request(payload[:])
	self_imp.import_count = 1
	self_imp.import_hashes[0] = self_imp.expected_module_hash
	testing.expect_value(t, validate_start_from_bytes_request(&self_imp, payload[:]).refusal, Start_From_Bytes_Refusal.Self_Import_Hash)

	dup_imp := make_valid_start_request(payload[:])
	dup_imp.import_count = 2
	dup_imp.import_hashes[0] = make_test_hash(7)
	dup_imp.import_hashes[1] = make_test_hash(7)
	testing.expect_value(t, validate_start_from_bytes_request(&dup_imp, payload[:]).refusal, Start_From_Bytes_Refusal.Duplicate_Import_Hash)

	// Grant refusals: System_Part, Machine grants, unknown grant words, duplicates, bound+1.
	sys_part_req := make_valid_start_request(payload[:])
	sys_part_req.requested_grant_count = 1
	sys_part_req.requested_grant_words[0] = u64(start_grant.Grant.System_Part)
	testing.expect_value(t, validate_start_from_bytes_request(&sys_part_req, payload[:]).refusal, Start_From_Bytes_Refusal.Forbidden_System_Part_Grant)

	for machine_grant in ([?]start_grant.Grant{.Root_Ring, .Inspect, .Stop, .Schedule, .Events, .Counters, .Principals, .Tpm, .Start_Policy, .Data_Disk, .Replace, .Acts_For_Principal}) {
		req := make_valid_start_request(payload[:])
		req.requested_grant_count = 1
		req.requested_grant_words[0] = u64(machine_grant)
		testing.expect_value(t, validate_start_from_bytes_request(&req, payload[:]).refusal, Start_From_Bytes_Refusal.Forbidden_Machine_Grant)
	}

	for unknown_word in ([?]u64{u64(max(start_grant.Grant)) + 1, 999, max(u64)}) {
		req := make_valid_start_request(payload[:])
		req.requested_grant_count = 1
		req.requested_grant_words[0] = unknown_word
		testing.expect_value(t, validate_start_from_bytes_request(&req, payload[:]).refusal, Start_From_Bytes_Refusal.Unknown_Grant)
	}

	dup_grant := make_valid_start_request(payload[:])
	dup_grant.requested_grant_count = 2
	dup_grant.requested_grant_words[0] = u64(start_grant.Grant.Store)
	dup_grant.requested_grant_words[1] = u64(start_grant.Grant.Store)
	testing.expect_value(t, validate_start_from_bytes_request(&dup_grant, payload[:]).refusal, Start_From_Bytes_Refusal.Duplicate_Grant)

	too_many_grants := make_valid_start_request(payload[:])
	too_many_grants.requested_grant_count = GRANT_REQUEST_CAPACITY + 1
	testing.expect_value(t, validate_start_from_bytes_request(&too_many_grants, payload[:]).refusal, Start_From_Bytes_Refusal.Too_Many_Grants)

	// Valid sandboxed request (0 grants) and valid Store request pass.
	clean := make_valid_start_request(payload[:])
	clean.import_count = 2
	clean.import_hashes[0] = make_test_hash(1)
	clean.import_hashes[1] = make_test_hash(2)
	res := validate_start_from_bytes_request(&clean, payload[:])
	testing.expect_value(t, res.refusal, Start_From_Bytes_Refusal.None)
	testing.expect_value(t, res.grants, Disk_Start_Grants{})

	with_store := clean
	with_store.requested_grant_count = 1
	with_store.requested_grant_words[0] = u64(start_grant.Grant.Store)
	res_store := validate_start_from_bytes_request(&with_store, payload[:])
	testing.expect_value(t, res_store.refusal, Start_From_Bytes_Refusal.None)
	testing.expect(t, .Store in res_store.grants)
}

@(test)
disk_rows_set_enforces_narrow_classes_and_single_start_policy :: proc(t: ^testing.T) {
	// Zero generation and row count past capacity are refused.
	zero_gen: Disk_Rows_Set_Request
	testing.expect_value(t, validate_disk_rows_set_request(&zero_gen).refusal, Disk_Rows_Set_Refusal.Zero_Generation)

	too_many := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = DISK_ROWS_CAPACITY + 1}
	testing.expect_value(t, validate_disk_rows_set_request(&too_many).refusal, Disk_Rows_Set_Refusal.Too_Many_Rows)

	// Unknown row classes (0, 4, max(u32)) are refused.
	for bad_class in ([?]u32{0, u32(Disk_Row_Class.Client_Key) + 1, 99, max(u32)}) {
		req := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 1}
		req.rows[0].class_word = bad_class
		testing.expect_value(t, validate_disk_rows_set_request(&req).refusal, Disk_Rows_Set_Refusal.Unknown_Row_Class)
	}

	// Start_Policy is refused for non-zero principal.
	non_zero_sp := Disk_Rows_Set_Request{principal = 1, generation = 1, row_count = 1}
	non_zero_sp.rows[0].class_word = u32(Disk_Row_Class.Start_Policy)
	non_zero_sp.rows[0].nickname_length = fill_nickname(&non_zero_sp.rows[0].nickname, "custom-policy")
	non_zero_sp.rows[0].module_hash = make_test_hash(10)
	testing.expect_value(t, validate_disk_rows_set_request(&non_zero_sp).refusal, Disk_Rows_Set_Refusal.Start_Policy_Requires_Principal_Zero)

	// Two Start_Policy rows for principal 0 are refused.
	two_sp := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 2}
	two_sp.rows[0].class_word = u32(Disk_Row_Class.Start_Policy)
	two_sp.rows[0].nickname_length = fill_nickname(&two_sp.rows[0].nickname, "policy-a")
	two_sp.rows[0].module_hash = make_test_hash(11)
	two_sp.rows[1].class_word = u32(Disk_Row_Class.Start_Policy)
	two_sp.rows[1].nickname_length = fill_nickname(&two_sp.rows[1].nickname, "policy-b")
	two_sp.rows[1].module_hash = make_test_hash(12)
	testing.expect_value(t, validate_disk_rows_set_request(&two_sp).refusal, Disk_Rows_Set_Refusal.Multiple_Start_Policy_Rows)

	// Store row exceeding block limit or smuggling client_key is refused.
	bad_blocks := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 1}
	bad_blocks.rows[0].class_word = u32(Disk_Row_Class.Store)
	bad_blocks.rows[0].nickname_length = fill_nickname(&bad_blocks.rows[0].nickname, "notes-disk")
	bad_blocks.rows[0].module_hash = make_test_hash(13)
	bad_blocks.rows[0].store_blocks = STORE_BLOCKS_LIMIT + 1
	testing.expect_value(t, validate_disk_rows_set_request(&bad_blocks).refusal, Disk_Rows_Set_Refusal.Store_Blocks_Out_Of_Range)

	smuggled := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 1}
	smuggled.rows[0].class_word = u32(Disk_Row_Class.Store)
	smuggled.rows[0].nickname_length = fill_nickname(&smuggled.rows[0].nickname, "notes-disk")
	smuggled.rows[0].module_hash = make_test_hash(13)
	smuggled.rows[0].client_uses_word = 1
	testing.expect_value(t, validate_disk_rows_set_request(&smuggled).refusal, Disk_Rows_Set_Refusal.Unexpected_Field_Data)

	// Client_Key row with Input without View is refused; zero key and duplicate key refused.
	bad_uses := Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 1}
	bad_uses.rows[0].class_word = u32(Disk_Row_Class.Client_Key)
	bad_uses.rows[0].client_key[0] = 0xAA
	bad_uses.rows[0].client_uses_word = remote.client_uses_word({.Input})
	testing.expect_value(t, validate_disk_rows_set_request(&bad_uses).refusal, Disk_Rows_Set_Refusal.Bad_Client_Uses)

	// Valid mixed request: Store + single Start_Policy + Client_Key passes.
	valid := Disk_Rows_Set_Request{principal = 0, generation = 2, row_count = 3}
	valid.rows[0].class_word = u32(Disk_Row_Class.Store)
	valid.rows[0].nickname_length = fill_nickname(&valid.rows[0].nickname, "editor-disk")
	valid.rows[0].module_hash = make_test_hash(20)
	valid.rows[0].store_blocks = 128

	valid.rows[1].class_word = u32(Disk_Row_Class.Start_Policy)
	valid.rows[1].nickname_length = fill_nickname(&valid.rows[1].nickname, "boot-policy")
	valid.rows[1].module_hash = make_test_hash(21)

	valid.rows[2].class_word = u32(Disk_Row_Class.Client_Key)
	valid.rows[2].client_key[0] = 0x42
	valid.rows[2].client_uses_word = remote.client_uses_word({.Calls, .View})

	summary := validate_disk_rows_set_request(&valid)
	testing.expect_value(t, summary.refusal, Disk_Rows_Set_Refusal.None)
	testing.expect_value(t, summary.store_row_count, u32(1))
	testing.expect_value(t, summary.start_policy_row_count, u32(1))
	testing.expect_value(t, summary.client_key_row_count, u32(1))
}

@(test)
device_identity_table_and_grant_spec_refuse_unknown_duplicates_and_escalation :: proc(t: ^testing.T) {
	table := device_identity_table_default()
	testing.expect_value(t, device_identity_table_validate(&table), Device_Identity_Refusal.None)

	// Border checks on Device_Class_Role.
	for bad_role in ([?]u64{0, u64(Device_Class_Role.Gpu_Device) + 1, 99, max(u64)}) {
		role, ok := device_class_role_from_word(bad_role)
		testing.expect(t, !ok && role == .None)
	}

	// Refuses invalid PCI IDs (0x0000, 0xFFFF), duplicate identity, unknown lookup.
	testing.expect_value(t, device_identity_table_add(&table, {pci_vendor_id = 0, pci_device_id = 1, role = .Block_Device, required_bar_count = 1}), Device_Identity_Refusal.Invalid_Pci_Id)
	testing.expect_value(t, device_identity_table_add(&table, {pci_vendor_id = 0xFFFF, pci_device_id = 1, role = .Block_Device, required_bar_count = 1}), Device_Identity_Refusal.Invalid_Pci_Id)
	testing.expect_value(t, device_identity_table_add(&table, {pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_BLOCK, role = .Block_Device, required_bar_count = 1}), Device_Identity_Refusal.Duplicate_Identity)
	_, unknown_refusal := device_identity_table_lookup(&table, 0x1234, 0x5678)
	testing.expect_value(t, unknown_refusal, Device_Identity_Refusal.Unknown_Identity)

	// Valid attenuated grant spec for VirtIO Block.
	valid_spec := Device_Grant_Spec {
		location            = {bus = 0, device = 0x10, function = 0},
		pci_vendor_id       = PCI_VENDOR_VIRTIO,
		pci_device_id       = PCI_DEVICE_VIRTIO_BLOCK,
		role                = .Block_Device,
		bar_count           = 1,
		bars                = {0 = {base_address = 0xFE00_0000, page_count = 4}},
		interrupt_vector    = 0x40,
		has_interrupt       = true,
		iommu_allowed       = true,
		config_read_only    = true,
		granted_rights_word = DEVICE_GRANT_ALLOWED_RIGHTS_MASK,
	}
	testing.expect_value(t, validate_device_grant_spec(&valid_spec, &table), Device_Grant_Refusal.None)

	// Config write attempt refused.
	bad_cfg := valid_spec
	bad_cfg.config_read_only = false
	testing.expect_value(t, validate_device_grant_spec(&bad_cfg, &table), Device_Grant_Refusal.Config_Write_Forbidden)

	// Role mismatch refused.
	bad_role := valid_spec
	bad_role.role = .Network_Device
	testing.expect_value(t, validate_device_grant_spec(&bad_role, &table), Device_Grant_Refusal.Role_Mismatch)

	// Unaligned and overlapping BARs refused.
	unaligned := valid_spec
	unaligned.bars[0].base_address = 0xFE00_0001
	testing.expect_value(t, validate_device_grant_spec(&unaligned, &table), Device_Grant_Refusal.Invalid_Bar_Range)

	overlapping := valid_spec
	overlapping.bar_count = 2
	overlapping.bars[1] = {base_address = 0xFE00_2000, page_count = 2}
	testing.expect_value(t, validate_device_grant_spec(&overlapping, &table), Device_Grant_Refusal.Overlapping_Bar_Ranges)

	// Elevated rights (Control, Devices, Spend, Give, Debug, 0) refused.
	for bad_rights in ([?]u64{
		0,
		DEVICE_GRANT_ALLOWED_RIGHTS_MASK | (u64(1) << u64(op.Right.Control)),
		DEVICE_GRANT_ALLOWED_RIGHTS_MASK | (u64(1) << u64(op.Right.Devices)),
		DEVICE_GRANT_ALLOWED_RIGHTS_MASK | (u64(1) << u64(op.Right.Spend)),
		DEVICE_GRANT_ALLOWED_RIGHTS_MASK | (u64(1) << u64(op.Right.Debug)),
		max(u64),
	}) {
		spec := valid_spec
		spec.granted_rights_word = bad_rights
		testing.expect_value(t, validate_device_grant_spec(&spec, &table), Device_Grant_Refusal.Elevated_Or_Empty_Rights)
	}

	// TPM does not need IOMMU; granting IOMMU to TPM is refused.
	tpm_spec := Device_Grant_Spec {
		location            = {bus = 0, device = 0x1F, function = 0},
		pci_vendor_id       = PCI_VENDOR_INFINEON_TPM,
		pci_device_id       = PCI_DEVICE_TPM_SLB9670,
		role                = .Tpm_Device,
		bar_count           = 1,
		bars                = {0 = {base_address = 0xFED4_0000, page_count = 5}},
		has_interrupt       = false,
		iommu_allowed       = true,
		config_read_only    = true,
		granted_rights_word = DEVICE_GRANT_ALLOWED_RIGHTS_MASK,
	}
	testing.expect_value(t, validate_device_grant_spec(&tpm_spec, &table), Device_Grant_Refusal.Unauthorized_Iommu)
	tpm_spec.iommu_allowed = false
	testing.expect_value(t, validate_device_grant_spec(&tpm_spec, &table), Device_Grant_Refusal.None)
}

@(test)
canonical_role_catalog_covers_all_14_core_roles_with_unique_blake3_hashes :: proc(t: ^testing.T) {
	// Refuse None and out-of-range role words.
	for bad in ([?]role_contract.Role{.None, role_contract.Role(u64(max(role_contract.Role)) + 1), role_contract.Role(max(u64))}) {
		_, ok := role_contract_by_role(bad)
		testing.expect(t, !ok)
		_, h_ok := role_contract_hash_by_role(bad)
		testing.expect(t, !h_ok)
	}

	hashes: [len(CORE_CATALOG_ROLES)]role_contract.Contract_Hash
	display_hash := role_contract.display_contract_hash()
	powerbox_hash := role_contract.powerbox_contract_hash()

	for role, idx in CORE_CATALOG_ROLES {
		contract, ok := role_contract_by_role(role)
		testing.expectf(t, ok, "catalog must contain contract for role %v", role)
		testing.expect_value(t, contract.role, role)
		testing.expect(t, contract.version >= 1)
		testing.expect(t, len(contract.faces) >= 1)

		digest, hash_ok := role_contract_hash_by_role(role)
		testing.expectf(t, hash_ok, "contract_hash must succeed for role %v", role)
		testing.expect(t, digest != (role_contract.Contract_Hash{}))
		// Deterministic repeatability.
		digest_again, hash_ok_again := role_contract_hash_by_role(role)
		testing.expect(t, hash_ok_again)
		testing.expect_value(t, digest, digest_again)

		// Distinct from Display, Powerbox, and every earlier core role.
		testing.expect(t, digest != display_hash)
		testing.expect(t, digest != powerbox_hash)
		for earlier in 0 ..< idx {
			testing.expectf(t, hashes[earlier] != digest, "duplicate contract hash between roles %v and %v", CORE_CATALOG_ROLES[earlier], role)
		}
		hashes[idx] = digest
	}
}

@(test)
principals_ring_command_and_status_borders :: proc(t: ^testing.T) {
	for bad in ([?]u32{0, u32(max(Principals_Ring_Command)) + 1, max(u32)}) {
		_, ok := principals_ring_command_from_word(bad)
		testing.expect(t, !ok)
	}
	for cmd in Principals_Ring_Command {
		if cmd == .None {
			continue
		}
		got, ok := principals_ring_command_from_word(u32(cmd))
		testing.expect(t, ok)
		testing.expect_value(t, got, cmd)
	}
	for bad in ([?]u32{u32(max(Principals_Ring_Status)) + 1, max(u32)}) {
		_, ok := principals_ring_status_from_word(bad)
		testing.expect(t, !ok)
	}
	for st in Principals_Ring_Status {
		got, ok := principals_ring_status_from_word(u32(st))
		testing.expect(t, ok)
		testing.expect_value(t, got, st)
	}
}

// The ring of the devices service: zero, the word after the last command
// and the largest word are refused; each command, Lookup_Identity
// included, is taken last. The same for the statuses, where zero is Ok.
@(test)
devices_ring_words_refuse_unknown_commands_and_statuses :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(Devices_Ring_Command.Lookup_Identity) + 1, max(u32)}) {
		_, ok := devices_ring_command_from_word(word)
		testing.expectf(t, !ok, "the command word %d is taken", word)
	}
	for word in ([?]u32{u32(Devices_Ring_Status.Bad_Command) + 1, max(u32)}) {
		_, ok := devices_ring_status_from_word(word)
		testing.expectf(t, !ok, "the status word %d is taken", word)
	}
	for command in Devices_Ring_Command {
		if command == .None {
			continue
		}
		got, ok := devices_ring_command_from_word(u32(command))
		testing.expect(t, ok)
		testing.expect_value(t, got, command)
	}
	testing.expect_value(t, u32(Devices_Ring_Command.Lookup_Identity), u32(5))
	for status in Devices_Ring_Status {
		got, ok := devices_ring_status_from_word(u32(status))
		testing.expect(t, ok)
		testing.expect_value(t, got, status)
	}
}

// The answer of a Lookup_Identity at the border of the core: a role of
// zero, past the last member and of the largest word; a count of BARs of
// 0, one past PCI_BAR_CAPACITY and the largest word; a flag of 2; and a
// word after the flags that is not zero are each refused. The answer of
// each default identity is read back whole last.
@(test)
device_identity_answers_refuse_out_of_range_words :: proc(t: ^testing.T) {
	table := device_identity_table_default()
	block, _ := device_identity_table_lookup(&table, PCI_VENDOR_VIRTIO, PCI_DEVICE_VIRTIO_BLOCK)
	good := device_identity_answer_values(block)
	bad_answers := [?]struct {
		place: int,
		word:  u64,
	}{
		{0, 0},
		{0, u64(max(Device_Class_Role)) + 1},
		{0, max(u64)},
		{1, 0},
		{1, PCI_BAR_CAPACITY + 1},
		{1, max(u64)},
		{2, 2},
		{2, max(u64)},
		{3, 2},
		{4, 1},
		{5, max(u64)},
		{6, 1},
	}
	for bad in bad_answers {
		values := good
		values[bad.place] = bad.word
		_, ok := device_identity_answer_of_values(values, PCI_VENDOR_VIRTIO, PCI_DEVICE_VIRTIO_BLOCK)
		testing.expectf(t, !ok, "the word %d at %d is taken", bad.word, bad.place)
	}
	for index in 0 ..< int(table.count) {
		entry := table.entries[index]
		read, ok := device_identity_answer_of_values(device_identity_answer_values(entry), entry.pci_vendor_id, entry.pci_device_id)
		testing.expect(t, ok)
		testing.expect_value(t, read, entry)
	}
}

// The bind places of the region: a negative place, the count and the
// largest int are refused; the first and the last place are taken, apart,
// with the specification after the discovered record and inside the
// region.
@(test)
devices_bind_places_stay_inside_the_region :: proc(t: ^testing.T) {
	for place in ([?]int{-1, DEVICES_BIND_PLACE_COUNT, max(int)}) {
		_, _, ok := devices_bind_place_offsets(place)
		testing.expectf(t, !ok, "the place %d is taken", place)
	}
	region_bytes := u64(DEVICES_REGION_PAGES * op.PAGE_SIZE)
	first_discovered, first_spec, first_ok := devices_bind_place_offsets(0)
	last_discovered, last_spec, last_ok := devices_bind_place_offsets(DEVICES_BIND_PLACE_COUNT - 1)
	testing.expect(t, first_ok && last_ok)
	testing.expect_value(t, first_discovered, u64(0))
	testing.expect(t, first_spec >= first_discovered + size_of(Pci_Discovered_Device))
	testing.expect(t, last_discovered >= first_spec + size_of(Device_Grant_Spec))
	testing.expect(t, last_spec + size_of(Device_Grant_Spec) <= region_bytes)
}
