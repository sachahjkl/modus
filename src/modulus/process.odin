package kernel

import "modus:contract/errors"
import "modus:contract/input_history"
import "modus:contract/ring"
import "base:intrinsics"
import op "modus:contract/operation"
import "modulus:extended_switch"
import "modulus:processor_counters"

// The objects, the handle tables, the processes and their threads
// (docs/ARCHITECTURE.md, "Handle table"). The scheduler is in schedule.odin
// and strategy.odin.
// All tables are flat arrays with a fixed capacity. Index 0 of each table is
// not used, so that 0 means "none".

USER_END :: u64(op.USER_END)
REGION_CAPACITY :: 2048
// The root budget holds the log records of a process of normal use for
// each process slot: the contract counts the slots of the kernel.
PROCESS_CAPACITY :: op.PROCESS_SLOTS_OF_THE_MACHINE
HANDLE_CAPACITY :: op.HANDLE_TABLE_CAPACITY
MAPPING_CAPACITY :: 128

// A memory object: pages, each with a page frame or with none yet.
//
// A page on first use gets its page frame at the first read or write, by a
// process (a page fault) or by the kernel (user_range). The budget paid for
// each page when the object was created: the page is reserved, so a free
// page frame exists for it at any time, and an access never fails for lack
// of memory. A page that nobody touched costs no page frame and no zeroing.
//
// The frames of an object that is not contiguous are in its frame list:
// in `frames` for at most REGION_INLINE_PAGES pages; else one list page of
// 512 frames, or for more pages a top page of list pages. The budget pays
// for the list pages too. 0 in the list: the page has no frame yet.
//
// A contiguous object has its frames in one block from `physical`, all
// given at creation: device memory, and the memory that the kernel itself
// reads through the direct map (a thread area, the first process).
REGION_INLINE_PAGES :: op.MEMORY_INLINE_PAGES
LIST_ENTRIES :: op.MEMORY_LIST_ENTRIES

Region :: struct {
	physical:   u64, // Contiguous: the first frame.
	page_count: u64, // 0: the slot is free.
	frames:     [REGION_INLINE_PAGES]u64, // Not contiguous: the frame list (see above).
	present:    u64, // Pages that have a frame.
	references: u32, // Handles and mappings.
	budget:     u32, // The budget that paid. 0 for a device.
	device:     bool, // The frames are not from the page frame table: a framebuffer, boot data, the registers of a device.
	contiguous: bool,
	uncached:   bool, // The registers of a device: a mapping uses no cache.
	uncommitted: bool, // Made Uncommitted: a page is paid when it is committed (the bit SLOT_COMMITTED of its slot).
	large_pages: bool, // Made Large_Pages: contiguous, aligned on 2 MiB, a whole number of large pages.
	committed:  u64, // Uncommitted: the committed pages. Region lock and frame lock to change it.
	marked_pages: u64, // The pages whose slot has a mark of protection (Memory_Protect of a part). Region lock; read atomically.
	serial:     u64, // A number that no other memory object has had: a slot of the table serves many objects in time.
	requester:  u32, // Device memory over the registers of a function of the bus: 1 + the requester identifier that the unit sees for its accesses, when the IOMMU is in use and a unit gives it a domain (iommu.odin). 0: none.
	bridge_function: u32, // A function behind a conventional bridge: 1 + its own requester identifier, while `requester` names the one that it shares with the devices behind the bridge. 0: a function with its own requester.
	declared:          u32, // A bit for each device slot of the IOMMU whose domain maps the pages (iommu.odin). Frame lock.
	declared_writable: u32, // The slots of `declared` whose device can also write the pages. Frame lock.
	// Count of mappings of this region currently held by active recorded or
	// replayed processes (record_replay.odin). Atomic: prevents another process
	// from gaining a writable mapping to a recorded/replayed region.
	recorded_mappings: u32,
}

// The state of a page in its slot of the frame list (docs/ARCHITECTURE.md,
// "The virtual memory of a process", "The state of a page"): a frame is
// aligned on 4096 bytes, so the low 12 bits of a slot hold the state.
SLOT_COMMITTED :: u64(1) // Uncommitted objects only: the budget paid for the page.
SLOT_DENY_WRITE :: u64(1) << 1
SLOT_DENY_EXECUTE :: u64(1) << 2
SLOT_NO_ACCESS :: u64(1) << 3
SLOT_STATE :: u64(PAGE_SIZE - 1)
SLOT_MARKS :: SLOT_DENY_WRITE | SLOT_DENY_EXECUTE | SLOT_NO_ACCESS

// region_page_state gives the state bits of a page of an object with a
// frame list; 0 for a contiguous object.
region_page_state :: proc "contextless" (region: ^Region, page: u64) -> u64 {
	if region.contiguous {
		return 0
	}
	return intrinsics.atomic_load(region_slot(region, page)) & SLOT_STATE
}

// page_committed says if a page can have a frame: each page of an object
// that is not Uncommitted, a committed page of one that is.
page_committed :: #force_inline proc "contextless" (region: ^Region, state: u64) -> bool {
	return !region.uncommitted || state & SLOT_COMMITTED != 0
}

region_serial: u64 // The serial of the last memory object.
// The reserved pages: paid by a budget, with no page frame yet. The kernel
// keeps free_frames = the pages of all the budgets + reserved_pages.
reserved_pages: u64

// The `object` of a handle slot, by kind:
//   Memory: index in regions       Process: index in processes
//   Interrupt: index in the interrupt tables (INTERRUPT_CAPACITY)
//   Ports: first port; count: number of ports
//   Thread: index in threads       Budget: index in budgets
Object_Kind :: op.Object_Kind

// The rights of the handle of a new object, by kind.
RIGHTS_MEMORY :: op.Rights{.Give, .Read, .Write, .Execute}
// A process: Debug makes its holder the debugger of the process
// (fault_ring.odin). The process that creates a process has it, as it has
// the memory that it maps in that process; a copy that it gives has it only
// when the giver names it.
RIGHTS_PROCESS :: op.Rights{.Give, .Read, .Control, .Debug}
// A thread: Control ends it; Inspect holds it and reads its registers;
// Write writes them (op.thread_control_rights).
RIGHTS_THREAD :: op.Rights{.Give, .Read, .Write, .Control, .Inspect}
RIGHTS_PORTS :: op.Rights{.Give}
RIGHTS_INTERRUPT :: op.Rights{.Give, .Read}
RIGHTS_MACHINE :: op.Rights{.Give, .Inspect, .Devices, .Stop, .Physical, .Schedule, .Events, .Counters}
RIGHTS_BUDGET :: op.Rights{.Give, .Read, .Spend, .Commit}
RIGHTS_LOG :: op.Rights{.Give, .Write}

Handle_Slot :: struct {
	kind:       Object_Kind,
	ended:      u8, // An empty slot: how the handle of the generation before ended (errors.End). For an error record.
	generation: u16,
	rights:     op.Rights,
	object:     u32,
	count:      u32,
	through:    u64, // Not 0: the serial of the memory object that the handle came through (Handle_Give).
}

Mapping :: struct {
	address:    u64,
	page_count: u64, // 0: the slot is free.
	first:      u64, // The first page of the memory object.
	bits:       u64, // The protection bits of each page table entry of the mapping.
	region:     u32,
	// The pages of the mapping whose entry is present. Written only where an
	// entry of the mapping becomes present or the mapping ends, each time
	// under the process lock: map_region, page_give, unmap. A report reads it
	// in place of a walk of the page table (its cost is one read for each
	// mapping, not one for each page).
	present_page_count: u64,
	// The protection that the handle permitted when the process mapped the
	// object: Memory_Protect can give back what `bits` lost, never more.
	limit_bits: u64,
	large:           bool, // Each 2 MiB of the mapping is one large page (an object made Large_Pages).
	protected:       bool, // Memory_Protect changed the protection of pages of the mapping.
	receive_handles: bool, // Memory_Map passed Map_Flag.Receive_Handles: this process agrees to receive handles through this memory.
}

// page_bits gives the bits of a page table entry for a page of a mapping
// with its state bits (region_page_state): 0 is no access.
page_bits :: proc "contextless" (mapping: ^Mapping, state: u64) -> u64 {
	if mapping.bits & PAGE_PRESENT == 0 || state & SLOT_NO_ACCESS != 0 {
		return 0
	}
	bits := mapping.bits
	if state & SLOT_DENY_WRITE != 0 {
		bits &~= PAGE_WRITE
	}
	if state & SLOT_DENY_EXECUTE != 0 {
		bits |= PAGE_NO_EXECUTE
	}
	return bits
}


// A thread: one flow of execution in a process. It is a register state and
// a kernel ring. Its stack is memory of the process: the kernel does not
// know it.
//
// The first 64 bytes are the hot line of the scheduler: what a pick, a wake
// and a tick read (docs/SCHEDULING.md, "The hot data"). The record is
// aligned on 64 bytes, so the line is one cache line.
Thread :: struct #align (64) {
	// Scheduling (schedule.odin, strategy.odin), under the run lock of home.
	state:          op.Process_State, // None, Ready, Waiting or Stopped.
	home:           u32, // The processor whose run queue the thread is in, or was in last.
	queue_next:     u32,
	queue_previous: u32,
	processor:      u32, // 1 + the index of the processor that runs the thread. 0: none.
	budget:         u32, // The budget that paid for the slot. Written under the frame lock (atomic).
	weight:         u32, // 1 to op.WEIGHT_FULL. Written at the creation, then by thread_schedule_write.
	request:        u32, // Microseconds: the request of EEVDF. Written at the creation, then by thread_schedule_write.
	// The fields of the strategy of the queue of home (strategy.odin). Zero
	// is valid for each strategy: the thread is not placed.
	virtual:          u64, // The virtual time.
	virtual_deadline: u64, // EEVDF.
	lag:              i64, // At the last wait: EEVDF, the lag; fair, the distance to the queue clock.
	queued:           bool,
	placed:           bool, // The strategy placed the thread: virtual means something.
	// The thread has breakpoints (breakpoints.odin): the processor that
	// takes it loads its debug registers. It is in this line so that a
	// switch to a thread with no breakpoint reads no other line for it.
	// Written under the process lock, while the thread is held or to clear
	// it (atomic: a switch and a debug exception read it).
	has_breakpoints:  bool,
	// The set `processors` below does not hold every processor of the
	// machine: a processor that takes the thread from the queue of another
	// one, the processor that the thread leaves, and a waker that looks
	// for an idle processor then read that set. It is in this line so
	// that a thread with no placement costs these paths one test of a
	// byte that they have already, and no read of another line. Written
	// with `processors`.
	placement_restricted: bool,
	// The thread counts the events of the processor for its own code
	// (thread_counters.odin): the processor that takes it turns its
	// counters on, the processor that leaves it adds them to
	// `counter_totals`. In this line so that a switch to a thread that does
	// not count reads no other line for it. Only the processor that runs
	// the thread writes it: the thread in its own kernel entry.
	counting: bool,
	// Whether this thread is recorded or replayed (record_replay.odin).
	// Kept in the hot line so switching normal threads reads no extra line.
	record_mode: input_history.Record_Mode,
	frame:        Frame,
	extended_state: Extended_State_Area, // Complete while the thread is on no processor: schedule saves it when a processor leaves the thread, and restores it when a processor takes it (docs/ARCHITECTURE.md, "The extended state of the processor").
	process:      u32,
	number:       u32, // The index of the thread area in the process.
	ring:         ring.Ring,
	record:       u64, // The address of the thread record in the process.
	events:       ^u32, // The `events` word of the thread record, for the kernel.
	deadline:     u64,
	references:   u32, // Handles to this thread.
	in_enter:     bool,
	run_time:     u64,
	// The word wait of the entry in progress or of the wait in progress:
	// the physical addresses of the words.
	words:        [op.WORD_WAIT_CAPACITY]u64,
	word_count:   u32, // The words registered in the wait table (wait.odin).
	word_changed: bool, // A word did not hold the value: this entry does not wait.
	wait_serial:  u32, // Changes when a wait ends: wait.odin. Run lock of home.
	woken:        bool, // A waker came while the thread registered its words. Run lock of home.
	stop_requested: bool, // Another processor ends the thread: its processor ends it (atomic).
	finished:     bool, // thread_finish ran: the thread area is free. Control lock.
	serial:       u32, // Changes for each new thread in the slot (the record of the gs register).
	// The thread record of the thread through the direct map: the kernel
	// writes the fault ring there when this thread is the fault handler of
	// its process. nil after thread_finish. Process lock.
	record_in_kernel: ^op.Thread_Record,
	// The thread waits in the fault ring for an answer (fault_ring.odin).
	// Written under the process lock; the thread is Waiting with no deadline
	// while it is true.
	fault_waits:   bool,
	fault_serial:  u64, // The serial of that fault: Process.fault_serial when it came. Process lock.
	fault_address: u64, // The address of the access of that fault. Process lock.
	// The instruction address and the frame pointer of that fault: a
	// write of Thread_Control changes the frame while the thread waits,
	// and the stop report of the answer Stop names the fault, not the
	// write. Process lock.
	fault_instruction:   u64,
	fault_frame_pointer: u64,
	// The control of a thread (thread_control.odin). The stop count: the
	// thread enters no run queue while it is above 0. Written under the
	// run lock of home (atomic: kernel_interrupt reads it with no lock).
	control_stops: u32,
	// Thread_Control wrote the registers or the extended state since the
	// last fault of the thread: Fault_Answer then accepts Resume for any
	// kind. Process lock.
	registers_written: bool,
	// The breakpoints of the thread, and the value of the debug control
	// register for them (breakpoints.odin). They mean something only while
	// has_breakpoints is true. Written under the process lock while the
	// thread is held; the processor that takes the thread reads them.
	breakpoints:        op.Thread_Breakpoints,
	breakpoint_control: u64,
	// The record of the fault that the thread waits for is in the ring of
	// the debugger of its process, not in the ring of its process: only
	// the debugger answers it. Process lock.
	fault_to_debugger: bool,
	// The stops of control_stops that the debugger of the process made:
	// the end of the debugging takes them back, and no others. Never
	// above control_stops: a Resume that is not of the debugger takes
	// only a stop that is not of the debugger. Process lock.
	debug_stops: u32,
	// The debugger of the process wrote the trap flag that is in the
	// frame of the thread: the end of the debugging clears that flag, and
	// a single step that comes after that end is dropped and stops no
	// process. It stays true through the record of a step, until the next
	// write of the registers. A trap flag that the process set itself
	// never has this mark. Process lock.
	debugger_step: bool,
	// The process whose debug handler this thread is (fault_ring.odin). 0:
	// none. Written under the control lock (atomic: Fault_Handler_Set reads
	// it under the process lock of the thread only).
	debugs_process: u32,
	// The most that the weight can be: 1 to op.WEIGHT_FULL. Only a write
	// of the schedule through the machine handle changes it; a new thread
	// gets the limit of a new thread of its creator
	// (creation_weight_limit). Read at a write of the schedule and at a
	// creation only, so it is not in the hot line.
	// Written under the run lock of home (atomic: a diagnosis reads it
	// with no lock).
	weight_limit: u32,
	// The weight limit of a thread that this thread creates, and of the
	// first thread of a process that it starts, with the value of its
	// process as a second bound (creation_weight_limit): 1 to
	// weight_limit. Only a write of the schedule through the machine
	// handle changes it; a new thread gets the limit of its creation as
	// its weight limit and as its own value. It bounds the weight of a
	// thread that the share policy never saw (docs/SCHEDULING.md, "A share
	// for each process"). Read at a write of the schedule and at a
	// creation only. Written under the run lock of home (atomic: a
	// creation and a diagnosis read it with no lock).
	new_thread_weight_limit: u32,
	// The placement of the thread (docs/SCHEDULING.md, "The placement of a
	// thread"). `processors`: bit n says that the processor n can run the
	// thread; never 0, and only processors that the machine has. Read
	// only when placement_restricted is true, so it is not in the hot
	// line. `processors_limit`: the most that `processors` can be; only a
	// write of the placement through the machine handle changes it, and a
	// new thread gets the limit of the thread that creates it. Both are
	// written at the creation, then under the run lock of home by a write
	// of the placement (atomic: a waker and a creation read them with no
	// lock).
	processors:       u64,
	processors_limit: u64,
	// The counts of the thread up to its last leave of a processor, while
	// `counting` is true (thread_counters.odin). The processor that runs
	// the thread reads and writes them: the release of the run lock at the
	// leave orders them before the take of another processor.
	counter_totals: [processor_counters.Event]u64,
	// Per-thread record/replay entry state (record_replay.odin). Written and
	// read only by the processor running this thread.
	replay_return_time:  u64,  // Return value placed in rax on kernel entry return.
	record_wait_pending: bool, // Pure wait entry deferred until wake so post-wake time and point copies are recorded.
	// The recorded thread runs its own instructions, between two input
	// points: its shared writers wait (record_replay.odin). Written and read
	// only by the processor running this thread.
	record_outside_point: bool,
	// The recorded process whose gate counted this thread of a shared writer
	// as running on its processor, and the generation of that record: the
	// leave of the processor ends that run (record_replay.odin). 0: none.
	// Written and read only by the processor running this thread.
	shared_writer_gate_process:    u32,
	shared_writer_gate_generation: u64,
	// Extended-state switch tracking (modulus:extended_switch): generation
	// bumped on creation, Thread_Control writes, or stop, plus the processor
	// (1 + index, 0 for none) that last saved this thread's extended state.
	extended_switch: extended_switch.Thread_State,
}

#assert(offset_of(Thread, placed) < 64)
#assert(offset_of(Thread, counting) < 64)
#assert(offset_of(Thread, record_mode) < 64)
#assert(offset_of(Thread, has_breakpoints) < 64)
#assert(offset_of(Thread, placement_restricted) < 64)
// One bit of a set of processors for each processor that runs threads.
#assert(PROCESSOR_CAPACITY <= op.PLACEMENT_PROCESSOR_CAPACITY)
#assert(offset_of(Thread, frame) == 64)

// word_address gives the physical address of a 32-bit word of a process,
// or 0 if the process cannot read it.
word_address :: proc "contextless" (process: ^Process, address: u64) -> u64 {
	if address & 3 != 0 || !user_range(process, address, 4, false) {
		return 0
	}
	entry := page_entry(process.table, address)^
	// A large page: its frame is 2 MiB, and the bits 12 to 20 of the
	// address are in the page.
	if entry & PAGE_LARGE != 0 {
		return entry & PAGE_ADDRESS &~ u64(LARGE_PAGE_SIZE - 1) | address & (LARGE_PAGE_SIZE - 1)
	}
	return entry & PAGE_ADDRESS | address & (PAGE_SIZE - 1)
}

THREAD_TABLE_CAPACITY :: 256

Process :: struct {
	state:        op.Process_State, // None, Created, Ready or Stopped.
	cause:        op.Stop_Cause, // Why it stopped: set with the state Stopped, under the process lock.
	outcome:      op.Stop_Outcome, // What it said of its work: None but for the cause Itself; set with the cause.
	name:         [op.PROCESS_NAME_BYTES_MOST + 1]u8, // Zero bytes after the name.
	table:        u64,
	references:   u32, // Handles to this process.
	budget:       u32, // The budget that paid for the slot. It pays for the page tables.
	thread_areas: u32, // Bit n: thread area n is in use.
	thread_count: u32,
	has_ports:    bool,
	// The recorded process whose shared memory this process writes: its
	// threads run only while the recorded thread is at an input point
	// (record_replay.odin). 0: none. Written under the control lock (atomic:
	// the pick of a processor reads it with no lock).
	shared_writer_of: u32,
	// The new-thread weight limit of the process (op.Process_Schedule): no
	// thread of the process creates a thread with a higher weight limit.
	// 0 is op.WEIGHT_FULL, so a new process, whose record is zero, has the
	// full value (process_new_thread_weight_limit). Only a write through the
	// machine handle changes it, under the process lock (atomic: a creation
	// reads it with no lock).
	new_thread_weight_limit: u32,
	run_time:     u64,
	start_time:   u64, // Microseconds since the machine started.
	entries:       u64,
	mapped_pages:  u64,
	handles_held:  u32, // Handles currently in `handles`. Process lock.
	handles_peak:  u32, // Largest `handles_held` reached by this process. Process lock.
	mappings_held: u32, // Mappings currently in `mappings`. Process lock.
	mappings_peak: u32, // Largest `mappings_held` reached by this process. Process lock.
	handles:       [HANDLE_CAPACITY]Handle_Slot,
	mappings:     [MAPPING_CAPACITY]Mapping,
	modules:      [op.PROCESS_MODULE_CAPACITY]op.Module_Record, // What the loaders asserted (Process_Module).
	stop:         op.Stop_Report, // A process that stopped on a fault: where.
	// The processors that run a thread of the process, plus 1 while a stop
	// marks the threads; HOLDS_STOPPED when the marks are done (atomic).
	holds:        u64,
	ports_serial: u64, // Changes with each Ports handle of the process. It stays when the slot serves a new process.
	cleaned:      bool, // process_cleanup ran: the slot can be free when no handle names it. Control lock.
	serial:       u32, // Changes for each new process in the slot. It stays when the slot serves a new process.
	// The log records of this process: the count of its next record, whose
	// low 32 bits are its own number (op.Log_Record.own_number). Log lock;
	// process_create sets it to 0, when no thread of the slot runs. A new
	// process starts at 0, so its own numbers say nothing of the processes
	// before it in the slot. 64 bits: the window of the own log ring
	// (op.own_log_window) needs the count, not its low bits.
	log_records_written:  u64,
	// The Log operations of this process that its log limit refused since
	// its last accepted one. Process lock (Log runs under it); the cleanup
	// reads it after the threads ended, and writes it on the log when it is
	// not 0, so a refusal that no later line said is not silent.
	log_lines_refused: u64,
	// The frames of the own log ring of this process (op.OWN_LOG_PAGES),
	// which its budget paid: a copy of each record of the process, which
	// only its own records push out (src/md/features/own_log_ring.md).
	// Set and cleared under the log lock; all 0: no ring.
	log_ring_frames:      [op.OWN_LOG_PAGES]u64,
	// The fault ring (fault_ring.odin), under the process lock. 0: no fault
	// handler, and every fault stops the process.
	fault_handler:        u32, // The thread whose thread record holds the fault ring.
	// The fault kinds of the handler: bit n is the vector n. 0 with no
	// handler. Written under the process lock with an atomic store, and read
	// with no lock by a fault first, so that a fault that is not delivered
	// takes no lock.
	fault_kinds:          u64,
	fault_handler_serial: u32,
	fault_written:        u32, // The records that the kernel wrote in that ring: the kernel's own count, not the one in memory of the process.
	fault_full:           u32, // The faults that found the ring full.
	fault_serial:         u64, // The faults given to a ring: the serial of the next record is one more. A count of this process only.
	// The debugger of the process (fault_ring.odin), under the process
	// lock. debug_handler is a thread of
	// another process, the debugger: its debug handler. 0: no debugger.
	// It changes only with the control lock held too.
	debug_handler: u32,
	// The thread record of the debug handler through the direct map: the
	// ring that takes the records. The end of the debug handler clears it
	// under the process lock before the record is unmapped, so a fault of
	// this process never writes a record that is gone.
	debug_record:  ^op.Thread_Record,
	// The fault kinds of the debugger: bit n is the vector n. 0 with no
	// debugger. Written and read as fault_kinds.
	debug_kinds:   u64,
	debug_written: u32, // The records that the kernel wrote in the ring of the debug handler: the kernel's own count.
	debug_full:    u32, // The faults that found that ring full, since the debugger attached.
	debug_full_logged: bool, // The log has the line of the full ring: no other line until a record finds room.
}

HOLDS_STOPPED :: u64(1) << 32

// process_leave says that a processor left a thread of a process. true:
// it was the last one after a stop, and the caller cleans the process up.
process_leave :: proc "contextless" (index: u32) -> bool {
	return intrinsics.atomic_sub(&processes[index].holds, 1) - 1 == HOLDS_STOPPED
}

// process_module records a module that a loader put in a process, replaces
// the record with the same base, or removes it (size 0). Two records do not
// share an address. by_the_process: the process writes in itself. The kernel
// writes the writer of the record, and the process cannot change a record of
// its starter: else a process could name its code by the module of another
// (src/md/features/module_record_writer.md).
process_module :: proc "contextless" (process: ^Process, record: op.Module_Record, by_the_process: bool) -> Operation_Outcome {
	if record.size != 0 && (record.base >= op.USER_END || record.size > op.USER_END - record.base) {
		return .Bad_Address
	}
	place: ^op.Module_Record
	for &item in process.modules {
		if item.size != 0 && item.base == record.base {
			place = &item
		} else if item.size != 0 && record.size != 0 && record.base < item.base + item.size && item.base < record.base + record.size {
			return .Bad_Address
		} else if item.size == 0 && place == nil {
			place = &item
		}
	}
	if place == nil {
		return .No_Slot
	}
	if record.size == 0 && (place.size == 0 || place.base != record.base) {
		return .Bad_Address
	}
	if by_the_process && place.size != 0 && place.writer == u64(op.Module_Writer.Starter) {
		return .No_Right
	}
	written := record
	written.writer = by_the_process ? u64(op.Module_Writer.Process) : u64(op.Module_Writer.Starter)
	place^ = record.size == 0 ? {} : written
	return .Ok
}

// starter_module_meeting gives the module record of the writer Starter that
// meets a range of addresses of a process, or nil. The caller holds the
// process lock. The test compares offsets from the lower start, so no sum
// of an address and a size from the process wraps.
starter_module_meeting :: proc "contextless" (process: ^Process, address: u64, size: u64) -> ^op.Module_Record {
	if size == 0 {
		return nil
	}
	for &item in process.modules {
		if item.size == 0 || item.writer != u64(op.Module_Writer.Starter) {
			continue
		}
		meets := address >= item.base ? address - item.base < item.size : item.base - address < size
		if meets {
			return &item
		}
	}
	return nil
}

// module_of gives the module record of a process that holds an address, or nil.
module_of :: proc "contextless" (process: ^Process, address: u64) -> ^op.Module_Record {
	for &item in process.modules {
		if item.size != 0 && address >= item.base && address - item.base < item.size {
			return &item
		}
	}
	return nil
}

BUDGET_CAPACITY :: 128

// A budget: see operation.Budget_Amounts. Budget 0 is not live: it holds
// what returned to no budget.
Budget :: struct {
	live:       bool,
	parent:     u32, // The budget that this budget came from. It is live, or it is 0.
	references: u32, // Handles to this budget.
	amounts:    op.Budget_Amounts,
	// limit.odin:
	spent:       u64, // Cycles of processor time in this period, and what was above the part of the periods before.
	spent_total: u64, // Cycles of processor time since the budget was made.
	logged:      u64, // The second (high 32 bits) and the log records in it (low 32 bits): limit.odin.
	refused:     u64, // Log records that the kernel refused.
	ended:       bool, // The slot held a budget that ended: a tick can still walk through it (budget_create).
}

budgets: [BUDGET_CAPACITY]Budget
regions: [REGION_CAPACITY]Region
processes: [PROCESS_CAPACITY]Process
threads: [THREAD_TABLE_CAPACITY]Thread
interrupt_owner: [INTERRUPT_CAPACITY]u32 // A process.
interrupt_pending: [INTERRUPT_CAPACITY]u32
interrupt_references: [INTERRUPT_CAPACITY]u32 // Handles. A message interrupt with none is free.
// The milliseconds since the kernel made the time page. The tick of the
// first processor writes it, from the cycle counter: a tick that comes late
// loses no time. It never goes back.
time_milliseconds: u64
cycle_start: u64 // The cycle counter at the time 0.
time_region: u32 // The memory object of the time page. It is in each process.
boot_image_region: u32 // Immutable read-only boot image memory object (not MMIO).
debug_image_region: u32 // Immutable read-only debug image memory object (not MMIO).
time_record: ^op.Time_Record

// budget_create moves amounts from a budget to a new budget.
budget_create :: proc "contextless" (parent: u32, amounts: op.Budget_Amounts) -> (index: u32, status: Operation_Outcome) {
	from := &budgets[parent]
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	if !from.live || amounts.pages > from.amounts.pages || amounts.processes > from.amounts.processes || amounts.threads > from.amounts.threads || amounts.processor > from.amounts.processor || amounts.log_records > from.amounts.log_records {
		return 0, .No_Budget
	}
	for &budget, slot in budgets[1:] {
		if !budget.live {
			if budget.ended {
				// A tick or a log record can walk the chain of a thread
				// through this slot: after processor_sync, none does.
				processor_sync(all_other_processors())
			}
			from.amounts.pages -= amounts.pages
			from.amounts.processes -= amounts.processes
			from.amounts.threads -= amounts.threads
			// Log reads it with no lock (budget_log).
			intrinsics.atomic_sub(&from.amounts.log_records, amounts.log_records)
			budget = {live = true, parent = parent, amounts = amounts}
			// The count of this second moves with the log records.
			budget_log_count_to_child(parent, u32(slot + 1))
			return u32(slot + 1), .Ok
		}
	}
	return 0, .No_Slot
}

// budget_release closes one handle to a budget. With no handle, the budget
// ends: what it holds returns to its parent, and its parent pays for the
// objects that it paid for.
budget_release :: proc "contextless" (index: u32) {
	budget := &budgets[index]
	// A copy of a Budget handle in its own process adds 1 with no control
	// lock: the count is atomic.
	if intrinsics.atomic_sub(&budget.references, 1) != 1 {
		return
	}
	parent := budget.parent
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	budgets[parent].amounts.pages += budget.amounts.pages
	budgets[parent].amounts.processes += budget.amounts.processes
	budgets[parent].amounts.threads += budget.amounts.threads
	for &region in regions {
		if region.page_count != 0 && region.budget == index {
			region.budget = parent
		}
	}
	for &process in processes {
		if process.state != .None && process.budget == index {
			intrinsics.atomic_store(&process.budget, parent) // read_log_count reads it with an atomic load.
		}
	}
	for &thread in threads {
		if thread.state != .None && thread.budget == index {
			intrinsics.atomic_store(&thread.budget, parent)
		}
	}
	for &other in budgets {
		if other.live && other.parent == index {
			intrinsics.atomic_store(&other.parent, parent)
		}
	}
	// After its processes and threads moved: the records that it wrote in
	// this second stay spent in its parent. Its amount returns after its
	// count, so a Log of the parent meanwhile is checked against the
	// smaller amount and never passes it.
	budget_log_count_to_parent(index, parent)
	intrinsics.atomic_add(&budgets[parent].amounts.log_records, budget.amounts.log_records)
	budget^ = {ended = true, parent = parent}
}

list_pages :: op.memory_list_pages

// uncommitted_base_cost gives the pages that the budget of an Uncommitted
// object pays at its creation: its frame list, at least one page.
uncommitted_base_cost :: proc "contextless" (page_count: u64) -> u64 {
	return max(list_pages(page_count), 1)
}

// region_cost gives the pages that a budget pays for a memory object.
region_cost :: proc "contextless" (page_count: u64, contiguous: bool) -> u64 {
	return contiguous ? page_count : op.memory_cost(page_count)
}

// region_create_cost gives the pages that region_create takes from a
// budget for an object of this kind. The error record of a refused
// Memory_Create names this cost, so it names what the kernel charges.
region_create_cost :: proc "contextless" (page_count: u64, contiguous: bool, uncommitted: bool) -> u64 {
	return uncommitted ? uncommitted_base_cost(page_count) : region_cost(page_count, contiguous)
}

// frame_take gives one page frame, not zero, for a page that a budget
// reserved or paid (memory.odin, frame_take_held): it cannot fail. The
// caller holds the frame lock.
@(private = "file")
frame_take :: proc "contextless" () -> u64 {
	return frame_take_held()
}

// region_create makes a memory object. The budget pays for its pages and
// for its frame list. A contiguous object has all its frames now; another
// one has its frames at first use, or now with `now`.
region_create :: proc "contextless" (budget: u32, page_count: u64, contiguous := false, now := false, uncommitted := false, large_pages := false) -> (index: u32, status: Operation_Outcome) {
	if page_count == 0 || !contiguous && page_count > op.MEMORY_PAGE_LIMIT {
		return 0, .Bad_Operation
	}
	// An uncommitted object pays its frame list only, and at least one page:
	// no budget holds a slot of the table of memory objects for nothing.
	cost := region_create_cost(page_count, contiguous, uncommitted)
	// One section of the frame lock: the budget pays, the slot is taken, the
	// frames of a contiguous object or of the frame list are taken, the pages
	// are reserved. The frames are zero filled after the section.
	lock_take(&frame_lock, .Frame)
	if !budgets[budget].live || budgets[budget].amounts.pages < cost {
		lock_free(&frame_lock, .Frame)
		return 0, .No_Budget
	}
	index = region_slot_take()
	if index == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, .No_Slot
	}
	region := &regions[index]
	region^ = {page_count = page_count, budget = budget, contiguous = contiguous, serial = region.serial, uncommitted = uncommitted, large_pages = large_pages}
	if contiguous {
		alignment := large_pages ? u64(op.LARGE_PAGE_PAGES) : 1
		region.physical = frames_take_aligned(page_count, alignment)
		if region.physical == 0 {
			// Frames in the stacks of the processors can make the run.
			caches_drain()
			region.physical = frames_take_aligned(page_count, alignment)
		}
		if region.physical == 0 {
			region^ = {serial = region.serial}
			lock_free(&frame_lock, .Frame)
			return 0, .No_Memory
		}
		region.present = page_count
	} else {
		// The budget has the cost: free frames for the list exist. Each
		// list page is taken in this section, so that the sums of the frames
		// hold whenever the frame lock is free (memory.odin): a second
		// section took the other list pages before, and a report or a drain
		// between the two saw the budget paid for frames not yet taken.
		lists := list_pages(page_count)
		if lists != 0 {
			region.frames[0] = frame_take()
			for list in 1 ..< lists {
				direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1] = frame_take()
			}
		}
		if !uncommitted {
			reserved_pages += page_count
		} else {
			// The page that an Uncommitted object with no list page pays
			// (uncommitted_base_cost) has no frame: it is a reserved page,
			// so the sums of the frames hold.
			reserved_pages += cost - lists
		}
	}
	budgets[budget].amounts.pages -= cost
	lock_free(&frame_lock, .Frame)
	if contiguous {
		frames_zero(region.physical, page_count)
	} else if lists := list_pages(page_count); lists != 0 {
		// The top page holds the frames of the other list pages: they are
		// zero filled first, then the top page keeps their frames.
		for list in 1 ..< lists {
			frames_zero(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
		}
		if lists == 1 {
			frames_zero(region.frames[0], 1)
		} else {
			// The top page: zero after its first lists - 1 entries.
			top := direct(region.frames[0], [LIST_ENTRIES]u64)
			for &entry in top[lists - 1:] {
				entry = 0
			}
		}
	}
	if now {
		for page in 0 ..< page_count {
			region_frame(region, page, true)
		}
	}
	return index, .Ok
}

region_hint: u32 // Where the search of a free slot starts. Frame lock.

// region_slot_take takes a free slot of the table of memory objects, and
// gives it a new serial. The caller holds the frame lock. 0: none.
@(private = "file")
region_slot_take :: proc "contextless" () -> u32 {
	for step in 0 ..< u32(REGION_CAPACITY - 1) {
		index := 1 + (region_hint + step) % (REGION_CAPACITY - 1)
		if regions[index].page_count == 0 {
			region_hint = index
			region_serial += 1
			regions[index].serial = region_serial
			return index
		}
	}
	return 0
}

region_device :: proc "contextless" (physical: u64, page_count: u64) -> u32 {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	index := region_slot_take()
	if index != 0 {
		regions[index] = {physical = physical, page_count = page_count, present = page_count, device = true, contiguous = true, serial = regions[index].serial}
	}
	return index
}

// region_slot gives the place of the frame of one page in the frame list of
// a memory object that is not contiguous.
region_slot :: proc "contextless" (region: ^Region, page: u64) -> ^u64 {
	switch {
	case region.page_count <= REGION_INLINE_PAGES:
		return &region.frames[page]
	case region.page_count <= LIST_ENTRIES:
		return &direct(region.frames[0], [LIST_ENTRIES]u64)[page]
	}
	list := direct(region.frames[0], [LIST_ENTRIES]u64)[page / LIST_ENTRIES]
	return &direct(list, [LIST_ENTRIES]u64)[page % LIST_ENTRIES]
}

// region_frame gives the page frame of one page of a memory object. With
// give, a page with no frame gets one now: a zero page. Without give, 0
// means that the page has no frame yet.
region_frame :: proc "contextless" (region: ^Region, page: u64, give: bool) -> u64 {
	if region.contiguous {
		return region.physical + page * PAGE_SIZE
	}
	slot := region_slot(region, page)
	value := intrinsics.atomic_load(slot)
	frame := value & PAGE_ADDRESS
	if frame != 0 || !give || !page_committed(region, value) {
		return frame // A page that is not committed has no frame, and gets none.
	}
	// The region lock gives the page one frame, when two processors give it
	// at one time. The frame is zero before the slot names it. The state
	// bits of the slot stay.
	index := u32(intrinsics.ptr_sub(region, &regions[0]))
	lock_take(&region_locks[index], .Region)
	value = intrinsics.atomic_load(slot)
	frame = value & PAGE_ADDRESS
	if frame == 0 && page_committed(region, value) {
		frame = frame_reserved_take()
		frames_zero(frame, 1)
		intrinsics.atomic_store(slot, frame | value & SLOT_STATE)
		intrinsics.atomic_add(&region.present, 1)
	}
	lock_free(&region_locks[index], .Region)
	return frame
}

// The lock of each memory object: it gives a page on first use one frame.
region_locks: [REGION_CAPACITY]Lock

region_release :: proc "contextless" (index: u32) {
	region := &regions[index]
	if intrinsics.atomic_sub(&region.references, 1) != 1 {
		return
	}
	// No handle and no mapping names the object: no other processor uses it.
	// The test build checks the committed pages before the frame lock: the
	// walk of each slot of a large object does not hold the lock that each
	// processor needs to take a frame.
	when TEST_BUILD_CHECKS_FRAME_SUMS {
		if region.uncommitted {
			committed_slots: u64
			for page in 0 ..< region.page_count {
				committed_slots += intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
			}
			if committed_slots != region.committed {
				intrinsics.atomic_store(&log_serial_only, true)
				log("kernel: the committed pages of a memory object do not add up: slots ", committed_slots, ", count ", region.committed)
				machine_stop(.Invariant_Broken)
			}
		}
	}
	lock_take(&frame_lock, .Frame)
	switch {
	case region.device:
	case region.contiguous:
		// A device that the object was declared to reaches it no more
		// before its frames are free.
		iommu_region_end_held(index)
		frames_free_held(region.physical, region.page_count)
		budgets[region.budget].amounts.pages += region.page_count
	case:
		// A device that the window of the object was declared to reaches it
		// no more before its frames are free.
		iommu_region_end_held(index)
		// The frames go to the stack of this processor: its next pages on
		// first use take them with no frame lock (memory.odin).
		// The walk ends at the last frame (`present`): an object of 1 GiB
		// with few frames is not walked to its end under the frame lock. The
		// bound that stays: an object whose last page has a frame is one
		// pass over its slots (262 144 for 1 GiB, 2 MiB read in order).
		cache := &processor_self().frame_cache
		lock_take(&cache.lock, .Cache)
		found: u64
		for page := u64(0); page < region.page_count && found < region.present; page += 1 {
			if frame := region_frame(region, page, false); frame != 0 {
				cache_put_held(cache, frame)
				found += 1
			}
		}
		lock_free(&cache.lock, .Cache)
		lists := list_pages(region.page_count)
		for list in 1 ..< lists {
			frames_free_held(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
		}
		if lists != 0 {
			frames_free_held(region.frames[0], 1)
		}
		// The pages that the budget paid: all, or the committed ones; each
		// paid page with no frame is a reserved page.
		paid := region.uncommitted ? region.committed : region.page_count
		reserved_pages -= paid - region.present
		base := region.uncommitted ? uncommitted_base_cost(region.page_count) : list_pages(region.page_count)
		reserved_pages -= base - list_pages(region.page_count) // The page with no frame of a small Uncommitted object.
		budgets[region.budget].amounts.pages += base + paid
	}
	region^ = {serial = region.serial}
	lock_free(&frame_lock, .Frame)
}

// handle_insert puts a handle in a free slot of a process. The caller holds
// the process lock; for a Ports or an Interrupt handle, also the control
// lock. A reference count is atomic: the caller holds a handle or a mapping
// of the object, so the count is not 0. 0: no free slot.
handle_insert :: proc "contextless" (process: ^Process, slot: Handle_Slot) -> op.Handle {
	for &entry, index in process.handles[1:] {
		if entry.kind != .None {
			continue
		}
		generation := entry.generation
		entry = slot
		entry.generation = generation
		switch slot.kind {
		case .Memory:
			intrinsics.atomic_add(&regions[slot.object].references, 1)
		case .Process:
			intrinsics.atomic_add(&processes[slot.object].references, 1)
		case .Thread:
			intrinsics.atomic_add(&threads[slot.object].references, 1)
		case .Budget:
			intrinsics.atomic_add(&budgets[slot.object].references, 1)
		case .Ports:
			intrinsics.atomic_store(&process.has_ports, true)
			ports_changed(process)
		case .Interrupt:
			intrinsics.atomic_store(&interrupt_owner[slot.object], index_of_process(process))
			interrupt_references[slot.object] += 1
			// The entry of a message interrupt behind a conventional bridge
			// follows the process that holds it.
			iommu_interrupt_owner_changed(slot.object)
		case .Machine, .Log:
			// One object of the machine, which never ends: no count.
		case .None:
			// A free slot is not a handle: no caller inserts one.
		}
		process.handles_held += 1
		if process.handles_held > process.handles_peak {
			process.handles_peak = process.handles_held
		}
		return op.Handle(u32(index + 1) | u32(generation) << 16)
	}
	return 0
}

// handle_insert_undo takes back a handle that handle_insert just made and
// that no process saw: the origin tree refused it during a revocation. The
// tree refuses only a path with no control lock, so the handle is never of
// a kind that handle_needs_control names.
handle_insert_undo :: proc "contextless" (process: ^Process, handle: op.Handle, previous_peak: u32) {
	slot := &process.handles[u32(handle) & 0xFFFF]
	was_held := slot.kind != .None
	switch slot.kind {
	case .Memory:
		intrinsics.atomic_sub(&regions[slot.object].references, 1)
	case .Process:
		intrinsics.atomic_sub(&processes[slot.object].references, 1)
	case .Thread:
		intrinsics.atomic_sub(&threads[slot.object].references, 1)
	case .Budget:
		intrinsics.atomic_sub(&budgets[slot.object].references, 1)
	case .Interrupt, .Ports:
		// A give of these holds the control lock, under which the origin
		// tree refuses nothing: an undo here is a fault of the kernel.
		fault_report_begin()
		log("kernel: the origin tree refused a handle of ports or of an interrupt, which a give makes under the control lock: the machine stops")
		machine_stop(.Invariant_Broken)
	case .Machine, .Log:
		// One object of the machine, which never ends: no count.
	case .None:
		// handle_insert never makes a free slot.
	}
	slot^ = {generation = slot.generation}
	if was_held && process.handles_held > 0 {
		process.handles_held -= 1
	}
	process.handles_peak = previous_peak
}

// handle_needs_control says if a handle of this kind changes data of the
// control lock when it is made or closed.
handle_needs_control :: proc "contextless" (kind: Object_Kind) -> bool {
	switch kind {
	case .Memory, .Log, .Machine:
		return false
	case .Process, .Thread, .Budget, .Interrupt, .Ports:
		return true
	case .None:
		// No handle: nothing is made or closed. A caller has found the
		// handle first, so it never asks this.
		return true
	}
	return true
}

// interrupt_handle_released ends what a handle of an interrupt held: its
// count, and the owner of the line when the process was the owner. The
// device of a message interrupt that no handle names sends it no more,
// before the index can be given to another device; the entry of a message
// interrupt behind a conventional bridge follows the process that holds it.
// The caller holds the control lock.
@(private = "file")
interrupt_handle_released :: proc "contextless" (process: ^Process, object: u32) {
	interrupt_references[object] -= 1
	if interrupt_owner[object] == index_of_process(process) {
		intrinsics.atomic_store(&interrupt_owner[object], 0)
	}
	if interrupt_references[object] == 0 && object >= INTERRUPT_LINES {
		iommu_message_end(object - INTERRUPT_LINES)
	}
	iommu_interrupt_owner_changed(object)
}

index_of_process :: #force_inline proc "contextless" (process: ^Process) -> u32 {
	return u32(intrinsics.ptr_sub(process, &processes[0]))
}

// ports_changed makes each processor open the ports of the process again
// before it returns to a process: run checks ports_serial. The caller holds
// the control lock.
ports_changed :: proc "contextless" (process: ^Process) {
	intrinsics.atomic_add(&process.ports_serial, 1)
	processor_sync(all_other_processors())
}

// handle_find gives the slot of a handle of a process. The handle must name
// an object of this kind (.None: any kind) and have each of these rights.
handle_find :: proc "contextless" (process: ^Process, handle: u64, kind: Object_Kind, rights: op.Rights = {}) -> (slot: ^Handle_Slot, status: Operation_Outcome) {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return nil, .Bad_Handle
	}
	slot = &process.handles[index]
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || (kind != .None && slot.kind != kind) {
		return nil, .Bad_Handle
	}
	if !(rights <= slot.rights) {
		return nil, .No_Right
	}
	return slot, .Ok
}

// handle_close closes a handle of a process. The caller holds the process
// lock; for a kind of handle_needs_control, and for a machine handle with
// the right Events, also the control lock.
handle_close :: proc "contextless" (process: ^Process, slot: ^Handle_Slot) {
	was_held := slot.kind != .None
	origin_detach(holding_of_handle(process, slot))
	switch slot.kind {
	case .Memory:
		// A device of this service reaches the object no more once the
		// service holds no handle to it, before the object can end.
		iommu_handle_closed(process, slot)
		region_release(slot.object)
	case .Process:
		// A process runs only while a handle names it: nobody can stop a
		// process that no handle names. The stop waits for control_free.
		// The debugging of a process lives while its debugger holds the
		// right Debug on it (fault_ring.odin): a close and a revocation
		// both come here.
		if .Debug in slot.rights {
			debug_right_closed(process, slot)
			record_right_closed(process, slot)
		}
		if intrinsics.atomic_sub(&processes[slot.object].references, 1) == 1 {
			stops_pending |= 1 << slot.object
		}
	case .Thread:
		thread := &threads[slot.object]
		if intrinsics.atomic_sub(&thread.references, 1) == 1 && thread.finished {
			thread_free(thread)
		}
	case .Budget:
		budget_release(slot.object)
	case .Interrupt:
		interrupt_handle_released(process, slot.object)
	case .Ports:
		slot.kind = .None
		ports_changed(process)
	case .Machine:
		// The event table of the process lives while it has the right
		// Events (events.odin): a close and a revocation both come here.
		if .Events in slot.rights {
			event_right_closed(process, slot)
		}
	case .Log:
		// The log never ends: the handle holds nothing to release.
	case .None:
		// handle_find gives no free slot: nothing to release.
	}
	slot^ = {generation = slot.generation + 1, ended = u8(errors.End.Closed)}
	if was_held && process.handles_held > 0 {
		process.handles_held -= 1
	}
}

// map_region puts pages of a region in the address space of a process. origin is
// the memory handle that a process mapped (origin.odin), or 0.
// by_the_process: the process maps in itself, and not over a module of its
// starter.
map_region :: proc "contextless" (process: ^Process, region_index: u32, address: u64, flags: op.Map_Flags, first: u64, count: u64, origin: Holding = 0, by_the_process := false) -> (result: u64, status: Operation_Outcome) {
	region := &regions[region_index]
	// An object with marks of protection is mapped once: the marks are of
	// the object, and would reach a second mapping.
	if intrinsics.atomic_load(&region.marked_pages) != 0 {
		return 0, .Bad_State
	}
	if record_replay_map_conflict(index_of_process(process), region_index, flags) {
		return 0, .Bad_State
	}
	count := count
	if count == 0 && first < region.page_count {
		count = region.page_count - first
	}
	if count == 0 || first >= region.page_count || count > region.page_count - first {
		return 0, .Bad_Address
	}
	// Guest memory: page 0, and memory that a guest writes and then
	// executes. Only for a process that no thread ran, which Process_Start
	// then refuses (process_holds_guest_memory): a thread there would run
	// with no fault at the address 0, or on pages that switch between Write
	// and Execute with no module named by their content.
	at_zero := .At_Address_Zero in flags
	writable_and_executable := .Write in flags && .Execute in flags
	if writable_and_executable && .No_Access not_in flags {
		return 0, .Bad_Operation // No page is writable and executable: it gets Write or Execute in turn.
	}
	if (at_zero || writable_and_executable) && (by_the_process || process.state != .Created || process.thread_count != 0) {
		return 0, .Bad_State
	}
	if at_zero && address != 0 {
		return 0, .Bad_Address
	}
	address := address
	chosen := address == 0 && !at_zero
	if chosen {
		// An object of large pages, mapped by whole large pages, gets an
		// address on 2 MiB.
		alignment := u64(PAGE_SIZE)
		if region.large_pages && first % op.LARGE_PAGE_PAGES == 0 && count % op.LARGE_PAGE_PAGES == 0 {
			alignment = LARGE_PAGE_SIZE
		}
		address = chosen_address(process, count, alignment)
		if address == 0 {
			return 0, .No_Slot // No gap below MODULE_BASE.
		}
	}
	size := count * PAGE_SIZE
	if address % PAGE_SIZE != 0 || address < PAGE_SIZE && !at_zero || address >= USER_END || size > USER_END - address {
		return 0, .Bad_Address
	}
	// Memory of the process where its starter recorded a module would run
	// under the name of that module. Before the check of the mappings, so
	// that a map over that module always gives the same status.
	if by_the_process && starter_module_meeting(process, address, size) != nil {
		return 0, .No_Right
	}
	// A page on first use has no page table entry yet: the mappings say
	// which addresses are taken.
	mapping: ^Mapping
	for &candidate in process.mappings {
		if candidate.page_count == 0 {
			if mapping == nil {
				mapping = &candidate
			}
		} else if address < candidate.address + candidate.page_count * PAGE_SIZE && candidate.address < address + size {
			return 0, .Bad_Address
		}
	}
	if mapping == nil {
		return 0, .No_Slot
	}
	limit_bits := PAGE_PRESENT | PAGE_USER
	if .Write in flags {
		limit_bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		limit_bits |= PAGE_NO_EXECUTE
	}
	if region.uncached {
		limit_bits |= PAGE_NO_CACHE
	}
	// No_Access: the mapping has its addresses and no access until
	// Memory_Protect gives it some.
	bits := .No_Access in flags ? 0 : limit_bits
	// Large pages: an object made Large_Pages, and a mapping whose address,
	// first page and size are whole large pages.
	large := region.large_pages && address % LARGE_PAGE_SIZE == 0 && first % op.LARGE_PAGE_PAGES == 0 && count % op.LARGE_PAGE_PAGES == 0
	// The origin first: during a revocation, a path with no control lock
	// adds no holding, and runs again under the control lock.
	holding := holding_of_mapping(process, mapping)
	if !origin_attach(holding, origin) {
		return 0, .Needs_Control
	}
	present_page_count: u64
	// The tables that a failed map emptied: freed after its shoot-down.
	freed: Freed_Tables
	if large {
		for part in 0 ..< count / op.LARGE_PAGE_PAGES {
			entry := page_directory_entry_hold(process.table, address + part * LARGE_PAGE_SIZE, &process.budget, &freed)
			if entry == nil {
				// The status before the free: the freed tables return pages
				// to the budget.
				refusal: Operation_Outcome = budgets[process.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
				self := processor_self()
				for undo in 0 ..< part {
					undo_address := address + undo * LARGE_PAGE_SIZE
					undo_entry := page_directory_entry(process.table, undo_address)
					if undo_entry == nil {
						page_table_count_broken("a held entry has no table")
					}
					undo_entry^ = 0
					if intrinsics.atomic_load(&self.table) == process.table {
						page_flush(undo_address)
					}
					page_entries_release(process.table, undo_address, 2, 1, &freed)
				}
				intrinsics.atomic_thread_fence(.Seq_Cst)
				processor_sync(processors_with_table(process.table))
				page_tables_free(process.table, &process.budget, &freed)
				origin_detach(holding)
				return 0, refusal
			}
			frame := region.physical + (first + part * op.LARGE_PAGE_PAGES) * PAGE_SIZE
			entry^ = bits == 0 ? 0 : frame | bits | PAGE_LARGE
			present_page_count += bits == 0 ? 0 : op.LARGE_PAGE_PAGES
		}
	}
	// One table of the last level at a time: one walk of the upper levels
	// and one addition to the count of the table for its run of pages.
	for page := u64(0); page < (large ? 0 : count); {
		run_address := address + page * PAGE_SIZE
		run := min(512 - (run_address >> 12 & 511), count - page)
		run_first_entry := page_entry_hold(process.table, run_address, run, &process.budget, &freed)
		if run_first_entry == nil {
			refusal: Operation_Outcome = budgets[process.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
			// Another thread of the process can have used a page that was
			// present: as in unmap, each processor forgets the entries. The
			// runs of the undo are the runs of the map: the same start.
			self := processor_self()
			for undo := u64(0); undo < page; {
				undo_address := address + undo * PAGE_SIZE
				undo_run := min(512 - (undo_address >> 12 & 511), page - undo)
				undo_first_entry := page_entry(process.table, undo_address)
				if undo_first_entry == nil {
					page_table_count_broken("a held entry has no table")
				}
				undo_entries := ([^]u64)(undo_first_entry)
				for at in 0 ..< undo_run {
					if undo_entries[at] & PAGE_PRESENT != 0 {
						undo_entries[at] = 0
						if intrinsics.atomic_load(&self.table) == process.table {
							page_flush(undo_address + at * PAGE_SIZE)
						}
					}
				}
				page_entries_release(process.table, undo_address, 1, undo_run, &freed)
				undo += undo_run
			}
			intrinsics.atomic_thread_fence(.Seq_Cst)
			processor_sync(processors_with_table(process.table))
			page_tables_free(process.table, &process.budget, &freed)
			origin_detach(holding)
			return 0, refusal
		}
		// The tables exist now and hold the entries while the mapping
		// lives: a page fault never needs a table. A page with no frame
		// keeps an entry of 0 until its first use.
		run_entries := ([^]u64)(run_first_entry)
		for at in 0 ..< run {
			frame := region_frame(region, first + page + at, false)
			page_bits_now := frame == 0 ? 0 : page_bits(&Mapping{bits = bits}, region_page_state(region, first + page + at))
			run_entries[at] = page_bits_now == 0 ? 0 : frame | page_bits_now
			present_page_count += page_bits_now == 0 ? 0 : 1
		}
		page += run
	}
	// Under the process lock of the process: each caller of map_region holds
	// it (Memory_Map through target_lock in enter.odin, process_create and
	// thread_create in this file, the start of the root service in main.odin).
	mapping^ = {address = address, page_count = count, first = first, bits = bits, region = region_index, present_page_count = present_page_count, limit_bits = limit_bits, large = large, receive_handles = .Receive_Handles in flags}
	intrinsics.atomic_add(&region.references, 1)
	if process_records[index_of_process(process)].mode != .None {
		intrinsics.atomic_add(&region.recorded_mappings, 1)
	}
	process.mapped_pages += count
	process.mappings_held += 1
	if process.mappings_held > process.mappings_peak {
		process.mappings_peak = process.mappings_held
	}
	return address, .Ok
}

// chosen_address gives the lowest address from op.CHOSEN_BASE where count
// pages fit with one page with no mapping before and after them: the first
// gap between the mappings of the process. The range of a mapping that
// ended serves again: a process that maps and unmaps at each call uses the
// same few addresses, and its tables are those of one mapping at a time.
// A module record of the writer Starter is a range that the gap avoids too:
// the process cannot map there, and an address that the kernel chooses must
// not give a refusal that the process cannot avoid. Each pass moves the
// candidate past at least one mapping or record, which it never meets
// again: at most MAPPING_CAPACITY + PROCESS_MODULE_CAPACITY passes. The
// caller holds the process lock.
chosen_address :: proc "contextless" (process: ^Process, count: u64, alignment: u64 = PAGE_SIZE) -> u64 {
	align_up :: #force_inline proc "contextless" (value, alignment: u64) -> u64 {
		return (value + alignment - 1) / alignment * alignment
	}
	candidate := align_up(u64(op.CHOSEN_BASE), alignment)
	size := count * PAGE_SIZE
	for _ in 0 ..= MAPPING_CAPACITY + op.PROCESS_MODULE_CAPACITY {
		moved := false
		for mapping in process.mappings {
			if mapping.page_count == 0 {
				continue
			}
			end := mapping.address + mapping.page_count * PAGE_SIZE
			if candidate < end + PAGE_SIZE && mapping.address < candidate + size + PAGE_SIZE {
				candidate = align_up(end + PAGE_SIZE, alignment)
				moved = true
			}
		}
		for item in process.modules {
			if item.size == 0 || item.writer != u64(op.Module_Writer.Starter) {
				continue
			}
			end := item.base + item.size
			if candidate < end + PAGE_SIZE && item.base < candidate + size + PAGE_SIZE {
				candidate = align_up(end + PAGE_SIZE, alignment)
				moved = true
			}
		}
		if !moved {
			break
		}
	}
	// The range of the chosen addresses ends where the modules start.
	if candidate + size > op.MODULE_BASE {
		return 0
	}
	return candidate
}

// unmap removes a mapping. Before the memory object can end, each
// processor that uses the page table of the process forgets the mapping.
// The entries of the mapping stop being held, and each table that holds no
// entry then is freed after that shoot-down. The caller holds the process
// lock.
unmap :: proc "contextless" (process: ^Process, mapping: ^Mapping) {
	origin_detach(holding_of_mapping(process, mapping))
	self := processor_self()
	walked_present_pages: u64
	freed: Freed_Tables
	// A large page is one entry of the second level for 512 pages.
	for part in 0 ..< (mapping.large ? mapping.page_count / op.LARGE_PAGE_PAGES : 0) {
		address := mapping.address + part * LARGE_PAGE_SIZE
		entry := page_directory_entry(process.table, address)
		if entry == nil {
			// The mapping holds its tables: a missing one is a wrong count.
			page_table_count_broken("a held entry has no table")
		}
		walked_present_pages += (entry^ & PAGE_PRESENT) * op.LARGE_PAGE_PAGES
		entry^ = 0
		if self.table == process.table {
			page_flush(address)
		}
		page_entries_release(process.table, address, 2, 1, &freed)
	}
	// One table of the last level at a time (one walk of the upper levels
	// for 512 pages). Each page of the mapping is a held entry, present or
	// not, so each table of the mapping loses its run of held entries with
	// one subtraction. The entries that are not present are already 0, so
	// the read of the entries ends when it has cleared each present entry of
	// the mapping (`present_page_count`): the tables of a mapping of 1 GiB
	// with few pages that have a frame are not read entry by entry. The test
	// build reads each entry, to compare the count with the walk.
	for page := u64(0); page < (mapping.large ? 0 : mapping.page_count); {
		address := mapping.address + page * PAGE_SIZE
		run := min(512 - (address >> 12 & 511), mapping.page_count - page)
		entry := page_entry(process.table, address)
		if entry == nil {
			// The mapping holds its tables: a missing one is a wrong count.
			page_table_count_broken("a held entry has no table")
		}
		read_entries := walked_present_pages != mapping.present_page_count
		when TEST_BUILD_CHECKS_LOCK_ORDER {
			read_entries = true
		}
		entries := ([^]u64)(entry)
		for at in 0 ..< (read_entries ? run : 0) {
			if entries[at] & PAGE_PRESENT != 0 {
				walked_present_pages += 1
				entries[at] = 0
				if self.table == process.table {
					page_flush(address + at * PAGE_SIZE)
				}
			}
		}
		page_entries_release(process.table, address, 1, run, &freed)
		page += run
	}
	// The entries are 0 before the read of the tables of the processors: a
	// processor that loads the table after the read sees the 0 entries.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(process.table))
	// Release any point copies inside the unmapped range after shoot-down.
	record_replay_on_unmap(index_of_process(process), mapping.region, mapping.address, mapping.page_count)
	// No processor walks into a freed table now: the frames can serve again.
	page_tables_free(process.table, &process.budget, &freed)
	// The test build checks the count of the present pages against the
	// walk that this loop made anyway: one comparison, no other walk.
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		if walked_present_pages != mapping.present_page_count {
			present_count_broken(mapping, walked_present_pages)
		}
	}
	// The marks of protection of the pages end with the one mapping that
	// has them: the object can be mapped
	// and given again.
	if region := &regions[mapping.region]; intrinsics.atomic_load(&region.marked_pages) != 0 && !region.contiguous {
		lock := &region_locks[mapping.region]
		lock_take(lock, .Region)
		for page in mapping.first ..< mapping.first + mapping.page_count {
			slot := region_slot(region, page)
			intrinsics.atomic_store(slot, intrinsics.atomic_load(slot) &~ SLOT_MARKS)
		}
		intrinsics.atomic_store(&region.marked_pages, 0)
		lock_free(lock, .Region)
	}
	process.mapped_pages -= mapping.page_count
	if mapping.page_count != 0 && process.mappings_held > 0 {
		process.mappings_held -= 1
	}
	// A mapping of the registers of a device keeps the domain of that device
	// as a handle does: the last one of the two ends it.
	iommu_mapping_ended(process, mapping)
	region_release(mapping.region)
	mapping^ = {} // The count of the present pages ends with the mapping (under the process lock: the caller holds it).
}

// all_other_processors gives the set of the processors but this one.
all_other_processors :: proc "contextless" () -> (set: u64) {
	self := processor_self()
	for cpu in processors[:processor_count] {
		if cpu != self {
			set |= 1 << cpu.index
		}
	}
	return set
}

// processors_with_table gives the other processors that use a page table:
// as their cr3, or as the nested page table of the guest that they run
// (guest.odin).
processors_with_table :: proc "contextless" (table: u64) -> (set: u64) {
	self := processor_self()
	for cpu in processors[:processor_count] {
		if cpu != self && table != 0 && (intrinsics.atomic_load(&cpu.table) == table || intrinsics.atomic_load(&guest_tables_running[cpu.index]) == table) {
			set |= 1 << cpu.index
		}
	}
	return set
}

// mapping_at gives the mapping of a process that holds an address, or nil.
mapping_at :: proc "contextless" (process: ^Process, address: u64) -> ^Mapping {
	for &mapping in process.mappings {
		if mapping.page_count != 0 && address >= mapping.address && address - mapping.address < mapping.page_count * PAGE_SIZE {
			return &mapping
		}
	}
	return nil
}

// page_give makes the page of an address present in a process, for an
// access of the process (a page fault) or of the kernel (user_range). The
// page gets the frame of its memory object; a page on first use gets its
// zero frame now. The caller holds the process lock, so no other processor
// changes the tables or the mappings of the process meanwhile. A processor
// keeps no translation of an entry that was not present, so no other
// processor must forget anything: a thread there that faults on the same
// page waits for the lock, then finds the entry present and continues.
// false: the process has no mapping there, or it does not permit the access.
page_give :: proc "contextless" (process: ^Process, address: u64, write: bool, execute: bool) -> bool {
	mapping := mapping_at(process, address)
	if mapping == nil {
		return false
	}
	// Each page of a large mapping with access is present. A fault there
	// that the entry permits now came through an old translation, before the
	// shoot-down of a protection change: the instruction runs again
	// with no stop of the process.
	if mapping.large {
		entry := page_directory_entry(process.table, address &~ u64(LARGE_PAGE_SIZE - 1))
		return entry != nil && entry^ & PAGE_PRESENT != 0 && (!write || entry^ & PAGE_WRITE != 0) && (!execute || entry^ & PAGE_NO_EXECUTE == 0)
	}
	page := (address - mapping.address) / PAGE_SIZE
	region := &regions[mapping.region]
	state := region_page_state(region, mapping.first + page)
	bits := page_bits(mapping, state)
	// No access, a page that is not committed, or an access that the
	// protection of the page refuses: a fault of the process.
	if bits == 0 || !page_committed(region, state) || write && bits & PAGE_WRITE == 0 || execute && bits & PAGE_NO_EXECUTE != 0 {
		return false
	}
	entry := page_entry(process.table, mapping.address + page * PAGE_SIZE)
	if entry == nil {
		return false // map_region made the tables and the mapping holds them: this does not happen.
	}
	if entry^ & PAGE_PRESENT == 0 {
		frame := region_frame(region, mapping.first + page, true)
		if frame == 0 {
			return false
		}
		entry^ = frame | bits
		mapping.present_page_count += 1 // Under the process lock: the caller holds it (see above).
	}
	return true
}

// stop_cause_missing stops the machine when a path of the kernel stops a
// process with no stop cause, or with a stop outcome that does not fit its
// cause: a fault of the kernel, which no process can cause, since each
// operation names the cause itself and the dispatch refuses the outcome
// word before.
stop_cause_missing :: proc "contextless" (index: u32) -> ! {
	fault_report_begin()
	log("kernel: the kernel stopped the process slot ", u64(index), " with no stop cause, or with a stop outcome that does not fit its cause")
	machine_stop(.Invariant_Broken)
}

// present_count_broken stops the machine of the test when the count of the
// present pages of a mapping is not what its page table holds.
present_count_broken :: proc "contextless" (mapping: ^Mapping, walked: u64) -> ! {
	fault_report_begin()
	log("kernel: the count of the present pages of a mapping is ", mapping.present_page_count, ", its page table holds ", walked)
	machine_stop(.Invariant_Broken)
}

// present_pages gives the pages of the mappings of a process that have a
// page frame.
present_pages :: proc "contextless" (process: ^Process) -> (count: u64) {
	for mapping in process.mappings {
		count += mapping.present_page_count
	}
	return count
}

// maps_region_consent says if a process maps a memory object, and whether at
// least one mapping of it agreed to receive handles (Map_Flag.Receive_Handles).
maps_region_consent :: proc "contextless" (process: ^Process, region: u32) -> (maps: bool, accepts_handles: bool) {
	for mapping in process.mappings {
		if mapping.page_count != 0 && mapping.region == region {
			maps = true
			if mapping.receive_handles {
				return true, true
			}
		}
	}
	return maps, false
}

// time_page_create makes the time page. The kernel keeps one reference:
// the page stays when no process has it.
time_page_create :: proc "contextless" () -> bool {
	physical := frames_allocate(1)
	if physical == 0 {
		return false
	}
	time_region = region_device(physical, 1) // No budget pays for it, and no process frees it.
	if time_region == 0 {
		return false
	}
	regions[time_region].references = 1
	time_record = direct(physical, op.Time_Record)
	direct(physical, [PAGE_SIZE]u8)^ = {}
	time_record.cycle_frequency = cycle_frequency // timer_calibrate measured it.
	cycle_start = cycles_now()
	time_record.cycle_start = cycle_start
	return true
}

// process_create makes a process with no memory. The budget pays for the
// slot and for the page tables. The caller holds the control lock.
process_create :: proc "contextless" (budget: u32, name: []u8) -> (index: u32, status: Operation_Outcome) {
	if !budgets[budget].live || budgets[budget].amounts.processes == 0 || budgets[budget].amounts.pages == 0 {
		return 0, .No_Budget
	}
	for &process, slot in processes[1:] {
		if process.state != .None {
			continue
		}
		index = u32(slot + 1)
		taken := process_lock(index)
		defer process_unlock(index, taken)
		ports_serial := process.ports_serial
		serial := process.serial + 1
		process = {ports_serial = ports_serial, serial = serial, budget = budget}
		process.table = address_space_create(&process.budget)
		if process.table == 0 {
			process = {ports_serial = ports_serial, serial = serial}
			return 0, .No_Budget
		}
		// The own log ring: the budget of the process pays it, as it pays
		// the top table, so a process with many records fills memory that
		// it paid for.
		ring_frames, ring_taken := own_log_ring_take(&process.budget)
		if !ring_taken {
			address_space_free(process.table, &process.budget)
			process = {ports_serial = ports_serial, serial = serial}
			return 0, .No_Budget
		}
		budgets[budget].amounts.processes -= 1
		copy(process.name[:len(process.name) - 1], name)
		// The time page: read only. A process cannot remove it (Memory_Unmap).
		if _, map_status := map_region(&process, time_region, op.TIME_ADDRESS, {}, 0, 1); map_status != .Ok {
			own_log_ring_give_back(ring_frames, &process.budget)
			address_space_free(process.table, &process.budget)
			budgets[budget].amounts.processes += 1
			process = {ports_serial = ports_serial, serial = serial}
			return 0, map_status
		}
		// Under the log lock: Log_Read finds the frames of the ring only
		// with the serial of this process, which the reset above wrote.
		log_taken := log_take()
		process.log_ring_frames = ring_frames
		log_free(log_taken)
		process.state = .Created
		process.start_time = microseconds(cycles_now())
		return index, .Ok
	}
	return 0, .No_Slot
}

// process_free frees the slot of a stopped process that no handle names,
// after its cleanup. Stopped alone does not say that the cleanup ran: a
// thread of it can still run on a processor. The caller holds the control
// lock, and no lock after the process lock.
//
// The own log ring ends here, not at the cleanup: while a handle names the
// process, its holder can read its last records (Log_Read with the slot
// and the serial). Its pages return to the budget with the slot, before
// the slot can serve a new process.
process_free :: proc "contextless" (process: ^Process) {
	if process.state != .Stopped || !process.cleaned {
		return
	}
	own_log_ring_end(process)
	process.state = .None
	// A slot with no process has no stop cause and no stop outcome. Its
	// other facts (the name, the counts) stay until a new process takes the
	// slot: the reports of Inspect give none of them for a free slot.
	process.cause = .None
	process.outcome = .None
	budgets[process.budget].amounts.processes += 1
}

// thread_free frees the slot of a finished thread that no handle names.
// The caller holds the control lock.
thread_free :: proc "contextless" (thread: ^Thread) {
	intrinsics.atomic_store(&thread.state, .None)
	budgets[thread.budget].amounts.threads += 1
}

// process_new_thread_weight_limit gives the new-thread weight limit of a
// process: the stored value, where 0 is the full weight.
process_new_thread_weight_limit :: proc "contextless" (process: ^Process) -> u32 {
	value := intrinsics.atomic_load(&process.new_thread_weight_limit)
	return value == 0 ? u32(op.WEIGHT_FULL) : value
}

// creation_weight_limit gives the weight limit of a thread that the thread
// `creator` creates, or of the first thread of a process that it starts:
// the smaller of its own new-thread weight limit and the one of its
// process (op.new_thread_weight_limit_of_creation). The creation and a
// write of the value of the process both hold the control lock, so each
// creation comes wholly before the write or wholly after it: a thread
// created before it is in each thread report read after it, and a thread
// created after it has the new value (docs/SCHEDULING.md, "A share for
// each process").
creation_weight_limit :: proc "contextless" (creator: u32) -> u32 {
	thread := &threads[creator]
	return op.new_thread_weight_limit_of_creation(intrinsics.atomic_load(&thread.new_thread_weight_limit), process_new_thread_weight_limit(&processes[thread.process]))
}

// thread_create adds a thread to a process. The kernel makes the thread
// area: the thread record and the kernel ring of the thread.
// The budget pays for the slot and for the thread area. The weight and the
// request are checked by the caller, the weight against weight_limit too;
// 0 gives the weight limit and the default request (docs/SCHEDULING.md).
// weight_limit is the limit of a new thread of the thread that creates
// this one (creation_weight_limit), which the new thread gets as its
// weight limit and as its own new-thread weight limit
// (op.thread_schedule_of_new_thread): a process
// does not leave a limit by a new thread, or by the first thread of a
// process that it starts. processors_limit is the limit of the
// placement of that thread, for the same reason: the new thread gets it
// as its set of processors and as its limit; 0 is every processor. The
// caller holds the control lock.
thread_create :: proc "contextless" (process_index: u32, budget: u32, entry, stack, parameter: u64, weight: u64 = 0, request: u64 = 0, weight_limit: u32 = op.WEIGHT_FULL, processors_limit: u64 = 0) -> (index: u32, status: Operation_Outcome) {
	// The first instruction and the stack are in the half of the addresses
	// of a process. The processor refuses to return to an address that is
	// not canonical, and it refuses in the kernel, after the kernel loaded
	// the state of the process: the fault would be a fault of the kernel,
	// and one process would stop the machine.
	if entry >= USER_END || stack > USER_END || stack < 8 {
		return 0, .Bad_Address
	}
	process := &processes[process_index]
	taken := process_lock(process_index)
	defer process_unlock(process_index, taken)
	// A stop marks each thread of the process once: a thread made after it
	// would run in a process that ends.
	if process.state != .Created && process.state != .Ready {
		return 0, .Bad_State
	}
	// Single-thread record/replay mode refuses creating a second thread and
	// requires the pinned processor to intersect the creator's placement limit.
	every_processor := machine_processors()
	placement_limit := processors_limit & every_processor
	if placement_limit == 0 {
		placement_limit = every_processor
	}
	if record_replay_thread_create_refused(process_index, placement_limit) {
		return 0, .Bad_State
	}
	number := u32(op.THREAD_CAPACITY)
	for candidate in 0 ..< u32(op.THREAD_CAPACITY) {
		if process.thread_areas & (1 << candidate) == 0 {
			number = candidate
			break
		}
	}
	for &candidate, slot in threads[1:] {
		if candidate.state == .None && intrinsics.atomic_load(&candidate.references) == 0 {
			index = u32(slot + 1)
			break
		}
	}
	if number == op.THREAD_CAPACITY || index == 0 {
		return 0, .No_Slot
	}
	if !budgets[budget].live || budgets[budget].amounts.threads == 0 {
		return 0, .No_Budget
	}
	// The kernel reads the thread area through the direct map, as one
	// block: it is contiguous.
	region := region_create(budget, 1 + ring.PAGE_COUNT, contiguous = true) or_return
	record := op.THREAD_AREA_BASE + u64(number) * op.THREAD_AREA_PAGES * PAGE_SIZE
	if _, map_status := map_region(process, region, record, {.Write}, 0, 0); map_status != .Ok {
		regions[region].references = 1
		region_release(region)
		return 0, map_status
	}
	direct(regions[region].physical, op.Thread_Record)^ = {
		self      = record,
		parameter = parameter,
		number    = u64(number),
		processors = u32(processor_count),
	}
	thread_ring, _ := ring.open(direct(regions[region].physical + PAGE_SIZE, u8), ring.PAGE_COUNT)
	thread := &threads[index]
	serial := thread.serial + 1
	wait_serial := thread.wait_serial
	home := thread.home
	// Written in place: a composite literal of the whole entry can be built
	// on the kernel stack first, and the entry holds an extended state area
	// of 2688 bytes.
	intrinsics.mem_zero(thread, size_of(Thread))
	thread.state = .Ready
	thread.process = process_index
	thread.budget = budget
	thread.number = number
	thread.ring = thread_ring
	thread.record = record
	thread.events = &direct(regions[region].physical, op.Thread_Record).events
	thread.record_in_kernel = direct(regions[region].physical, op.Thread_Record)
	thread.serial = serial
	thread.wait_serial = wait_serial
	thread.home = home
	// The caller checked the values against the same limit, so ok is true.
	schedule, _ := op.thread_schedule_of_new_thread(weight_limit, weight, request)
	thread.weight_limit = schedule.weight_limit
	thread.new_thread_weight_limit = schedule.new_thread_weight_limit
	thread.weight = schedule.weight
	thread.request = schedule.request
	// The limit of a thread that lives is never empty and holds only
	// processors of the machine; 0 here is the first thread of the root
	// service, or a caller with no limit to give.
	thread.processors = placement_limit
	thread.processors_limit = placement_limit
	thread.placement_restricted = placement_limit != every_processor
	thread.frame = {
		rip    = entry,
		cs     = SELECTOR_USER_CODE,
		rflags = USER_FLAGS,
		rsp    = stack - 8, // As after a call instruction.
		ss     = SELECTOR_USER_DATA,
		rdi    = parameter,
	}
	extended_state_start(&thread.extended_state)
	extended_switch.thread_initialize(&thread.extended_switch)
	budgets[budget].amounts.threads -= 1
	process.thread_areas |= 1 << number
	process.thread_count += 1
	record_replay_thread_init(process_index, thread)
	thread_queue(thread)
	return index, .Ok
}

// thread_stop ends one thread (docs/ARCHITECTURE.md, "The owner of a
// running thread"). A thread on a processor gets stop_requested, and its
// processor ends it (schedule); another thread ends now. The caller holds
// the control lock.
thread_stop :: proc "contextless" (index: u32) {
	thread := &threads[index]
	home := run_lock(thread)
	if thread.state == .None || thread.state == .Stopped {
		run_unlock(home)
		return
	}
	if running := thread.processor; running != 0 {
		intrinsics.atomic_store(&thread.stop_requested, true)
		run_unlock(home)
		if cpu := processors[running - 1]; cpu != processor_self() {
			apic_send(cpu.apic_id, VECTOR_WAKE)
			// The operation returns after the thread left its processor.
			if self := processor_self(); self.operation.running {
				self.operation.stopped_thread, self.operation.stopped_thread_serial = index, thread.serial
			}
		}
		return
	}
	queue_remove(thread)
	thread.state = .Stopped
	intrinsics.atomic_add(&thread.wait_serial, 1)
	run_unlock(home)
	thread_finish(index, thread.serial)
}

// thread_finish frees what an ended thread has: its entries in the wait
// table, its thread area. No processor runs the thread. The other threads
// of the process get an event: one of them can wait for this end. A
// process with no thread stops. The caller holds the control lock.
// `serial` names the thread: if the slot serves another thread now, this
// thread was finished already.
thread_finish :: proc "contextless" (index: u32, serial: u32) {
	thread := &threads[index]
	if thread.finished || thread.serial != serial {
		return
	}
	thread.finished = true
	extended_switch.thread_mark_modified(&thread.extended_switch)
	wait_unregister(thread)
	process_index := thread.process
	process := &processes[process_index]
	// The debug handler of another process ends with its thread: that
	// process gets its threads back before the thread record, which holds
	// the ring, is unmapped below.
	if debugged := intrinsics.atomic_load(&thread.debugs_process); debugged != 0 {
		debug_handler_end(debugged)
	}
	taken := process_lock(process_index)
	record_replay_thread_finished(process_index, index)
	thread.events = nil
	thread.record_in_kernel = nil
	thread.ring = {}
	// The thread record is unmapped below: a fault handler that ends ends
	// the fault ring. A thread that waits for an answer then has no thread
	// that can read its record: the process stops (after the lock).
	handler_ended := process.fault_handler == index
	if handler_ended {
		process.fault_handler = 0
		intrinsics.atomic_store(&process.fault_kinds, 0)
	}
	// Under the process lock: process_event, which holds only this lock,
	// never reads this slot as a thread of the process again, also when a
	// new thread of another process takes the slot.
	thread.process = 0
	running := process.state != .Stopped
	last := false
	if running {
		for &mapping in process.mappings {
			if mapping.page_count != 0 && mapping.address == thread.record {
				unmap(process, &mapping)
				break
			}
		}
		process.thread_areas &~= 1 << thread.number
		process.thread_count -= 1
		last = process.thread_count == 0
	}
	// A thread that waits for the debugger of the process has its record
	// in another ring: the end of this handler does not lose it.
	unanswered := handler_ended && running && fault_waiter_exists(process_index)
	process_unlock(process_index, taken)
	if intrinsics.atomic_load(&thread.references) == 0 {
		thread_free(thread)
	}
	if last {
		process_stop(process_index, .Last_Thread_Ended, .None)
	} else if unanswered {
		process_stop(process_index, .Fault_Unanswered, .None)
	} else if running {
		process_event(process_index)
	}
}

// process_event tells each thread of a process that an event arrived: see
// operation.Word. A thread that waits on its event word wakes. It takes the
// process lock: the thread area of a thread that ends is free only after.
process_event :: proc "contextless" (index: u32) {
	taken := process_lock(index)
	defer process_unlock(index, taken)
	for &thread in threads[1:] {
		if thread.process != index || thread.events == nil {
			continue
		}
		intrinsics.atomic_add(thread.events, 1)
		word_wake(physical_of(thread.events), max(u64))
	}
}

// process_state gives the state of a process for a report: a running
// process is Ready when one of its threads is Ready.
process_state :: proc "contextless" (index: u32) -> op.Process_State {
	process := &processes[index]
	if process.state != .Ready {
		return process.state
	}
	for &thread in threads[1:] {
		if thread.process == index && intrinsics.atomic_load(&thread.state) == .Ready {
			return .Ready
		}
	}
	return .Waiting
}

// process_stop ends a process (docs/ARCHITECTURE.md, "A process ends after
// its last thread leaves its processor"). Each thread that waits or is in a
// queue ends now; each thread on a processor gets stop_requested. The last
// of these processors to leave its thread, or this call if none runs one,
// cleans the process up. The caller holds the control lock. The first stop
// keeps its cause and its outcome: a later stop or fault changes neither.
process_stop :: proc "contextless" (index: u32, cause: op.Stop_Cause, outcome: op.Stop_Outcome, stop_error: errors.Error_Record = {}) {
	// Every path of the kernel names its cause, only a stop of the process
	// itself carries an outcome, and only a Failed or Refused self-stop may
	// carry an error record.
	if cause == .None || (cause == .Itself) != (outcome != .None) || (stop_error != {} && !(cause == .Itself && op.stop_outcome_takes_error(outcome))) {
		stop_cause_missing(index)
	}
	process := &processes[index]
	taken := process_lock(index)
	if process.state == .None || process.state == .Stopped {
		// Another stop marked the threads, and some can still be on their
		// processors: this operation also returns only after they left.
		if self := processor_self(); process.state == .Stopped && self.operation.running {
			self.operation.stopped_processes |= 1 << index
			self.stopped_serials[index] = process.serial
		}
		process_unlock(index, taken)
		return
	}
	intrinsics.atomic_add(&process.holds, 1)
	// The state changes first: a handle that this process closes later can
	// name this process, and an operation of the process sees it.
	process.state = .Stopped
	process.cause = cause
	process.outcome = outcome
	if stop_error != {} {
		process.stop.error = stop_error
	}
	// The debugging of a process ends with the process: its debug handler
	// is free for another process, and no ring takes a record of a process
	// that stops.
	debug_handler_end(index)
	record_replay_end_locked(index, .Normal_Stop)
	process_unlock(index, taken)
	self := processor_self()
	running: u64
	ended: [THREAD_TABLE_CAPACITY]bool
	for &thread, slot in threads[1:] {
		if thread.process != index {
			continue
		}
		home := run_lock(&thread)
		if thread.state != .None && thread.state != .Stopped {
			if thread.processor != 0 {
				intrinsics.atomic_store(&thread.stop_requested, true)
				running |= 1 << (thread.processor - 1)
			} else {
				queue_remove(&thread)
				thread.state = .Stopped
				intrinsics.atomic_add(&thread.wait_serial, 1)
				ended[slot + 1] = true
			}
		}
		run_unlock(home)
	}
	// A guest of this process runs on a processor with no thread of the
	// process: that processor gets the interrupt too, which ends the run at
	// once, and the stop waits for the hold of the run (guest.odin).
	if process.table != 0 {
		for cpu in processors[:processor_count] {
			if intrinsics.atomic_load(&guest_tables_running[cpu.index]) == process.table {
				running |= 1 << cpu.index
			}
		}
	}
	for slot in 1 ..< u32(THREAD_TABLE_CAPACITY) {
		if ended[slot] {
			thread_finish(slot, threads[slot].serial)
		}
	}
	for cpu in processors[:processor_count] {
		if running & (1 << cpu.index) != 0 && cpu != self {
			apic_send(cpu.apic_id, VECTOR_WAKE)
		}
	}
	// The operation returns after the threads left their processors.
	if running &~ (1 << self.index) != 0 && self.operation.running {
		self.operation.stopped_processes |= 1 << index
		self.stopped_serials[index] = process.serial
	}
	if intrinsics.atomic_add(&process.holds, HOLDS_STOPPED - 1) + HOLDS_STOPPED - 1 == HOLDS_STOPPED {
		process_cleanup(index)
	}
}

// process_cleanup frees all that a stopped process has. No processor runs
// a thread of it. The caller holds the control lock.
process_cleanup :: proc "contextless" (index: u32) {
	process := &processes[index]
	// The event table belongs to the process that gave it: it ends with it,
	// before its handles close (events.odin). No process lock is held here.
	event_table_end_for(index)
	record_replay_recorder_stopped(index, process.serial)
	// No thread of this process is on a processor now: a recorded thread
	// no longer waits for it as a shared writer.
	record_replay_writer_stopped(index)
	for &thread, slot in threads[1:] {
		if thread.process == index && thread.state == .Stopped && !thread.finished {
			thread_finish(u32(slot + 1), thread.serial)
		}
	}
	// The lines that its log limit refused and that no later line of the
	// process said: no thread of it runs a Log now. The control lock comes
	// before the log lock.
	if refused := process.log_lines_refused; refused != 0 {
		process.log_lines_refused = 0
		log("kernel: ", Module_Name{process_name(process)}, ": ", refused, " lines were refused by its log limit, the last ones before its stop")
	}
	taken := process_lock(index)
	process.thread_count = 0
	process.thread_areas = 0
	// No processor keeps the page table of the process.
	self := processor_self()
	if intrinsics.atomic_load(&self.table) == process.table {
		intrinsics.atomic_store(&self.table, kernel_table)
		control_register_3_write(kernel_table)
	}
	processor_sync(processors_with_table(process.table))
	// The devices of a device service reach no page from now: before its
	// handles close, which can free the pages.
	iommu_process_end(index)
	for &mapping in process.mappings {
		if mapping.page_count != 0 {
			unmap(process, &mapping)
		}
	}
	for &slot in process.handles {
		if slot.kind != .None {
			handle_close(process, &slot)
		}
	}
	// The control block and the extended state of a guest: no run holds
	// the process now.
	guest_end(index)
	address_space_free(process.table, &process.budget)
	process.table = 0
	// The own log ring stays until the slot is free (process_free): a
	// holder of the process handle, such as the starter, still reads the
	// last records of a process that stopped.
	process.cleaned = true
	process_unlock(index, taken)
	for &other, other_index in processes[1:] {
		other_slot := u32(other_index + 1)
		other_taken := process_lock(other_slot)
		holds := false
		if other.state != .None && other.state != .Stopped {
			for slot in other.handles {
				if slot.kind == .Process && slot.object == index {
					holds = true
					break
				}
			}
		}
		process_unlock(other_slot, other_taken)
		if holds {
			process_event(other_slot)
		}
	}
	if intrinsics.atomic_load(&process.references) == 0 {
		process_free(process)
	}
}

// ports_switch opens on a processor the ports of process index (0: none),
// when the process or its ports changed (ports_serial). A processor writes
// only its own port bitmap.
ports_switch :: proc "contextless" (cpu: ^Processor, index: u32) {
	serial := intrinsics.atomic_load(&processes[index].ports_serial)
	if cpu.ports_loaded == index && (index == 0 || cpu.ports_serial == serial) {
		return
	}
	if cpu.ports_loaded != 0 {
		for &b in cpu.task_state.ports {
			b = 0xFF
		}
	}
	if index != 0 {
		for &slot in processes[index].handles {
			if intrinsics.atomic_load(&slot.kind) == .Ports {
				ports_allow(cpu, u64(slot.object), u64(slot.count), true)
			}
		}
	}
	cpu.ports_loaded = index
	cpu.ports_serial = serial
}

EXCEPTION_NAMES := [32]string {
	0  = "division by zero",
	1  = "debug",
	2  = "non-maskable interrupt",
	3  = "breakpoint",
	4  = "overflow",
	5  = "bound range",
	6  = "invalid instruction",
	7  = "device not available",
	8  = "double fault",
	10 = "invalid task state",
	11 = "segment not present",
	12 = "stack fault",
	13 = "protection fault",
	14 = "page fault",
	16 = "x87 floating point",
	17 = "alignment check",
	18 = "machine check",
	19 = "SIMD floating point",
	21 = "control protection",
}

// kernel_interrupt is where every interrupt, exception and kernel entry
// arrives. It takes no lock of its own: each path takes the locks of the
// data that it touches (docs/ARCHITECTURE.md, "Locks of the kernel").
@(require, linkage = "strong", link_name = "kernel_interrupt")
kernel_interrupt :: proc "c" (frame: ^Frame) {
	from_process := frame.cs & 3 != 0
	// The address of a page fault, read once and first: every later use
	// takes this value, also if a later path can take another page fault.
	fault_address: u64
	if frame.vector == VECTOR_PAGE_FAULT {
		fault_address = control_register_2_read()
	}
	// A fault of the iretq of resume: the processor refused the return to
	// the current thread. interrupt_common gave the kernel its gs back for
	// each interrupt between the swapgs of resume and its iretq.
	if !from_process && frame.rip == u64(uintptr(&resume_return)) && frame.vector >= 11 && frame.vector <= 13 {
		return_refused_by_the_processor(frame)
	}
	// A protection fault of the one instruction of a register trial: the
	// processor refused the register, and the trial goes on at its refusal
	// label, which gives false (register_trial.odin). It returns through the
	// iretq of interrupt_common, on the stack of the trial.
	if !from_process && frame.vector == VECTOR_PROTECTION_FAULT {
		if refusal := register_trial_refusal_address(frame.rip); refusal != 0 {
			frame.rip = refusal
			return
		}
	}
	// A non-maskable interrupt, a double fault and a machine check are not
	// faults of an instruction of the process that ran: a double fault is a
	// mistake of the kernel, a machine check an error of the machine, and
	// the kernel sends no non-maskable interrupt, so one reports the machine
	// (a hardware error, or a request through the hypervisor). To stop only
	// that process would hide the fault and go on with a machine that is
	// not sound: the machine stops with a line, as in the kernel below.
	if from_process && (frame.vector == VECTOR_NON_MASKABLE_INTERRUPT || frame.vector == VECTOR_DOUBLE_FAULT || frame.vector == VECTOR_MACHINE_CHECK) {
		fault_report_begin()
		log("kernel: ", EXCEPTION_NAMES[frame.vector], " vector ", frame.vector, " while a process ran, at ", Hex(frame.rip), ": a fault of the machine, not of the process: the machine stops")
		machine_stop(.Fault)
	}
	if !from_process && frame.vector < VECTOR_INTERRUPT_BASE {
		// The processor can hold any lock: it takes none.
		name := EXCEPTION_NAMES[frame.vector]
		address := fault_address
		if frame.vector != VECTOR_PAGE_FAULT {
			address = control_register_2_read()
		}
		fault_report_begin()
		log("kernel: exception in the kernel: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(address), ": ", fault_reason(frame, address))
		machine_stop(.Fault)
	}
	cpu := processor_self()
	sync_acknowledge(cpu)
	if !from_process {
		// An interrupt in the idle loop: the drain of the serial port there
		// leaves after it, as idle_wait returns after one interrupt, so the
		// processor looks at the queues again (serial_drain_while_idle).
		intrinsics.atomic_add(&cpu.idle_interrupts, 1)
	}
	// The thread of a process entry is the current thread of this
	// processor: no other processor takes it away.
	thread: ^Thread
	if from_process {
		thread = &threads[cpu.current]
		thread.frame = frame^
		// The status of a debug exception is in a register of the
		// processor, which keeps it until the kernel clears it: it is read
		// once, here, into the frame of the thread, where the delivery of
		// the fault reads it (breakpoints.odin).
		if frame.vector == VECTOR_DEBUG {
			thread.frame.error = debug_status_take()
		}
	}
	when KERNEL_EDGE_COUNTERS {
		// The counted kernel counts the code that a counted process asked
		// for: its commands and its exceptions, and not a tick, a device
		// or the scheduler (edge_counters.odin).
		edge_counting_set(from_process && edge_counted_processes[thread.process] && (frame.vector == VECTOR_KERNEL_ENTER || frame.vector < VECTOR_INTERRUPT_BASE || frame.vector == VECTOR_DEBUG_FRAME_LOST))
	}
	switch {
	case frame.vector == VECTOR_DEBUG_FRAME_LOST:
		// The process ran int1 with a held debug trap, and the second trap
		// took the place of the frame of the first on their one stack: the
		// kernel does not know where the thread was, so it cannot return to
		// it, and no fault handler could resume it. The process stops as a
		// fault of a debug exception, with the instruction address 0;
		// its general registers are its own, so the stack trace starts from
		// its frame pointer.
		frame.vector = VECTOR_DEBUG
		process_fault(thread.process, frame, 0)
		if event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.process) {
			event_record(cpu, .Fault, thread.process, thread.number, frame.vector, 0, u64(op.Event_Fault_Outcome.Stopped))
		}
	case frame.vector == VECTOR_KERNEL_ENTER:
		cpu.entries += 1
		enter(cpu, cpu.current)
	case frame.vector == VECTOR_TIMER:
		if from_process {
			cpu.busy_time += 1
			thread.run_time += 1
			intrinsics.atomic_add(&processes[thread.process].run_time, 1)
			stint_ended := strategy_tick(cpu, thread, budget_charge(cpu))
			if stint_ended {
				cpu.slice_left = 0 // The strategy ends the stint.
			}
			if budget_spent(intrinsics.atomic_load(&thread.budget)) {
				cpu.slice_left = 0 // The budget has no time left in this period.
			}
			if intrinsics.atomic_load(&thread.record_mode) == .Recording && stint_ended {
				record_replay_stint_bound_check(thread)
			}
		}
		// The first processor counts the time.
		if cpu.index == 0 {
			now := max(time_milliseconds, milliseconds_now())
			intrinsics.atomic_store(&time_milliseconds, now)
			intrinsics.volatile_store(&time_record.milliseconds, now)
			budget_period(now)
			// The fault records that the last fault event of the IOMMU left.
			iommu_tick()
			// The deadlines: read with no lock, then checked under the run
			// lock by thread_wake.
			for &waiting in threads[1:] {
				if intrinsics.atomic_load(&waiting.state) == .Waiting && intrinsics.atomic_load(&waiting.deadline) <= now {
					thread_wake(&waiting, now)
				}
			}
			// The bound of a shared writer that waits for a recorded
			// thread: one word read when no record has a shared writer.
			if intrinsics.atomic_load(&shared_writer_recordings) != 0 {
				shared_writer_wait_bound_check(now)
			}
		}
		// The lines of the log go to the serial port here, not in Log. Each
		// processor tries, so a hang of one does not silence the others.
		// The thread that this tick interrupts was charged above: the time
		// of the drain moves the start of its next charge, so no budget pays
		// for the lines of others.
		drain_start := cycles_now()
		serial_tick(cpu)
		cpu.charged_from += cycles_now() - drain_start
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_WAKE || frame.vector == VECTOR_SYNC:
		// A thread that woke on another processor preempts the thread
		// that runs here (kick). Interrupts are off in the kernel, so this
		// interrupt arrives either when the processor returns to a process
		// (from_process) or while it waits idle with no thread: then no
		// stint is to end, and the processor picks a thread anyway. A flag
		// for a thread that left its processor before the interrupt ends
		// the stint of the next thread (one more pass through schedule).
		if intrinsics.atomic_exchange(&cpu.preempt, false) && from_process {
			cpu.slice_left = 0
			cpu.preemptions += 1
			cpu.preempt_from = cycles_now()
		}
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_SPURIOUS:
	case frame.vector == VECTOR_IOMMU_FAULT:
		// A device reached memory that its service did not declare: a line
		// of the log, and the process that runs goes on.
		cpu.interrupts += 1
		iommu_faults_take()
		apic_write(APIC_END, 0)
	case frame.vector >= VECTOR_INTERRUPT_BASE && frame.vector < VECTOR_INTERRUPT_BASE + INTERRUPT_LINES:
		line := frame.vector - VECTOR_INTERRUPT_BASE
		cpu.interrupts += 1
		interrupt_signal(line)
		interrupt_end(line)
	case frame.vector >= VECTOR_MESSAGE_BASE && frame.vector < VECTOR_MESSAGE_BASE + op.MESSAGE_CAPACITY:
		cpu.interrupts += 1
		interrupt_signal(INTERRUPT_LINES + frame.vector - VECTOR_MESSAGE_BASE)
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_PAGE_FAULT && frame.error & FAULT_RESERVED_BIT != 0:
		// The processor found a reserved bit in an entry of a page table.
		// Only the kernel writes those entries: it is a mistake of the
		// kernel, not of the process. The machine stops, as at an exception
		// in the kernel; a fault handler never sees it, so a repair cannot
		// hide it in a loop of faults.
		fault_report_begin()
		log("kernel: a page table entry of process ", Module_Name{process_name(&processes[thread.process])}, " has a reserved bit: page fault error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(fault_address))
		machine_stop(.Fault)
	case frame.vector == VECTOR_PAGE_FAULT && frame.error & FAULT_PRESENT == 0 && page_fault(thread.process, fault_address, frame.error):
		// A page on first use, or a page that another thread made present
		// while this one waited for the lock: the instruction runs again.
		cpu.first_use_faults += 1
		// The event points of a fault (events.odin) come after the work, so
		// that the record says what the kernel did. The thread keeps its
		// process and its number until its processor leaves it.
		if event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.process) {
			event_record(cpu, .Fault, thread.process, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.First_Use))
		}
	case from_process && frame.vector == VECTOR_PROTECTION_FAULT && (intrinsics.atomic_load(&thread.record_mode) != .None || cpu.record_traps_loaded) && record_replay_handle_gp(cpu, thread):
		// Emulated rdtsc, rdtscp, or cpuid for a recorded or replayed thread
		// (or stale trap unload after recording ended); never delivered to a
		// user fault handler.
	case:
		delivery := Fault_Delivery.Stops_The_Process
		if from_process && frame.vector < VECTOR_INTERRUPT_BASE {
			delivery = fault_deliver(cpu.current, fault_address)
		}
		switch delivery {
		case .Waits_For_An_Answer:
			// A record of a fault ring: the thread is Waiting until a
			// thread of its process, or its debugger, answers, so the end
			// below goes to schedule. The address is 0 for a fault that is
			// not a page fault.
			if event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.process) {
				event_record(cpu, .Fault, thread.process, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.Fault_Ring))
			}
		case .Continues:
			// A debug exception of a breakpoint or of a single step that
			// its debugger no longer waits for: the thread goes on below,
			// and it is no fault of the process.
		case .Stops_The_Process:
			process_fault(thread.process, frame, fault_address)
			if from_process && frame.vector < VECTOR_INTERRUPT_BASE && event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.process) {
				event_record(cpu, .Fault, thread.process, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.Stopped))
			}
		}
	}
	when KERNEL_EDGE_COUNTERS {
		// Before the return, the wait and the scheduler, which run the
		// code of other threads.
		edge_counting_set(false)
	}
	if !from_process {
		return // The processor was idle: it looks for a thread itself.
	}
	// The thread that entered continues, unless it waits, it ends, a stop
	// of Thread_Control holds it, or its time slice is over.
	if !intrinsics.atomic_load(&thread.stop_requested) && intrinsics.atomic_load(&thread.state) == .Ready && intrinsics.atomic_load(&thread.control_stops) == 0 && cpu.slice_left > 0 {
		run(cpu, thread)
	}
	schedule()
}

// interrupt_signal counts an interrupt and tells its owner. The owner is
// read with no lock: when the handle closes at the same time, the event
// can go to the process that held it.
interrupt_signal :: proc "contextless" (index: u64) {
	intrinsics.atomic_add(&interrupt_pending[index], 1)
	if owner := intrinsics.atomic_load(&interrupt_owner[index]); owner != 0 {
		process_event(owner)
	}
}

// page_fault gives a page on first use to a process, under its process
// lock. false: the process has no mapping there, or no right for the access.
page_fault :: proc "contextless" (index: u32, address: u64, error: u64) -> bool {
	taken := process_lock(index)
	defer process_unlock(index, taken)
	return page_give(&processes[index], address, error & FAULT_WRITE != 0, error & FAULT_EXECUTE != 0)
}

// process_fault stops the process of a thread that faulted. A fault in one
// thread stops the process: the threads share all their memory.
process_fault :: proc "contextless" (index: u32, frame: ^Frame, address: u64) {
	control_take()
	defer control_free()
	process_stop(index, process_fault_report(index, frame, address), .None)
}

// process_fault_report writes the stop report and the line of the log of a
// fault of a thread of a process, and gives the stop cause. address is the
// address of a page fault (the processor gives it in cr2). The caller holds
// the control lock, and the page table of this processor is the one of the
// process: the stack trace reads its memory. Then the caller stops the
// process with the cause.
process_fault_report :: proc "contextless" (index: u32, frame: ^Frame, address: u64) -> (cause: op.Stop_Cause) {
	process := &processes[index]
	taken := process_lock(index)
	name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
	// The module of the instruction, as the loader recorded it: a
	// replacement names the module that runs, not the one of the import.
	found := module_of(process, frame.rip)
	// The first stop is the one that the report keeps: a process that a stop
	// or another fault already stopped keeps its cause and its report.
	first := process.state != .Stopped && process.state != .None
	// A page of an Uncommitted object that is not committed has its own
	// cause: the access went to addresses with no memory paid behind them.
	cause = .Fault
	if frame.vector == VECTOR_PAGE_FAULT && process.table != 0 {
		if mapping := mapping_at(process, address); mapping != nil && mapping.region < REGION_CAPACITY {
			region := &regions[mapping.region]
			page := mapping.first + (address - mapping.address) / PAGE_SIZE
			if region.uncommitted && !page_committed(region, region_page_state(region, page)) {
				cause = .Not_Committed
				name = "page fault on a page that is not committed"
			}
		}
	}
	if first {
		process.stop = {cause = u32(cause), vector = u32(frame.vector), instruction = frame.rip}
		if frame.vector == 14 {
			process.stop.address = address
		}
		if found != nil {
			process.stop.module = found^
		}
	}
	if found == nil {
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(process)}, " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(address))
	} else if found.replaces == {} {
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(process)}, " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(address), ", in module ", Hash{found.hash[:8]}, " at offset ", Hex(frame.rip - found.base))
	} else {
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(process)}, " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(address), ", in module ", Hash{found.hash[:8]}, " at offset ", Hex(frame.rip - found.base), ", which replaces ", Hash{found.replaces[:8]})
	}
	// The stack trace: the page table of the process is the one of this
	// processor, and the process lock is held (user_range, user_copy).
	if first {
		stack_trace(process, frame, &process.stop)
	}
	process_unlock(index, taken)
	return cause
}

process_name :: proc "contextless" (process: ^Process) -> string {
	count := 0
	for count < len(process.name) && process.name[count] != 0 {
		count += 1
	}
	return string(process.name[:count])
}
