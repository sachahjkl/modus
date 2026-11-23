// The kernel operations: what a process can ask the kernel. The list is
// short and counted, and only a change of docs/PROPERTIES.md changes its
// limit (docs/PROPERTIES.md, "Small kernel with a small, counted interface").
//
// Each thread of a process has one ring to the kernel: the kernel ring. It
// is one page after the thread record of the thread, and the `gs` register
// of the thread holds the address of the thread record. A kernel
// operation is a command record in that ring: kind is an Operation, values
// are its parameters. The completion record has a Status in kind, and the
// results in values.
//
// The kernel has one entry point, the `syscall` instruction ("enter"):
//   rdi   0: execute the commands of the kernel ring, then return.
//         n: the same, then wait until a wake or until time n (milliseconds
//            since boot). WAIT_FOREVER waits with no time limit.
//   rax   on return: the time, in milliseconds since boot.
//
// This package is the contract between the kernel and every process. The
// kernel imports it to read the commands and write the completions;
// `src/library/modus/system` imports it to give each operation a procedure; the
// developer tools import its report records to read what the kernel shows.
// A record of this package that crosses the kernel ring has the same bytes on
// both sides, so its size is fixed and checked with `#assert`.
//
// The main parts:
//
// - `Operation`: the kernel operations, each with its arguments, results and
//   statuses.
// - `Status`: the result kind of each completion record.
// - `Handle`, `Right`, `Rights`, `Object_Kind`: how a process names an object
//   and what it can do with it.
// - `Time_Record`, `Thread_Record`, `Context`: the three records that the
//   kernel or the starter puts at fixed addresses of each process.
// - `Budget_Amounts`: what a budget holds and limits.
// - `Fault_Record`, `Fault_Kind`, `Thread_Registers`: the fault ring and the
//   control of a thread.
// - `Event_Rule`, `Event_Record`, `Event_Ring`: the kernel events.
// - `Guest_Registers`, `Guest_Exit_Kind`: a guest (`Guest_Run`).
// - `Log_Head`, `Log_Record`, `Log_Level`: the log of the kernel.
// - The reports of `Inspect`: `System_Report`, `Process_Report`,
//   `Processor_Report`, `Boot_Report`, `Mapping_Report`, `Module_Report`,
//   `Process_Mapping_Report`, `Thread_Table_Report`, `Stop_Report`,
//   `Page_Report`.
// - The fixed addresses of a process (`PROCESS_BASE` to `USER_END`) and the
//   roles of the context (`CONTEXT_LOG`, `CONTEXT_BUDGET`, the `CONTEXT_VALUE_`
//   constants, the `ROOT_` constants).
//
// The design is in (docs/ARCHITECTURE.md, "Kernel systems") and in
// (docs/ARCHITECTURE.md, "The virtual memory of a process").
package operation

import info "modus:contract/boot_info"
import "modus:contract/errors"
import "modus:contract/value_kinds"

// The bytes of one page: the unit of each mapping, of each memory object and
// of each budget of pages. It is the small page of the x86-64 processor.
PAGE_SIZE :: 4096
// The deadline of a wait with no time limit: the largest time, which the
// clock of the kernel never reaches. Give it as `rdi` to the `syscall` entry,
// or as the deadline of `Word_Wait`.
WAIT_FOREVER :: max(u64)

// The addresses of a process that the system fixes. Each process has the same
// layout, so that a loader, a debugger and a stop report read an address with
// no table:
//
// - from `PROCESS_BASE`: the module of the process;
// - from `CHOSEN_BASE`: the mappings whose address the kernel chooses;
// - from `MODULE_BASE`: the modules that the process loads;
// - below `STACK_TOP`: the stack of the first thread;
// - at `CONTEXT_ADDRESS`: the context;
// - from `THREAD_AREA_BASE`: the thread areas;
// - at `TIME_ADDRESS`: the time page;
// - at `USER_END`: the end of the half of the addresses that a process owns.
PROCESS_BASE :: 0x0000_0000_0040_0000 // The module of the process: the starter maps its first byte here, at 4 MiB.
CHOSEN_BASE :: 0x0000_1000_0000_0000 // Where the kernel puts a mapping with no given address: `Memory_Map` with the address 0 takes the lowest free place from here, and below `MODULE_BASE`.
// Where a process loads, while it runs, the modules that it calls: the
// console and the process `errors` start their `system.Module_Space` here.
// The places end at `fixed_addresses.MODULES_END`. The modules that the
// starter loads with the process follow it from `PROCESS_BASE`.
MODULE_BASE :: 0x0000_2000_0000_0000
// The first address above the stack of the first thread. The stack grows
// down from here: its `STACK_PAGES` pages end at this address. The starter
// maps it, and gives it to `Process_Start` as the stack address.
STACK_TOP :: 0x0000_7FFF_FFE0_0000
// The pages of the stack of the first thread: 64 pages, 256 KiB. A thread
// that `system.thread_start` makes has its own count (`THREAD_STACK_PAGES`).
STACK_PAGES :: 64
// The pages of the stack of a thread that `system.thread_start` makes when
// its caller gives no other count. It is here, beside STACK_PAGES, because
// the tool counts both in the budget that a module asks for
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
THREAD_STACK_PAGES :: 16
// The address of the context of the process (`Context`): the starter maps one
// page there and gives this address as the parameter of the entry.
CONTEXT_ADDRESS :: 0x0000_7FFF_FFF0_0000
// The thread areas: one per thread, THREAD_AREA_PAGES pages each. An area
// is the thread record (one page), the kernel ring, and one page with no
// memory.
//
// The thread number n has its area at `THREAD_AREA_BASE + n *
// THREAD_AREA_PAGES * PAGE_SIZE`. The page with no memory is a guard page: a
// write past the kernel ring faults and touches no other thread.
THREAD_AREA_BASE :: 0x0000_7FFF_FFF4_0000
THREAD_AREA_PAGES :: 4 // One page of thread record, the two pages of the kernel ring (`ring.PAGE_COUNT`), one guard page.
// The threads of one process, at the same time. `Thread_Create` gives
// `No_Slot` when all the thread numbers are in use. The 32 thread areas end
// below `TIME_ADDRESS`.
THREAD_CAPACITY :: 32
// The time page: one page that the kernel writes and that each process can
// only read. A process reads the time with no kernel entry.
TIME_ADDRESS :: 0x0000_7FFF_FFFE_0000
// The first address that a process does not own: the end of the lower half
// of the addresses of the processor. The kernel refuses a mapping that ends
// above it, and a thread instruction address at or above it.
USER_END :: 0x0000_8000_0000_0000

// The record at TIME_ADDRESS. A process reads `milliseconds` with one load
// of 64 bits: the value is always complete.
//
// The kernel is the one writer; a process maps the page read only. The
// clock that it gives is the clock of the machine since boot: it is not a
// date (the date page gives the date). `system.time` reads `milliseconds`.
//
// Example: a process that reads `milliseconds = 5230` 5.23 seconds after the
// kernel made the page; with `cycle_frequency = 2_000_000_000`, a cycle count
// of `cycle_start + 3_000_000` is 1.5 ms after the time 0.
Time_Record :: struct {
	// Since the kernel made the time page. It never goes back. The kernel
	// writes it at each tick of its timer, from the cycle counter: a tick
	// that comes late loses no time, and the value is at most one tick old.
	milliseconds: u64,
	// Cycles of the cycle counter in one second. It does not change after
	// boot.
	cycle_frequency: u64,
	// The cycle counter at the time 0. It does not change after boot. A
	// process that needs a time finer than one millisecond reads the cycle
	// counter, subtracts this, and divides by the frequency.
	cycle_start: u64,
}

// A handle: the number by which one process names one kernel object, with
// the rights that it holds on it. 0 names no object.
//
// A handle names a slot of the handle table of its process: the same number
// in another process names another object, or none. Its low 16 bits are the
// index of the slot, and the next 16 bits a generation that changes at each
// close of the slot: an old number of a closed handle names no new object,
// and gives `Bad_Handle`. A process gets a handle
// from an operation that makes an object (`Memory_Create`), from its
// starter in its `Context`, or from another process with `Handle_Give`. The
// kernel checks each handle argument: a handle that names no object of the
// kind that an operation needs gives `Bad_Handle`; a handle with too few
// rights gives `No_Right`. `Handle_Close` ends a handle; an object ends when
// no handle and no mapping names it. See [handle](term:handle) and
// (docs/ARCHITECTURE.md, "K1. Handle table").
//
// Example: the log handle of a process is `context.handles[CONTEXT_LOG]`.
Handle :: distinct u32

// A right: one kind of operation that a handle permits on its object. The
// handle of a new object has each right of its kind. Handle_Give copies a
// handle with a part of its rights. No operation adds a right to a handle.
//
// One name serves several kinds of objects: the comment of each member says
// what it permits on each kind. A right that has no meaning for the kind of
// the object permits nothing. `Handle_State` gives the rights of a handle. In
// the comment of each operation the rights that it needs are in **bold**.
// See [right](term:right).
//
// Example: a starter gives a process read-only memory with
// `Handle_Give` and the rights `{.Read}`: the process maps it with no
// `Write` and gives no copy of it, because it has no **Give**.
Right :: enum u32 {
	Give    = 0, // Each kind: give a copy of the handle to another process.
	Read    = 1, // Memory: map it; the memory of the log: also copy the own log ring of a process (Log_Read). Process, Thread: read its state. Interrupt: read its count. Budget: read what it holds (Budget_Read).
	// Memory: map it with Write. Log: write text on the log. Thread: write its registers and its extended state
	// while it is held (Thread_Control): full control of the code that its process runs.
	Write   = 2,
	Execute = 3, // Memory: map it with Execute.
	// Process: map memory in it, give handles to it, start it, stop it. Thread: end it, make it the fault handler,
	// write its weight and its request (Thread_Control).
	Control = 4,
	// Machine: read the reports. Thread: hold it and release it, and read its registers, its extended state and its
	// schedule (Thread_Control): what a sampling profiler needs, and no write.
	Inspect = 5,
	Devices = 6, // Machine: create device handles.
	Stop    = 7, // Machine: stop the machine.
	Spend   = 8, // Budget: create objects with it, and take a part of it for a new budget.
	Physical = 9, // Machine: read the physical address of a memory object (Memory_Physical).
	// Machine: change the scheduling strategy of the machine (Strategy_Set), and the weight, the request, the
	// two weight limits and the placement of any thread (Thread_Control).
	Schedule = 10,
	// Budget: pay pages of a memory object that this budget already pays for (Memory_Commit), and nothing else: no
	// object, thread, process or budget is created with it. The narrow form of Spend, to give to another process.
	Commit = 11,
	// Machine: give the event table of the machine (Events_Set): the kernel then writes records of its own work,
	// for every process or for the processes that the rules name, into memory of the caller.
	Events = 12,
	// Process: debug it. The holder becomes the debugger of the process (Fault_Handler_Set with the process
	// handle): it receives its debug exceptions and its breakpoints, holds its threads by their numbers, reads
	// and writes their registers and their breakpoints, and reads the memory of the process (Thread_Control).
	// The handle of a new process has it; the root service gives it to no process at its start.
	Debug = 13,
	// Machine: count the events of the processor for the code of the calling thread (Thread_Control, the
	// commands of the thread counters). A count of the misses of a shared cache measures what other processes do,
	// so it is a grant, as a precise clock is (src/md/features/processor_counters.md).
	Counters = 14,
}
// The rights of one handle, as a set: bit n is the `Right` n. It is the
// form in which an operation takes and gives rights (`Handle_Give`,
// `Handle_State`).
Rights :: bit_set[Right;u32]

// The kind of the object that a handle names. `Handle_State` gives it; the
// kernel checks it at each handle argument.
Object_Kind :: enum u8 {
	None      = 0, // No object: the handle number is free, or was never given.
	Memory    = 1, // A memory object: pages that a process maps (`Memory_Create`). Rights: Give, Read, Write, Execute.
	Process   = 2, // A process: its addresses, its handles and its threads (`Process_Create`). Rights: Give, Read, Control, Debug.
	Interrupt = 3, // One interrupt line or message interrupt of a device, which wakes the threads of its holder (`Device_Create`). Rights: Give, Read.
	Ports     = 4, // A range of input and output ports of a device (`Device_Create`). Rights: Give.
	Machine   = 5, // The machine: its rights are Give, Inspect, Devices, Stop, Physical, Schedule, Events and Counters.
	Thread    = 6, // One thread of a process (`Thread_Create`). Rights: Give, Read, Write, Control, Inspect.
	Budget    = 7, // A budget: what its holders can still create (`Budget_Create`). Rights: Give, Read, Spend, Commit.
	Log       = 8, // The log of the kernel. Rights: Give, Write. Each process has one at `CONTEXT_LOG`.
}

// What a process asks the kernel. A thread asks for an operation with one
// command record in its kernel ring: `kind` is the operation, and the
// values are its arguments, in the order of its form. Then it enters the
// kernel with the `syscall` instruction. The kernel executes the commands
// of the ring in their order, and gives one completion record for each:
// `kind` is a `Status`, and the values are the results, in the order that
// each operation states. A completion with the status `Ok` has the results;
// with another status the operation failed, and the values of its
// completion are an [error record](errors.Error_Record): the
// argument that was wrong, its value, and what the kernel found (the
// [errors of the kernel](docs/MODULE_CONTRACT.md#8-errors-that-diagnose)).
// A command whose kind has the bit `COMMAND_NAMES_ERROR_DETAILS` also
// receives one error detail for each other wrong argument, in the
// [table of error details](term:table-of-error-details) that its last value
// names. The kind 0 (`None`) and each kind past the last operation name no
// operation: the kernel refuses the command with `Bad_Operation` and the
// error record `Unknown_Operation`, and changes nothing.
//
// A handle argument names an object of this process by the number that a
// grant or an operation gave. When the handle names no object of the kind
// that the operation needs, the status is `Bad_Handle`; when it names the
// object but has not the right that the operation needs, `No_Right`. The
// rights that each operation needs are in **bold**.
//
// `src/library/modus/system` calls each operation with a procedure of its own
// (`system.memory_create`) or with `system.call`.
Operation :: enum u32 {
	None           = 0,
	Log            = 1, // (log, address, length, level: Log_Level, runs, form: Log_Record_Form).
	// Writes one text or one log fact on the log of the kernel: records of the log, which a reader with the
	// memory of the log reads, and one line `[name] text` on the serial port. The kernel sets the time, the
	// process and the thread of each record, so a process cannot write a record of another process. The
	// operation writes the records only; the tick of the first processor writes their line on the serial port
	// after it, so a `Log` never waits for the lines of other processes.
	//
	// **Arguments**
	//
	// - `log`: the log handle, with **Write**. Each process has it in its context at `CONTEXT_LOG`.
	// - `address`, `length`: the bytes of the record, in memory that the process can read. For the form `Text`,
	//   the text, at most `LOG_TEXT_BYTES_MOST` bytes. A text longer than `LOG_TEXT_CAPACITY` continues in the
	//   next records (`Log_Record`, `more`). For the form `Fact`, a `Log_Fact_Call` up to the end of its
	//   values: from `LOG_FACT_HEAD_BYTES` to `LOG_FACT_CALL_BYTES_MOST` bytes. The kernel cuts the values in
	//   parts of `LOG_FACT_VALUE_CAPACITY` bytes and writes one record of each part, in a row, each with the
	//   module hash and the key, and `more` but on the last; it writes `value_count`, `part` and `part_count`
	//   of each, and reads no other field.
	// - `level`: a `Log_Level`, from `Info` (0) to `Error` (3).
	// - `runs`: the count of the value runs of the text, at most `LOG_CALL_RUN_LIMIT`; 0 is a plain text. The
	//   runs (`value_kinds.Value_Run_In_Call`) follow the `length` bytes of the text at `address`. A run says
	//   which bytes of the text are one value, and its kind: a reader of the log shows each value in the color
	//   of its kind. The text is written whole in every case: if a run is wrong, the record is plain. A fact
	//   has no runs: 0.
	// - `form`: a `Log_Record_Form`. 0 is `Text`, so a writer of text gives five arguments.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `log` is not a log handle with **Write**.
	// - `Bad_Address`: `length` is above `LOG_TEXT_BYTES_MOST`, or the process cannot read the text and its runs.
	//   For a fact: `length` is below `LOG_FACT_HEAD_BYTES` or above `LOG_FACT_CALL_BYTES_MOST`, or the
	//   process cannot read the bytes.
	// - `Bad_Operation`: `level` is above `Error`, `runs` is above `LOG_CALL_RUN_LIMIT`, `form` names no
	//   `Log_Record_Form`, or a fact has runs.
	// - `No_Budget`: the budget of the process accepted all the records of its amount in this second
	//   (`Budget_Amounts`, `log_records`). No other budget counts the record, so the refusal says nothing of
	//   what other processes wrote. A fact counts one record for each of its parts.
	Memory_Create  = 2, // (budget, pages, flags: Memory_Flags) -> memory handle.
	// Makes a memory object of `pages` pages of 4096 bytes, and gives a handle to it with each right of
	// memory: **Give**, **Read**, **Write** and **Execute**. The memory is zero. The budget pays now, so an
	// access to the memory never fails for lack of memory.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays now for each page and for the frame list of the
	//   object (`memory_cost`). A `Contiguous` object has no frame list; an `Uncommitted` object pays its
	//   frame list only, and at least one page.
	// - `pages`: the count of pages, from 1; at most `MEMORY_PAGE_LIMIT` (1 GiB) for an object that is not
	//   contiguous.
	// - `flags`: a `Memory_Flags`:
	//   - `Frames_Now`: each page gets its page frame now, not at its first use (a page on first use);
	//   - `Contiguous`: the frames follow each other in physical memory and do not move, for a device;
	//   - `Uncommitted`: no page is paid now, and `Memory_Commit` pays them later; with no other flag;
	//   - `Large_Pages`: `Contiguous`, in one run aligned on 2 MiB, with `pages` a multiple of
	//     `LARGE_PAGE_PAGES`, so that a mapping uses large pages.
	//
	// **Results**: the memory handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Operation`: `pages` is 0, or above the limit; a flag that the kernel does not know;
	//   `Uncommitted` with another flag; `Large_Pages` with a count that is not a multiple of
	//   `LARGE_PAGE_PAGES`.
	// - `No_Budget`: the budget cannot pay.
	// - `No_Slot`: the table of the memory objects of the kernel is full, or the handle table of the process.
	// - `No_Memory`: a contiguous object finds no free run of its length, though the budget can pay.
	//
	// ```odin
	// memory, status := system.memory_create(16, flags = {.Frames_Now})
	// ```
	Memory_Map     = 3, // (memory, process, address, flags: Map_Flags, first, pages) -> address.
	// Maps pages of a memory object in this process or in another process, and gives the address of the
	// first page.
	//
	// **Arguments**
	//
	// - `memory`: a memory handle with **Read**, and **Write** to map with `Write`, **Execute** to map with
	//   `Execute`.
	// - `process`: 0 for this process, or a process handle with **Control**.
	// - `address`: the address of the first page: a multiple of 4096, at least 4096, with the mapping below
	//   `USER_END` and over no other mapping. 0: the kernel chooses the lowest free place from
	//   `CHOSEN_BASE`, with a page with no mapping before and after it, on 2 MiB for an object of
	//   `Large_Pages` that is mapped by whole large pages. With `At_Address_Zero`, the address is 0.
	// - `flags`: a `Map_Flags`: `Write`, `Execute`, `No_Access` (the pages fault until `Memory_Protect`
	//   gives them access), `Receive_Handles` (this process agrees to receive handles through this memory
	//   object from `Handle_Give`), `At_Address_Zero`, or `Write_Combining` (device memory of
	//   `Device_Kind.Memory` that is write-combining, not uncached). No flag: read only. The kernel refuses any other
	//   bit. `Write` with `Execute` needs `No_Access`: no page is writable and executable. Such a switching
	//   mapping gets `Write`, `Execute` or `No_Access` from `Memory_Protect` for the whole mapping, and
	//   the kernel switches each page between `Write` and `Execute` at the fault of the guest. `Write` with `Execute` and
	//   `At_Address_Zero` are guest memory: only for another process that no thread ran
	//   ([a guest](docs/ARCHITECTURE.md#a-guest)), which `Process_Start` then refuses.
	// - `first`: the first page of the object.
	// - `pages`: the count of pages, or 0 for each page from `first` to the end of the object.
	//
	// **Results**: the address of the first page.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` or `process` is not a handle of its kind with its rights.
	// - `No_Right`: also, the process maps in itself at addresses that meet a module record of the
	//   writer `Starter` (`Module_Writer`). The error kind is `Starter_Module`. The kernel checks it before
	//   the other mappings. An address that the kernel chooses meets no such record.
	// - `Bad_State`: the process is stopped; a part of the object has a protection of its own
	//   (`Memory_Protect`): such an object has one mapping only; guest memory for this process, or for
	//   a process that a thread ran; or device memory with a live mapping of another cache type (no cache,
	//   `Write_Combining`, or the entry of a screen) through this object or another object whose physical
	//   pages meet its pages. The error kind is `Object_Shared`.
	// - `Bad_Address`: the pages are not inside the object; the address is not a multiple of 4096, is below
	//   4096 with no `At_Address_Zero`, is not 0 with it, ends above `USER_END`, or meets another mapping.
	// - `Bad_Operation`: `Write` with `Execute` and with no `No_Access`; `Write_Combining` on memory that is
	//   not device memory of `Device_Kind.Memory`, or with `Execute`; or a flag that the kernel does not know, which it refuses
	//   before it reads the handles; or, with the IOMMU in use, `memory` is device memory over the
	//   registers of a device with a domain and `process` names another process: only the holder of the
	//   registers maps them, so that its mappings keep the domain of the device.
	// - `No_Slot`: the process has 128 mappings, or the kernel finds no free place for the address that it
	//   chooses.
	// - `No_Budget`, `No_Memory`: the budget of the process that receives the mapping cannot pay its page
	//   tables, or no page frame is free.
	//
	// ```odin
	// address, status := system.memory_map(memory, flags = {.Write})
	// ```
	Memory_Unmap   = 4, // (process, address).
	// Removes the mapping that starts at an address, in this process or in another process. The memory
	// object ends when no handle and no mapping names it.
	//
	// **Arguments**
	//
	// - `process`: 0 for this process, or a process handle with **Control**.
	// - `address`: the first byte of a mapping, below `THREAD_AREA_BASE`: the thread areas and the time page
	//   stay.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Control**.
	// - `No_Right`: also, the process unmaps in itself a mapping that meets a module record of the writer
	//   `Starter` (`Module_Writer`). The error kind is `Starter_Module`.
	// - `Bad_State`: the process is stopped.
	// - `Bad_Address`: no mapping starts at the address, or it is a thread area or the time page.
	Memory_Size    = 5, // (memory) -> pages, flags: Memory_Flags.
	// Gives the count of pages of a memory object, and the flags of its creation that it keeps. A process that
	// reads an object that another process gives checks them before it maps it: the pages of an Uncommitted
	// object can have no frame, and an access to such a page is a fault.
	//
	// **Arguments**
	//
	// - `memory`: a memory handle, with any rights.
	//
	// **Results**: the count of pages; the flags `Contiguous`, `Uncommitted` and `Large_Pages` that the object
	// was made with. `Frames_Now` is not given: an object made with it is the same as one whose pages each
	// had their first use.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `memory` is not a memory handle.
	Process_Create = 6, // (budget, name, name_length) -> process handle.
	// Makes a process, in the state `Created`, and gives a handle to it with **Give**, **Read** and
	// **Control**. The process has no memory and no handle: its addresses hold the time page only.
	// `Process_Start` starts it.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays for one process slot, for the page tables of
	//   the process, and for the `OWN_LOG_PAGES` pages of its own log ring, which return to it when the
	//   slot of the process is free. The process keeps it: it pays for its first thread at `Process_Start`, and for each
	//   page table of the process after.
	// - `name`, `name_length`: the name of the process, at most `PROCESS_NAME_BYTES_MOST` bytes, in memory that the process can
	//   read: the reports and the log show it. Each byte is a printable character of ASCII or the
	//   space (32 to 126): a name starts each line of the log on the serial port.
	//
	// **Results**: the process handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Address`: `name_length` is above `PROCESS_NAME_BYTES_MOST`, or the process cannot read the name.
	// - `Bad_Operation`: a byte of the name is outside 32 to 126.
	// - `No_Budget`: the budget has no process slot or no page left, or it cannot pay the page tables or
	//   the own log ring.
	// - `No_Slot`: the table of the processes of the kernel is full, or the handle table of the process.
	Process_Start  = 7, // (process, entry, stack, context).
	// Starts a process that `Process_Create` made: its first thread runs at `entry`, and the process goes
	// from `Created` to `Ready`. The budget of the process pays for the thread, as `Thread_Create` does.
	// The first thread gets the limit of a new thread of the calling thread
	// (`new_thread_weight_limit_of_creation`: the smaller of the new-thread weight limit of the calling
	// thread and the one of its process) and the limit of its placement (`Thread_Placement`): a process
	// does not leave a limit by a process that it starts.
	//
	// **Arguments**
	//
	// - `process`: a process handle with **Control**, of a process in the state `Created`.
	// - `entry`: the address of the first instruction, below `USER_END`.
	// - `stack`: the top of the stack, from 8 to `USER_END`; the thread starts with its stack pointer at
	//   `stack` minus 8, as after a call.
	// - `context`: the value of the first register of the thread. By the rule of the system it is the
	//   address of the `Context` of the process (`CONTEXT_ADDRESS`); the kernel does not read it.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Control**.
	// - `Bad_State`: the process is not in the state `Created`, is a guest (`Guest_Run`), or holds guest
	//   memory: a mapping at the address 0, or one with `Write` and `Execute` (`Memory_Map`).
	// - `Bad_Address`: `entry` or `stack` is out of its range.
	// - `No_Budget`: the budget of the process has no thread slot left, or it cannot pay for the thread
	//   area or its page tables.
	// - `No_Slot`: the thread table of the kernel is full, or the process has `THREAD_CAPACITY` threads.
	// - `No_Memory`: no free run of page frames for the thread area.
	Process_Stop   = 8, // (process, outcome: Stop_Outcome, error: Error_Record).
	// Stops a process: this one or another one. Each of its threads ends, and the operation returns when no
	// thread of the process runs an instruction any more. The process is `Stopped` with its stop cause and its
	// stop outcome, which `Process_State` gives. Its handles, its mappings and its memory end when its last
	// thread left its processor. A process that is stopped already keeps its first stop cause and outcome.
	//
	// The kernel records the stop cause from the target, never from the argument: `Itself` when the target is
	// the process that asks (by 0 or by a handle that names it), `Holder` for another process. Only a process
	// that stops itself says what its work gave: a holder cannot forge the end of another process
	// (src/md/api/process_stop.md).
	//
	// **Arguments**
	//
	// - `process`: 0 for this process, or a process handle with **Control**. With 0, the thread that asks
	//   ends with its process: the operation does not return.
	// - `outcome`: for a stop of this process, the word of a `Stop_Outcome` other than `None`: `Done`,
	//   `Failed`, `Refused` or `Stopped_On_Request`. For a stop of another process, 0.
	// - `error`: 0, or the address of a readable `errors.Error_Record` in the caller. A non-zero address is
	//   allowed only when the target is this process and `outcome` is `Failed` or `Refused`, and the copied
	//   record must have a known non-zero `kind` and a known `unit`. For `Done`, `Stopped_On_Request`, and any
	//   holder stop, `error` must be 0.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Control**.
	// - `Bad_Address`: `error` is non-zero and names bytes that the caller cannot read.
	// - `Bad_Operation`: `outcome` names no valid outcome for the target, `error` is non-zero when disallowed,
	//   or the copied error record has an invalid kind or unit. Nothing changes: the target runs on.
	Process_State  = 9, // (process, report: Stop_Report) -> state: Process_State, cause: Stop_Cause, outcome: Stop_Outcome, entries, slot, serial.
	// Gives the state of a process, its stop cause and its stop outcome, its count of kernel entries, and its
	// place in the reports of `Inspect`. With an address, the kernel also writes there where the process
	// stopped on a fault. A reader takes the first three results through `stop_of_words`.
	//
	// The root service states facts of a process that it started by that place: the disk process page names
	// each disk process by its slot and its serial, which the reports of `Inspect` give too
	// (`modus:contract/disk_process_page`).
	//
	// **Arguments**
	//
	// - `process`: a process handle with **Read**.
	// - `report`: 0, or the address of a `Stop_Report` that the process can write: the instruction, the
	//   address of a page fault, the module and the stack trace of the fault that stopped the process. All
	//   zero while the process runs, or when its stop cause is not `Fault`, `Not_Committed` or
	//   `Cannot_Return`.
	//
	// **Results**
	//
	// 1. the `Process_State` of the process: `Created`, `Ready` (one of its threads is ready), `Waiting` or
	//    `Stopped`;
	// 2. its `Stop_Cause`: `None` while it runs;
	// 3. its `Stop_Outcome`: `None` while it runs, and for each stop cause but `Itself`;
	// 4. its kernel entries since its start;
	// 5. its process slot: the index that `Inspect` with the kind `Process` takes for it;
	// 6. its process serial, as `Process_Report.process_serial` gives it: the slot and the serial name this
	//    process and no later one. The kernel keeps both until the last handle of the process closes.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Read**.
	// - `Bad_Address`: the process cannot write the `Stop_Report` at `report`.
	Handle_Give    = 10, // (target, handle, rights: Rights) -> the handle in the target.
	// Copies a handle into a process, with a part of its rights: a grant never adds a right. The kernel
	// records where the copy came from (its origin): `Handle_Revoke` of the given handle ends the copy, and
	// when the given handle closes, the copy comes from the origin of the given handle.
	//
	// **Arguments**
	//
	// - `target`: where the copy goes:
	//   - 0: this process, with no right needed;
	//   - a process handle with **Control**: that process;
	//   - a memory handle: the one other process that maps this memory with `Map_Flag.Receive_Handles`.
	//     A process that holds or maps this memory without `Receive_Handles` never receives handles
	//     through it. The kernel keeps, with the copy, the memory object that it came through:
	//     `Handle_State` proves it to the receiver.
	// - `handle`: the handle to give, with **Give** when the target is another process.
	// - `rights`: the rights of the copy are the rights of `handle` that are also in `rights`. A process
	//   handle that goes to the process that it names also loses **Control** and **Give**: a process never
	//   holds the authority of its starter over itself, so it cannot give it to a child that would change
	//   its module records ([the writer of a module record](docs/MODULE_CONTRACT.md#the-writer-of-a-module-record)).
	//
	// **Results**: the number of the copy in the target process.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` or `target` names nothing; `target` is a handle of another kind; or it is a
	//   memory object that no other process maps, or that two other processes map with `Receive_Handles`.
	// - `No_Right`: `handle` has not **Give**, the process handle `target` has not **Control**, or `target`
	//   is a memory object that another process maps without `Receive_Handles`.
	// - `Bad_State`: the target process is stopped; or `handle` names a memory object with a protection of
	//   its own on a part (`Memory_Protect`), and the target is another process.
	// - `No_Slot`: the handle table of the target process is full.
	//
	// ```odin
	// copy, status := system.give(process, memory, {.Read})
	// ```
	Handle_Close   = 11, // (handle).
	// Closes a handle of this process. What came from it (its copies and its mappings) comes from its origin
	// now. The object ends when nothing names it:
	//
	// - a memory object, when no handle and no mapping names it;
	// - a budget, when its last handle closes: what it holds returns to the budget that it came from, which
	//   pays for its objects;
	// - a process: it stops with the stop cause `Handles_Closed` when its last handle closes;
	// - the event table of the machine, when the last machine handle with **Events** of its process closes.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this process.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing.
	Interrupt_Read = 12, // (interrupt) -> count.
	// Gives the count of the interrupts of a line or of a message interrupt since the last read, and sets
	// it to 0. Each interrupt also adds 1 to the `events` word of the threads of the process that holds the
	// handle, and wakes them.
	//
	// **Arguments**
	//
	// - `interrupt`: an interrupt handle with **Read**.
	//
	// **Results**: the count of interrupts.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `interrupt` is not an interrupt handle with **Read**.
	Device_Create  = 13, // (machine, kind: Device_Kind, a, b) -> handle, address, value.
	// Makes a handle to a part of the machine, for a device service.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Devices**.
	// - `kind`, `a`, `b`: a `Device_Kind` and its two values:
	//   - `Ports`: `a` the first port, below 65536, and `b` the count, from 1 to 65536 minus `a`: a ports
	//     handle with **Give**; the threads of the process use the ports with `in` and `out`;
	//   - `Interrupt`: `a` a line of the 8259, from 1 to 15: an interrupt handle with **Give** and **Read**;
	//   - `Memory`: `a` the physical address, a multiple of 4096, and `b` the count of pages of the
	//     registers of a device: a memory handle with **Give**, **Read** and **Write**, mapped with no cache.
	//     The range meets no memory that the firmware gave as free or as loaded;
	//   - `Display_Memory`: as `Memory`, for the video memory of a display: the range must hold the
	//     address of the framebuffer of the firmware; the mapping has the page attribute of that
	//     framebuffer, not "no cache", and the object has no requester for the IOMMU;
	//   - `Message`: `a` the physical address where a memory base address register of the device starts:
	//     a message interrupt (MSI-X) of the first processor, for that device: an interrupt handle with
	//     **Give** and **Read**. With interrupt remapping in use, the entry of the message names that device,
	//     and the unit refuses the message to every other device; with none, `a` is not read. Behind a
	//     conventional bridge, the entry names the requester that the devices there share, and it is present
	//     only while their one domain lives (`Memory_Physical`).
	//
	// **Results**
	//
	// 1. the handle;
	// 2. for `Message`: the address that the device writes: the remappable form of the entry with
	//    interrupt remapping of Intel in use, else the compatible form of the first processor; for
	//    `Memory`: the `Device_Memory_Facts` of the device whose base address register starts at `a`
	//    (empty with no IOMMU in use, and always empty for `Display_Memory`);
	// 3. for `Message` only: the value that the device writes there: 0 in the remappable form; the
	//    index of the entry in the interrupt table of the device with interrupt remapping of AMD in use;
	//    else the vector.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Devices**.
	// - `Bad_Address`: the ports, the line or the range of memory is out of its range.
	// - `Bad_Operation`: `kind` is `None` or a kind that the kernel does not know; or `Display_Memory` over
	//   a range that does not hold the framebuffer of the firmware: the error record has the kind
	//   `Bad_Value` for `a`, with the address of that framebuffer as its limit.
	// - `No_Slot`: no free memory object, no free message interrupt (`MESSAGE_CAPACITY`), or the handle
	//   table of the process is full.
	Inspect        = 14, // (machine, kind: Inspect_Kind, index, address, size) -> bytes written.
	// Writes a report of the kernel into memory of the process. Each `Inspect_Kind` has its report:
	//
	// - `System`: a `System_Report`; `index` is not read;
	// - `Process`: the `Process_Report` of the process slot `index`;
	// - `Processor`: the `Processor_Report` of the processor `index`;
	// - `Boot`: the `Boot_Report`;
	// - `Mappings`: the `Mapping_Report` of the page table: `index` 0 for the kernel half of the addresses,
	//   another value for the half of the process that asks;
	// - `Modules`: the `Module_Report` of the process slot `index`;
	// - `Process_Mappings`, `Threads`, `Stop`: the reports of a developer tool for the process slot `index`:
	//   `Process_Mapping_Report`, `Thread_Table_Report`, `Stop_Report`;
	// - `Pages`: the `Page_Report` of the process that asks, for the address that it wrote in the record;
	//   `index` must be 0.
	//
	// A slot or a processor with no process, or out of the table, gives a report of zeros.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Inspect**.
	// - `kind`, `index`: the report, as above.
	// - `address`, `size`: the memory of the report: `size` is at least the size of the report, and the
	//   process can write it.
	//
	// **Results**: the bytes written: the size of the report.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Inspect**.
	// - `Bad_Address`: `size` is below the size of the report, or the process cannot write the memory.
	// - `Bad_Operation`: `kind` is `None` or a kind that the kernel does not know; for `Pages`, `index` is
	//   not 0, or the address in the record is not a multiple of 4096, or its 64 pages pass `USER_END`.
	Machine_Stop   = 15, // (machine, code).
	// Stops the machine: the kernel writes `kernel: the machine stops with code <code>` on the log, then
	// stops each processor. The operation does not return.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Stop**.
	// - `code`: the code of the stop, from 0 to `MACHINE_STOP_CODE_MOST`: the machine gives it to its host.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Stop**.
	// - `Bad_Operation`: `code` is above `MACHINE_STOP_CODE_MOST`. A code that the host cannot receive
	//   whole is refused: else a code of 256 would end the machine with 0, the code of a normal end.
	Thread_Create  = 16, // (budget, entry, stack, parameter, weight, request) -> thread handle.
	// Starts a new thread of this process, and gives a handle to it with **Give**, **Read**, **Write**,
	// **Control** and **Inspect**. The thread is ready at once: it starts at `entry` with `parameter` in its
	// first register, and its stack pointer at `stack` minus 8.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays for the thread slot and for the thread area: the
	//   thread record, the kernel ring and a page with no memory. The budget of the process pays for the
	//   page tables of the area.
	// - `entry`: the address of the first instruction, below `USER_END`.
	// - `stack`: the top of the stack, from 8 to `USER_END`.
	// - `parameter`: any value.
	// - `weight`: from 1 to the limit of a new thread: the smaller of the new-thread weight limit of the
	//   calling thread (`Thread_Schedule`) and the one of its process (`Process_Schedule`,
	//   `new_thread_weight_limit_of_creation`). Each is `WEIGHT_FULL` unless the holder of the machine
	//   lowered it; 0 is that limit. A weight above it is refused. While the share policy of the process
	//   `scheduler` is on, it writes the process weight divided by 32 there, so the limit can be 32: a
	//   process that passes a weight reads its own schedule first, or passes 0. The share of the thread
	//   under the strategies that use weights. A weight can only be lower than the weight of a thread
	//   created with 0. The new thread gets that limit as its weight limit and as its own new-thread
	//   weight limit (`thread_schedule_of_new_thread`). It also gets the limit of the
	//   placement of the calling thread, as its set of processors and as its limit (`Thread_Placement`).
	// - `request`: microseconds, from 1 to `REQUEST_LIMIT`; 0 is `REQUEST_DEFAULT`. The delay that the
	//   thread asks for under EEVDF ([weights and requests](docs/SCHEDULING.md#weights-and-requests-a-field-at-thread-creation)).
	//
	// **Results**: the thread handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Operation`: `weight` is above the limit of a new thread, or `request` above
	//   `REQUEST_LIMIT`.
	// - `Bad_Address`: `entry` or `stack` is out of its range.
	// - `Bad_State`: the process stops.
	// - `No_Slot`: the thread table of the kernel is full, the process has `THREAD_CAPACITY` threads, or
	//   its handle table is full.
	// - `No_Budget`: the budget has no thread slot left, or it cannot pay for the thread area or its page
	//   tables.
	// - `No_Memory`: no free run of page frames for the thread area.
	//
	// ```odin
	// thread, status := system.thread_start(worker, nil)
	// ```
	Thread_Stop    = 17, // (thread).
	// Ends a thread: the calling thread, or a thread that a handle names, of this process or of another one.
	// A thread on another processor leaves it at once, and the operation returns after it left. The other
	// threads of its process get an event. A process with no thread left stops, with the stop cause
	// `Last_Thread_Ended` and no stop outcome.
	//
	// **Arguments**
	//
	// - `thread`: 0 for the calling thread, which ends: the operation does not return. Else a thread handle
	//   with **Control**.
	//
	// **Results**: none. A thread that ended already stays as it is.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Control**.
	Thread_State   = 18, // (thread) -> state: Process_State, stop count, area bytes, components, form.
	// Gives the state of a thread, and what a holder of the thread needs for `Thread_Control`.
	//
	// **Arguments**
	//
	// - `thread`: a thread handle with **Read**.
	//
	// **Results**
	//
	// 1. its `Process_State`: `Ready`, `Waiting` or `Stopped`. A thread that a stop holds is `Ready` when
	//    its wait ended, and runs only when its stop count is 0;
	// 2. its stop count (`Thread_Control`);
	// 3. the bytes of the extended state area of a thread on this machine;
	// 4. its components: the bits of XCR0 (0 x87, 1 SSE, 2 AVX, 5 to 7 AVX-512);
	// 5. its `Extended_State_Layout`: `With_Header` when the area has the header of `xsave` at byte 512,
	//    `Legacy` when it is the 512 bytes of `fxsave`.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Read**.
	Word_Wait      = 19, // (words: Word, count).
	// Adds words to the wait of this kernel entry: the one way to wait for something else than a time. A
	// thread that asks for a wait when it enters the kernel waits at the end of the entry while each word
	// of its list holds its value. The wait ends when `Word_Wake` names one of its words, or at its
	// deadline. The kernel names a word by its page frame, so two processes that map one memory object wait
	// on one word. If a word does not hold its value already, the wait ends at once: no wake is lost
	// between a read of the word and the wait.
	//
	// **Arguments**
	//
	// - `words`: the address of `count` records `Word`: each one is the address of a word of 32 bits, a
	//   multiple of 4 that the process can read, and the value that the word holds while the thread waits
	//   (the low 32 bits of `value`).
	// - `count`: the words of this command. One entry holds at most `WORD_WAIT_CAPACITY` words in all its
	//   commands.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `No_Slot`: the entry would hold more than `WORD_WAIT_CAPACITY` words.
	// - `Bad_Address`: the process cannot read the table or a word, or a word is not a multiple of 4. The
	//   entry then does not wait.
	//
	// ```odin
	// system.word_wait(&ready, 0, deadline)
	// ```
	Word_Wake      = 20, // (word, count) -> threads woken.
	// Ends the wait of at most `count` threads that wait on a word. A thread that put the word in the wait
	// of its entry and does not wait yet counts too: it does not wait, and reads its words again.
	//
	// **Arguments**
	//
	// - `word`: the address of a word of 32 bits, a multiple of 4 that the process can read.
	// - `count`: the most threads to wake.
	//
	// **Results**: the count of threads woken.
	//
	// **Statuses**
	//
	// - `Bad_Address`: the process cannot read the word, or its address is not a multiple of 4.
	//
	// ```odin
	// system.word_wake(&ready)
	// ```
	Budget_Create  = 21, // (budget, pages, processes, threads, processor, log_records) -> budget handle.
	// Makes a budget from a budget, and gives a handle to it with **Give**, **Read**, **Spend** and
	// **Commit** (`Budget_Amounts` says what each amount is). The pages, the process slots, the thread
	// slots and the log records of each second move from `budget` to the new budget. The processor time is
	// a limit for each second, for the new budget and each budget that comes from it. When the last handle
	// to the new budget closes, what it holds returns to `budget`, which pays for its objects.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**.
	// - `pages`, `processes`, `threads`: what moves to the new budget.
	// - `processor`: microseconds of processor time in each second, on all the processors together: at most
	//   the limit of `budget`.
	// - `log_records`: records of the log in each second, which move to the new budget.
	//
	// **Results**: the budget handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `No_Budget`: `budget` holds less than an amount that moves, or a limit is above its own.
	// - `No_Slot`: the table of the budgets of the kernel is full, or the handle table of the process.
	Budget_Read    = 22, // (budget) -> pages, processes, threads, processor, log_records, processor time, refused.
	// Gives what a budget can still pay, its limits, and what it used.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Read**.
	//
	// **Results**
	//
	// 1. the pages that it can still pay;
	// 2. the process slots that it can still pay;
	// 3. the thread slots that it can still pay;
	// 4. its limit of processor time: microseconds in each second;
	// 5. the log records of each second that it holds: its amount, after the budgets that came from it;
	// 6. the microseconds of processor time that its threads used since it was made;
	// 7. the log records that the kernel refused to it.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Read**.
	Handle_State   = 23, // (handle, memory) -> kind: Object_Kind, rights: Rights, through, holdings.
	// Gives the kind and the rights of a handle of this process, and proves where it came from. A process
	// that receives the number of a handle from another process, in a ring, proves with this operation that
	// the other process gave the handle through that ring (`Handle_Give` with the memory of the ring as its
	// target). Without the proof, the other process can name a handle that the receiver holds for itself.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this process.
	// - `memory`: 0, or a memory handle with any rights: the memory of the ring.
	//
	// **Results**
	//
	// 1. the `Object_Kind` of the object;
	// 2. the `Rights` of the handle;
	// 3. 1 when the handle came through the memory object of `memory`, else 0;
	// 4. the count of the holdings that came from this handle, in all processes: what `Handle_Revoke` ends.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing, or `memory` is not a memory handle.
	Handle_Revoke  = 24, // (handle, process) -> holdings ended.
	// Ends each holding that came from a handle. A holding is a handle or a mapping. The origin of a handle
	// that `Handle_Give` made is the handle that was given; the origin of a mapping is the memory handle
	// that was mapped. When a handle closes, what came from it comes from its origin. The operation ends
	// each holding that came from the handle, and what came from those holdings, in any process. The handle
	// stays, and the mappings of the process that revokes stay. A process that lost a holding gets an event.
	// A thread that uses memory that its process lost stops its process on a page fault.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this process, with any rights: the process that holds it is the origin of
	//   what came from it.
	// - `process`: 0 for each process, or a process handle with **Control**: only the holdings in that
	//   process.
	//
	// **Results**: the count of the holdings that ended.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing, or `process` is not a process handle.
	// - `No_Right`: the process handle has not **Control**.
	Memory_Physical = 25, // (machine, memory) -> device address.
	// Gives the address that a device uses for the first page of a memory object, so that a device service
	// gives it to its device, which reads and writes the memory with no processor (direct memory access).
	// For an object whose pages follow each other in physical memory and do not move (an object created
	// `Contiguous` or `Large_Pages`, or the registers of a device), it is the physical address of the first
	// page.
	//
	// When the IOMMU is in use, the call is also the declaration: each page of the object, which is not
	// device memory, becomes memory that each device whose registers the caller holds by a handle can read,
	// and write only while the caller holds a handle with **Write** to the object. A process that holds no
	// such handle declares nothing. An object that is not contiguous then has a device window: its pages
	// get their frames now, and the devices see them in their order from the address that the call gives,
	// at 2^38 or above: a device that gives fewer than 39 bits of address must get contiguous objects only
	// (`Device_Create` says whether the unit of a device gives windows: `Device_Memory_Facts`). The pages leave the
	// device when the process closes or loses its last handle to the object, when it holds neither a handle
	// nor a mapping of the registers of the device, when the object ends, or when the process stops
	// (docs/ARCHITECTURE.md, "K5. Device grant and interrupts"). The devices behind a conventional bridge
	// share one domain: it lives while the caller holds the registers of each of them.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Physical**.
	// - `memory`: a memory handle with **Read**.
	//
	// **Results**: the device address: the physical address, or the address of the window.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` or `memory` is not a handle of its kind with its right.
	// - `Bad_Operation`: the pages of the object are not contiguous, and no IOMMU is in use or the caller
	//   holds the registers of no device: they get their frames at their first use, from anywhere.
	// - `Bad_Operation`: also, with the IOMMU in use, a contiguous object ends above 2^38 or above the
	//   address width of the unit of a device; or an object that is not contiguous is `Uncommitted`, larger
	//   than 128 MiB (`iommu.WINDOW_SIZE`), or declared to a device whose unit gives no windows.
	// - `Bad_State`: another process declared memory to the same device, and it still holds or maps its
	//   registers; or the device is behind a conventional bridge, and the caller does not hold the registers
	//   of each device behind that bridge, which all share its requester and its domain (the log names the
	//   device that it misses).
	// - `No_Slot`: the caller holds the registers of more than 4 devices, or the 32 slots of the devices of
	//   the kernel are in use.
	// - `No_Budget`: the budget of the caller cannot pay for a page of the tables of the device.
	Process_Module = 26, // (process, record: Module_Record).
	// Records a module that a loader put in a process, in the module records of the process. The kernel
	// does not read the module: the record is what the loader asserts. The kernel names the module of the
	// address of a fault with it, and `Inspect` gives the records (`Module_Report`). The kernel writes the
	// writer of the record (`Module_Writer`): `Process` when the process records a module in itself,
	// `Starter` when another process does it through the process handle. A process cannot replace or
	// remove a record of the writer `Starter`, and cannot map or unmap where such a record is, so the
	// record names the code that its starter put there
	// ([the writer of a module record](docs/MODULE_CONTRACT.md#the-writer-of-a-module-record)).
	//
	// **Arguments**
	//
	// - `process`: 0 for this process, or a process handle with **Control**.
	// - `record`: the address of a `Module_Record` that the process can read. A record with the base of a
	//   record that exists replaces it; a record with the size 0 removes the record of its base. A process
	//   has at most `PROCESS_MODULE_CAPACITY` records, and no two of them share an address. The kernel
	//   does not read the field `writer`.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Control**.
	// - `No_Right`: also, the process replaces or removes in itself a record of the writer `Starter`. The
	//   error kind is `Starter_Module`: the fix is with the holder of the process handle.
	// - `Bad_State`: the process is stopped.
	// - `Bad_Address`: the process cannot read the record; the module passes `USER_END`; it meets another
	//   record; or a record of size 0 names a base that no record has.
	// - `No_Slot`: the process has `PROCESS_MODULE_CAPACITY` records.
	Strategy_Set = 27, // (machine, strategy: Strategy) -> the strategy before.
	// Changes the scheduling strategy of the machine while it runs: no thread stops, and none is lost. The
	// state of the strategy of each thread starts from zero
	// ([the change of strategy](docs/SCHEDULING.md#the-change-of-strategy-is-a-kernel-operation-with-a-right)).
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Schedule**.
	// - `strategy`: `Round_Robin`, `Fair` or `Eevdf`.
	//
	// **Results**: the `Strategy` before.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Schedule**.
	// - `Bad_Operation`: `strategy` is `None` or a strategy that the kernel does not know.
	//
	// ```odin
	// before, status := system.strategy_set(machine, .Eevdf)
	// ```
	Memory_Commit = 28, // (memory, budget, ranges: Page_Range, count, flags: Commit_Flags) -> pages changed.
	// Commits the pages of ranges of an object made with `Uncommitted`: the budget pays one page for each
	// page that was not committed, and each gets a frame at its first use. With `Decommit`, the committed
	// pages of the ranges are no longer paid: their frames and their pages return at once to the budget of
	// the object, and a page committed again is zero
	// ([the virtual memory of a process](docs/ARCHITECTURE.md#the-virtual-memory-of-a-process)).
	//
	// **Arguments**
	//
	// - `memory`: a memory handle with **Write**, of an object made with `Uncommitted`.
	// - `budget`: a handle to the budget of the object, with **Commit** or **Spend**. **Write** on the object
	//   does not spend the budget of its maker: to let another process commit, give it the object and a
	//   budget handle with **Commit** only ([who pays a commit](docs/ARCHITECTURE.md#who-pays-a-commit)).
	//   Not read with `Decommit`.
	// - `ranges`, `count`: a table of `count` records `Page_Range`, from 1 to `RANGE_TABLE_CAPACITY`, in
	//   increasing order, with no overlap, inside the object, with at most `RANGE_TABLE_PAGE_LIMIT` pages in
	//   all.
	// - `flags`: a `Commit_Flags`: `Decommit`, or none.
	//
	// **Results**: the count of pages that changed.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` is not a memory handle with **Write**; `budget` is not a budget
	//   handle with **Commit** or **Spend**.
	// - `Bad_Handle`: `budget` names another budget than the budget of the object.
	// - `Bad_Operation`: `count` is 0 or above `RANGE_TABLE_CAPACITY`; a flag that the kernel does not know;
	//   the table has more than `RANGE_TABLE_PAGE_LIMIT` pages; the object was not made `Uncommitted`.
	// - `Bad_Address`: the process cannot read the table, or the ranges are not in order, overlap, or pass
	//   the end of the object.
	// - `No_Budget`: the budget cannot pay the table: nothing changes.
	// - `Bad_State`: a `Decommit` of an object that another process names, or that has more than one
	//   mapping.
	//
	// ```odin
	// changed, status := system.memory_commit(memory, ranges[:])
	// ```
	Memory_Protect = 29, // (ranges: Address_Range, count, flags: Map_Flags, process) -> pages changed.
	// Changes the protection of pages of mappings of this process, or of a guest: read only (no flag),
	// `Write`, `Execute`, or `No_Access`. A switching mapping (guest memory mapped with `Write`, `Execute`
	// and `No_Access`) takes only `Write`, `Execute` or `No_Access`, for the whole mapping: the kernel then
	// switches each page between `Write` and `Execute` at the fault of the guest, never both at once
	// ([a guest](docs/ARCHITECTURE.md#a-guest)). Each processor that runs a thread of the process forgets the old translations before
	// the operation returns (one shoot-down). A table is done whole or not at all
	// ([protection and the shoot-down](docs/ARCHITECTURE.md#protection-and-the-shoot-down)).
	//
	// **Arguments**
	//
	// - `ranges`, `count`: a table of `count` records `Address_Range`, from 1 to `RANGE_TABLE_CAPACITY`.
	//   Each range is inside one mapping of this process, below `THREAD_AREA_BASE`.
	// - `flags`: a `Map_Flags` within `PROTECT_FLAGS_KNOWN` (`Receive_Handles` is refused). A protection
	//   can only take away what the mapping was made with: `Write` needs a mapping made with `Write`,
	//   `Execute` one made with `Execute`. `No_Access` takes no other flag, and `Write` with `Execute`
	//   is refused.
	// - `process`: 0 for this process, or a process handle with **Control** of a process in the state
	//   `Created` with no thread: a guest, or a process that will be one.
	//
	// A range that is a part of a mapping, not its whole, takes away from the protection of the mapping now:
	// it cannot get more. It needs an object with a frame list that only this process names, with one
	// mapping; while a part has its own protection, the object is not mapped again and not given
	// (`Bad_State`). At most `RANGE_TABLE_PAGE_LIMIT` pages change in one call.
	//
	// **Results**: the count of pages that changed.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `count` is 0 or above `RANGE_TABLE_CAPACITY`; a flag that the kernel does not know;
	//   `Write` with `Execute`, or `No_Access` with another flag; more than the mapping was made with; one
	//   table names a mapping whole and in part; more than `RANGE_TABLE_PAGE_LIMIT` pages; read only, or a
	//   part, of a switching mapping: the switch of a page gives it `Write` or `Execute` whatever such a
	//   protection said.
	// - `Bad_Address`: the process cannot read the table; a range is not on whole pages, is empty, or is not
	//   inside one mapping; the mapping is a thread area or the time page; a part of a mapping of a
	//   contiguous object.
	// - `Bad_State`: a part of a mapping of an object that another process names, or that has another
	//   mapping; `process` names a process that a thread ran.
	// - `Bad_Handle`, `No_Right`: `process` is not 0 and not a process handle with **Control**.
	//
	// ```odin
	// changed, status := system.memory_protect(ranges[:], {})
	// ```
	Fault_Handler_Set = 30, // (thread, end: Fault_Handler_Action, kinds: Fault_Kinds, process).
	// Makes a thread of this process the fault handler of the process: the faults of the chosen kinds of
	// the other threads of the process become records of the
	// [fault ring](docs/ARCHITECTURE.md#the-fault-ring) in the thread record of the handler, in place of a
	// stop. The thread of a fault waits for `Fault_Answer`. A page fault is delivered only below
	// `THREAD_AREA_BASE`. A fault of a kind that the handler did not ask for stops the process as with no
	// handler. A new handler replaces the one before, and its ring starts empty.
	//
	// **Arguments**
	//
	// - `thread`: 0 for the calling thread, or a thread handle with **Control** of a live thread of this
	//   process.
	// - `end`: a `Fault_Handler_Action`: `End` (1) ends the delivery, and each fault stops the process
	//   again; `Set` (0) sets the handler.
	// - `kinds`: the `Fault_Kinds` to deliver, or 0 for page faults only, so that a handler of pages never
	//   gets a kind that it does not know. Only the kinds of `FAULT_KINDS_DELIVERED`.
	// - `process`: 0, or a process handle with **Debug** of another process. Then the thread becomes the
	//   [debug handler](docs/ARCHITECTURE.md#the-debugger-of-a-process) of that process: the caller is its
	//   debugger. The faults of the kinds `Debug` and `Breakpoint` of that process become records of the ring
	//   of this thread, before the fault handler of the process itself, and each faulting thread waits for a
	//   `Fault_Answer` with the same handle. `kinds` is then 0 or the whole of
	//   `FAULT_KINDS_DEBUGGER`: the debugger takes both kinds. `end` `End` ends the debugging (the detach). A process has one debugger at a
	//   time, and a thread is the debug handler of one process and not the fault handler of its own.
	//
	// The debugging ends at the detach, when the debug handler thread ends, when the last handle of the
	// debugger to the process with **Debug** closes or is revoked, and when the process stops. The kernel
	// then removes the breakpoints of each thread of the process and the trap flag that the debugger wrote,
	// takes back the stops that the debugger made, and resumes each thread that waits for its answer: a
	// debugger that ends never holds and never stops the process.
	//
	// When a thread of the process waits for an answer, a new handler or the end of the delivery ends the
	// ring that holds its record: the process stops with the stop cause `Fault_Unanswered`, as when the handler
	// thread ends, and the operation gives `Ok`.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `end` names no `Fault_Handler_Action`; a kind that the kernel never delivers; kinds with the end of the
	//   delivery; with `process`, kinds that are not 0 and not the whole of `FAULT_KINDS_DEBUGGER`.
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Control**; `process` is not a
	//   process handle with **Debug**.
	// - `Bad_State`: the thread is not a live thread of this process; the thread is the debug handler of a
	//   process and would become the fault handler of its own, or the reverse; with `process`: the process is
	//   the caller, it stopped, it has another debugger, the thread is the debug handler of another process,
	//   or, for `End`, the caller is not its debugger.
	//
	// ```odin
	// status := system.fault_handler_set(kinds = {.Page_Fault, .Breakpoint})
	// ```
	Fault_Answer = 31, // (thread, serial, answer: Fault_Answer_Kind, process).
	// Answers a thread of this process that waits in the fault ring, by the two values of its
	// `Fault_Record`.
	//
	// **Arguments**
	//
	// - `thread`, `serial`: the `thread` and the `serial` of the record.
	// - `answer`: a `Fault_Answer_Kind`:
	//   - `Resume`: the thread continues with its registers, at the instruction of its record (the faulting
	//     instruction again, or the next one after a trap), or where `Thread_Control` wrote;
	//   - `Stop`: the process stops as with no handler: the stop cause and the stop report of the fault.
	// - `process`: 0, or the process handle with **Debug** of the process that the caller debugs: the answer
	//   is for a thread of that process, whose record came to the debug handler. Only `Resume`: a debugger
	//   stops a process with `Process_Stop` and the right **Control**. After a `Debug` fault of an execute
	//   breakpoint, `Resume` at the same instruction sets the resume flag of the thread, so that the
	//   instruction runs once and the breakpoint stays.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `answer` is not `Resume` or `Stop`; `Stop` with `process`.
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Debug**.
	// - `Bad_State`: no thread with that number waits for the fault of that serial: a wrong answer, a second
	//   answer, or an answer from another process; an answer with no `process` for a fault that went to the
	//   debugger of the process; with `process`, the caller is not the debugger. Also for `Resume` after a fault kind that does not resume
	//   by itself (`fault_kind_resumes`) when `Thread_Control` wrote neither the registers nor the extended
	//   state of the thread since its fault: the thread still waits, and `Stop` ends it.
	//
	// ```odin
	// status := system.fault_answer(record, .Resume)
	// ```
	Events_Set = 32, // (machine, memory, rules: Event_Rule, count, records) -> ring bytes, processors.
	// Gives the event table of the machine: the kernel writes an `Event_Record` into the event ring of the
	// processor of each [kernel event](docs/ARCHITECTURE.md#kernel-events) that a rule accepts. A new table
	// replaces the table of the caller. The table also ends when its process ends, and when the last
	// machine handle of its process with **Events** closes or is revoked: the table lives while the right
	// that made it lives.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Events**.
	// - `memory`: a memory handle with **Write** of an object made `Contiguous` (not the registers of a
	//   device), with room for one ring of `EVENT_RING_HEAD_BYTES` plus `records` times 64 bytes for each
	//   processor, one after the other from its first byte. 0: the caller takes its table away; when the
	//   operation returns, no processor writes in the old memory object.
	// - `rules`, `count`: a table of `count` records `Event_Rule`, from 1 to `EVENT_RULE_CAPACITY`.
	// - `records`: the records of each ring: a power of two from `EVENT_RING_RECORDS_LEAST` to
	//   `EVENT_RING_RECORDS_MOST`.
	//
	// **Results**
	//
	// 1. the bytes of one event ring;
	// 2. the count of processors: the count of rings.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Events**, or `memory` not a
	//   memory handle with **Write**; the process of a rule is not a process handle with **Read**.
	// - `Bad_State`: `memory` is 0 and the caller has no table; or another process has the table: one table
	//   at a time.
	// - `No_Slot`: `count` is above `EVENT_RULE_CAPACITY`.
	// - `Bad_Operation`: `count` is 0; `records` is not a power of two in its range; the object is not
	//   contiguous, is the registers of a device, or is too small for the rings; a rule that the kernel
	//   refuses (its kind, its flags, its reserved values, its least duration or its one in N).
	// - `Bad_Address`: the process cannot read the table of rules.
	Thread_Control = 33, // (thread, number, command: Thread_Control_Command, address, size, source) -> see the command.
	// Controls a thread: holds it and releases it, reads its registers and its extended state, and writes
	// them ([the control of a thread](docs/ARCHITECTURE.md#the-control-of-a-thread)). `Stop` and `Resume`
	// change the stop count of the thread: it runs only while the count is 0. The registers and the
	// extended state are read and written only while the thread is held: its stop count is above 0, or it
	// waits for an answer of the fault ring. It also reads and writes the schedule of a thread: its weight
	// and its request (`Thread_Schedule`), also while the thread runs
	// ([the schedule of a live thread](docs/SCHEDULING.md#the-schedule-of-a-live-thread)). And it reads and
	// writes the placement of a thread: the processors that can run it (`Thread_Placement`), also while the
	// thread runs ([the placement of a thread](docs/SCHEDULING.md#the-placement-of-a-thread)). Two more
	// commands read and write the schedule of a process (`Process_Schedule`): the new-thread weight limit
	// of all the threads of one process at once, through the machine handle only. Three commands count the
	// events of the processor for the code of the calling thread (`Thread_Counters`,
	// [the counters of a thread](docs/ARCHITECTURE.md#the-counters-of-a-thread)).
	//
	// **Arguments**
	//
	// - `thread`: a thread handle with the rights of the command (`thread_control_rights`): **Inspect**,
	//   and **Write** too for a write of the registers or of the extended state; **Control** for
	//   `Write_Schedule` and `Write_Placement`. Or 0, and then `number` names a live thread of this process
	//   (`Thread_Record.number`, `Fault_Record.thread`). Or, for the two commands of the schedule and the
	//   two commands of the placement only, the machine handle with **Schedule** and **Inspect**
	//   (`thread_control_machine_rights`), and then `number` names any thread of the machine. A
	//   thread of another process needs a handle. Or the process handle with **Debug** of the process that
	//   the caller debugs (`Fault_Handler_Set` with that handle first), and then `number` names a live thread
	//   of that process, for each command but the two of the schedule and the two of the placement
	//   (`thread_control_takes_debug_handle`). The two commands of the schedule of a process take the
	//   machine handle with **Schedule** and **Inspect** only. The three commands of the thread counters
	//   act on the calling thread (`thread_control_counts_the_caller`): `Start_Counters` and
	//   `Read_Counters` take the machine handle with **Counters** only; `Stop_Counters` reads no handle.
	// - `number`: the number of the thread when `thread` is 0; the machine number of the thread
	//   (`Thread_Report.machine_number`) when `thread` is the machine handle. For the two commands of the
	//   schedule of a process: the slot of the process in the low 32 bits and its serial
	//   (`Process_Report.process_serial`) in the high 32 bits (`process_slot_and_serial`). Not read by
	//   the three commands of the thread counters.
	// - `command`: a `Thread_Control_Command`.
	// - `address`, `size`: the memory of the command that reads or writes: `size` is at least the size of
	//   a `Thread_Registers`, of the extended state area (`Thread_State`), of a `Thread_Schedule`, of a
	//   `Thread_Breakpoints`, of a `Thread_Placement` or of a `Thread_Counters`, and the process can read it, or write it for a read
	//   of the thread. For
	//   `Read_Memory`, `size` is the count of bytes to read, at most `THREAD_MEMORY_READ_LIMIT`.
	// - `source`: for `Read_Memory`, the address of the first byte in the process of the thread.
	//
	// **Results**: what the command gives: the stop count, or the bytes written and the components.
	// `Read_Memory` gives the count of bytes that it copied.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `command` is `None` or a command that the kernel does not know; a write of values
	//   that a thread of a process cannot hold changes nothing (`thread_registers_refusal`,
	//   `extended_state_refusal`); a `Write_Schedule` through 0 or a thread handle with a weight above
	//   the weight of the thread or a request above its request; a `Write_Schedule` with a weight above
	//   `WEIGHT_FULL`, a request above `REQUEST_LIMIT`, or a weight limit or a new-thread weight limit
	//   above `WEIGHT_FULL`, changes nothing; a `Write_Process_Schedule` with a new-thread weight limit
	//   above `WEIGHT_FULL` changes nothing; a `Write_Breakpoints` with a breakpoint that a thread cannot have
	//   (`thread_breakpoints_refusal`) changes nothing; a `Read_Memory` of more than
	//   `THREAD_MEMORY_READ_LIMIT` bytes; a `Write_Placement` that `thread_placement_after_write` refuses
	//   changes nothing: through 0 or a thread handle a set with a processor that the set of the thread
	//   does not have, and for each writer a set or a limit with no processor that the machine has;
	//   `Start_Counters` or `Read_Counters` on a machine whose processors have no counters that the
	//   kernel uses, with the error kind `Unsupported`.
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with the rights of the command, and not
	//   the machine handle with the rights of a command of the schedule or of the placement. The machine
	//   handle with another command gives `Bad_Handle`. A process handle with no **Debug** gives
	//   `No_Right`, and a process handle with a command of the schedule or of the placement `Bad_Handle`.
	//   A command of the schedule of a process, `Start_Counters` or `Read_Counters` with 0 or with a
	//   handle that is not the machine handle gives `Bad_Handle`; the machine handle with no
	//   **Counters** gives `No_Right` for `Start_Counters` and `Read_Counters`.
	// - `Bad_State`: no live process has the slot and the serial of `number`, for a command of the
	//   schedule of a process; no live thread of this process has `number`; no live thread of the machine has the
	//   machine number `number`; the thread or its process ended, also for a read or a write of a
	//   schedule or of a placement of a thread that ends; a read or
	//   a write of the registers or of the breakpoints of a thread that is not held, or of the calling
	//   thread; a `Stop` above
	//   `THREAD_STOP_COUNT_LIMIT` or of a thread that ends; a `Resume` at the count 0; through a process
	//   handle with **Debug**: the caller is not the debugger of the process, the process is the caller, or a
	//   `Resume` of a thread that the debugger did not stop; a `Read_Counters` of a thread that does not
	//   count.
	// - `Bad_Address`: `size` is too small, or the process cannot read or write the memory; a `Read_Memory`
	//   whose first byte the process of the thread cannot read, or whose range is not below `USER_END`.
	Guest_Run = 34, // (process, registers: Guest_Registers, processor) -> kind: Guest_Exit_Kind, a, b, c, next, exit code, exit information.
	// Runs one guest processor of a process on the calling thread, until an exit that the kernel does not
	// handle itself, and gives that exit ([a guest](docs/ARCHITECTURE.md#a-guest)). The process is a guest:
	// a process that `Process_Create` made and that no thread ran. Its addresses are the guest physical
	// addresses: `Memory_Map` with its handle gives the guest memory. The first run makes the process a
	// guest: the time page leaves it, the `OWN_LOG_PAGES` pages of its own log ring return to its budget (a
	// guest writes no log record), and `Process_Start` of it gives `Bad_State` after. The first run of each
	// guest processor takes two pages from the budget of the process. A guest processor starts in 16-bit
	// real mode, with each segment at base 0, unless the record asks for the load of another mode.
	//
	// A guest has up to `GUEST_PROCESSOR_CAPACITY` guest processors. One thread runs one guest processor at
	// a time; several threads of the caller run several guest processors of one guest at once. The record
	// can ask for one event to deliver at the entry (`Guest_Inject_Kind`). The kernel delivers an
	// `External_Interrupt` only when the guest takes interrupts: else it opens the interrupt window, and
	// the run ends with `Interrupt_Window` when the guest takes interrupts again.
	//
	// The kernel gives a page on first use of a mapping of the guest its frame when the guest touches it,
	// and enters the guest again: that exit does not end the operation. A page of a mapping made with
	// `Write`, `Execute` and `No_Access` is writable or executable, never both: a fault that asks it for the
	// other access switches that page, and does not end the operation either. The operation ends at each other
	// exit, with the exit in its results.
	//
	// **Arguments**
	//
	// - `process`: a process handle with **Control**, of a process in the state `Created`, with no thread,
	//   which is not the caller.
	// - `registers`: the address of a `Guest_Registers` record that the process can read and write. The
	//   kernel reads it before the entry, and writes the registers of the guest processor there after the
	//   exit. The process answers an exit by a change of the record before the next run.
	// - `processor`: the index of the guest processor, from 0 to `GUEST_PROCESSOR_CAPACITY - 1`.
	//
	// **Results**
	//
	// 1. the `Guest_Exit_Kind` of the exit;
	// 2. to 4. the values of the exit kind: `a`, `b` and `c` (`Guest_Exit_Kind` says what each one holds);
	// 5. the address of the instruction after the one that exited, for `Port_Write`, `Port_Read`, `Halt`
	//    and `Cpuid`, and for an exit `Other` of `rdmsr`, `wrmsr`, `rdtsc` or `rdtscp`; else 0;
	// 6. the exit code of the processor (the AMD manual, volume 2, appendix C): what an exit `Other` was;
	// 7. the first exit information of the processor.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: the processors of the machine have no virtualization support that the kernel uses
	//   (AMD SVM with nested paging), and the error kind is `Unsupported`; the record has a field that its
	//   rules refuse (`guest_registers_refusal`); or `processor` is past the last guest processor.
	// - `Bad_Handle`, `No_Right`: `process` is not a process handle with **Control**.
	// - `Bad_State`: the process is the caller, was started, stopped, or another thread runs this guest
	//   processor now.
	// - `Bad_Address`: the process cannot read and write the record.
	// - `No_Budget`: at the first run of the guest processor, the budget of the process cannot pay its two
	//   pages.
	//
	// ```odin
	// exit, status := system.guest_run(guest, &registers)
	// ```
	Log_Read = 35, // (memory, process, serial, after, records: Log_Record, count) -> copied, lost, total.
	// Copies the records of the own log ring of one process: the last `OWN_LOG_RECORD_CAPACITY` records
	// that the process wrote, which only its own records push out. The ring lives until the slot of the
	// process is free: after its stop, while a handle names it, it is still read. The log service reads
	// the [own records](term:own-records) of a caller with it, and the records of a process whose handle
	// a starter lends (src/md/features/own_log_ring.md). The kernel
	// copies whole records under the log lock, so no copy is torn, and gives them to the caller after
	// the lock. A guest has no own log ring after its first `Guest_Run`.
	//
	// **Arguments**
	//
	// - `memory`: a handle of the memory of the log (`ROOT_LOG_RECORDS`) with **Read**. Its holder reads
	//   each record of the whole log, so a copy of an own log ring gives it no new fact.
	// - `process`, `serial`: the process slot and the process serial of the process, as `Process_State`
	//   gives them.
	// - `after`: an own number (`Log_Record.own_number`), modulo 2^32: the first record to copy. An `after`
	//   past the count of the records of the process gives no record (`own_log_window`).
	// - `records`: the address of `count` records that the process can write.
	// - `count`: the records that fit at `records`, at most `OWN_LOG_RECORD_CAPACITY`.
	//
	// **Results**
	//
	// 1. the records copied, in the order of their own numbers;
	// 2. the own records from `after` that the ring no longer keeps: the process wrote more records after
	//    them than the ring holds;
	// 3. the records that the ring keeps from the first one copied to the last one: more than the first
	//    result when `count` is too small.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` is not a handle of the memory of the log with **Read**.
	// - `Bad_Operation`: `process` is 0 or past the process slots, or `count` is above
	//   `OWN_LOG_RECORD_CAPACITY`.
	// - `Bad_State`: the slot holds no process with this serial and an own log ring: the slot is free,
	//   another process has it, or the process is a guest.
	// - `Bad_Address`: the process cannot write the `count` records at `records`.
	//
	// ```odin
	// results, status := system.call(.Log_Read, u64(log_memory), slot, serial, after, u64(uintptr(&rows[0])), u64(len(rows)))
	// ```
	Memory_Read = 36, // (memory, offset, address, length) -> bytes copied.
	// Copies bytes of a memory object, named by its handle, into memory of this process, and gives a
	// status where a mapping would fault. A process that reads an object that another process gives (the
	// trusted display reads the difference of a plan, a palette table) cannot trust its pages: their
	// maker can make the object Uncommitted and leave pages with no frame, or revoke the handle while
	// the reader reads, and a read through a mapping then faults and stops the reader. The kernel copies
	// the range under the process lock of the caller: a revocation
	// takes that process lock, so it comes before the call or after it, and a page that is not
	// committed is a status. Each page of the range is checked under the lock of the object before the
	// first byte is copied, so the copy is whole or nothing; the copy itself runs with that lock free,
	// since no frame that the check saw can leave the object while the caller holds its process lock.
	//
	// **Arguments**
	//
	// - `memory`: a memory handle with **Read**. Device memory is refused: a read of a register can
	//   change the device.
	// - `offset`: the first byte to copy, from the start of the object.
	// - `address`, `length`: the bytes of this process that receive the copy; `length` at most
	//   `MEMORY_READ_LIMIT`, so one call holds each lock for a bounded time.
	//
	// **Results**: the bytes copied: `length`.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` is not a memory handle with **Read**.
	// - `Bad_Operation`: `length` is above `MEMORY_READ_LIMIT`, or the object is device memory.
	// - `Bad_Address`: the range passes the end of the object, the process cannot write the `length`
	//   bytes at `address`, or those bytes meet a mapping of the same object in this process.
	// - `Bad_State`: a page of the range is not committed (an Uncommitted object that the copy reaches
	//   past its committed pages), or is marked No_Access (`Memory_Protect` of a part of a mapping), as a
	//   mapping refuses it. The kernel checks each page of the range before it copies the first byte: a
	//   refusal writes nothing at `address`.
	//
	// ```odin
	// copied, status := system.memory_read(memory, 0, buffer[:])
	// ```
}

// The bytes of one Memory_Read: a read of a larger range is several calls.
MEMORY_READ_LIMIT :: 1 << 20

// memory_read_arguments_status is the check of the arguments of a
// Memory_Read that needs no page: Bad_Operation for a length past
// MEMORY_READ_LIMIT or device memory, Bad_Address for a range that passes
// the end of the object of object_pages pages. A length of 0 at any offset
// up to the end copies nothing and is Ok.
memory_read_arguments_status :: proc "contextless" (offset, length, object_pages: u64, device: bool) -> Status {
	if length > MEMORY_READ_LIMIT || device {
		return .Bad_Operation
	}
	if object_pages > max(u64) / PAGE_SIZE {
		return .Bad_Address
	}
	object_bytes := object_pages * PAGE_SIZE
	if offset > object_bytes || length > object_bytes - offset {
		return .Bad_Address
	}
	return .Ok
}

// memory_read_destination_meets says if the bytes that a Memory_Read writes
// meet a mapping of the object that it reads: the copy would write the
// pages that it reads. An empty range meets nothing.
memory_read_destination_meets :: proc "contextless" (address, length, mapping_address, mapping_bytes: u64) -> bool {
	if length == 0 || mapping_bytes == 0 {
		return false
	}
	return address < mapping_address + mapping_bytes && mapping_address < address + length
}

// The scheduling strategy of the machine (docs/SCHEDULING.md): the rule that
// orders the ready threads of each run queue. 0 is no strategy: a report of
// a kernel that has none.
//
// `Strategy_Set` changes it at run time, with the right **Schedule** of the
// machine; `System_Report.strategy` and `Processor_Report.strategy` show it.
// A change gives each thread the zero values of the new strategy: each
// thread starts equal (docs/SCHEDULING.md, "The change at run time").
// Each strategy ends a stint after the time slice of 10 ticks at most.
Strategy :: enum u32 {
	None        = 0, // No strategy: only in a report of a kernel that has none.
	Round_Robin = 1, // A queue in order, a time slice of 10 ms, no wake preemption. The reference: it reads no weight and no request.
	// Virtual time and weights: the least virtual time runs (the idea of CFS). A target latency of 6 ms divided by
	// weight, a least stint of 0.75 ms, a sleeper credit of 3 ms, and wake preemption with a granularity of 1 ms.
	Fair        = 2,
	// Earliest eligible virtual deadline first: weights for the share, the request for the delay. A thread is
	// eligible when it is owed time (its lag is not negative); of those, the earliest virtual deadline runs.
	Eevdf       = 3,
}

// The name of each strategy, for a report or a line of the log.
@(rodata)
STRATEGY_NAMES := [Strategy]string {
	.None        = "none",
	.Round_Robin = "round robin",
	.Fair        = "fair",
	.Eevdf       = "EEVDF",
}

// The weight of a thread created with the weight 0: the most. A weight is
// from 1 to 1024: a process can lower or split the share of its threads,
// never raise it above the default. 1024 keeps each product of the virtual
// time inside 64 bits (docs/SCHEDULING.md, "Integer arithmetic and the
// overflow argument").
WEIGHT_FULL :: 1024
REQUEST_DEFAULT :: 3000 // Microseconds: the request of a thread created with the request 0.
// Microseconds: the longest request, 100 ms. The bound keeps the lag bound of
// EEVDF (two requests) inside the overflow argument of the scheduler
// (docs/SCHEDULING.md, "Integer arithmetic and the overflow argument").
REQUEST_LIMIT :: 100_000

// The schedule of a thread: the two values that a process sets for the
// scheduling strategies. `Thread_Control` reads it (`Read_Schedule`) and
// writes it (`Write_Schedule`) while the thread lives, also while it runs;
// `Thread_Create` takes the same two values. See
// [thread schedule](term:thread-schedule) and (docs/SCHEDULING.md, "The
// schedule of a live thread").
//
// A read gives the values in use, never 0.
//
// Who writes decides what a write can do:
//
// - A write through 0 (a thread of the calling process) or through a thread
//   handle only **lowers**: a weight above the weight that the thread has
//   now, or a request above its request, gives `Bad_Operation`, and nothing
//   changes. 0 keeps the value that the thread has. `weight_limit` and
//   `new_thread_weight_limit` are not read.
// - A write through the machine handle with **Schedule** and **Inspect**
//   gives the four values, and it alone raises a weight or a request. 0 is
//   the default of each: `WEIGHT_FULL` for the limit, the limit for the
//   weight and for the new-thread weight limit, `REQUEST_DEFAULT` for the
//   request. A weight or a new-thread weight limit above the new limit
//   becomes the limit (`thread_schedule_after_machine_write`). A thread
//   whose weight was raised starts again as a new thread for its scheduling
//   strategy: what it owed and what it was owed are gone.
//
// The weight limit is the most that the weight of the thread can be. The
// new-thread weight limit is the weight limit that the thread gives to a
// thread that it creates, and to the first thread of a process that it
// starts (`thread_schedule_of_new_thread`). So a weight that the holder of
// **Schedule** lowered stays lowered, also in the new threads. The share
// policy of the process `scheduler` uses the second limit to bound the
// weight of a thread that no round of the policy saw ([new-thread weight
// limit](term:new-thread-weight-limit)).
//
// Example: `{weight = 256, request = 500}` gives the thread a quarter of the
// share of a thread of the full weight, and asks for stints of 500
// microseconds under EEVDF.
Thread_Schedule :: struct {
	weight:       u32, // From 1 to the weight limit of the thread. The share of the thread under the strategies that use weights. 0 in a write: the weight that the thread has, or the limit in a write through the machine handle.
	request:      u32, // Microseconds, from 1 to `REQUEST_LIMIT`. The delay that the thread asks for under EEVDF. 0 in a write: the request that the thread has, or `REQUEST_DEFAULT` in a write through the machine handle.
	weight_limit: u32, // From 1 to `WEIGHT_FULL`; 0 in a write is `WEIGHT_FULL`. Read from a write through the machine handle only.
	new_thread_weight_limit: u32, // From 1 to `weight_limit`: the weight limit of a thread that this thread creates. 0 in a write is the weight limit of the write. Read from a write through the machine handle only.
}
#assert(size_of(Thread_Schedule) == 16)

// thread_schedule_after_machine_write gives the schedule that a thread has
// after a write of `Write_Schedule` through the machine handle. 0 is the
// default of each value. A weight above the weight limit becomes the limit,
// and a new-thread weight limit too: a thread under a limit never gives a
// higher limit to a thread that it creates. The caller checked each value
// against the most of the contract: a weight, a weight limit or a
// new-thread weight limit above `WEIGHT_FULL` is refused, not cut.
thread_schedule_after_machine_write :: proc "contextless" (written: Thread_Schedule) -> Thread_Schedule {
	weight_limit := written.weight_limit == 0 ? u32(WEIGHT_FULL) : written.weight_limit
	return {
		weight = written.weight == 0 ? weight_limit : min(written.weight, weight_limit),
		request = written.request == 0 ? u32(REQUEST_DEFAULT) : written.request,
		weight_limit = weight_limit,
		new_thread_weight_limit = written.new_thread_weight_limit == 0 ? weight_limit : min(written.new_thread_weight_limit, weight_limit),
	}
}

// The schedule of a process: the value that bounds each creation by any
// thread of one process at once. Only the machine handle with **Schedule**
// and **Inspect** reads it (`Read_Process_Schedule`) and writes it
// (`Write_Process_Schedule`). A process created has the full value. The
// share policy of the process `scheduler` writes it before it reads the
// threads of a process: one write then bounds each thread that the
// process creates after it, also a thread that a thread created a moment
// before the write and that the policy never saw.
//
// Example: `{new_thread_weight_limit = 32}` gives each thread that the
// process creates after the write the weight 32 at most.
Process_Schedule :: struct {
	new_thread_weight_limit: u32, // From 1 to `WEIGHT_FULL`: a thread of the process creates no thread with a higher weight limit. 0 in a write is `WEIGHT_FULL`.
}
#assert(size_of(Process_Schedule) == 4)

// process_schedule_after_write gives the schedule that a process has after
// a write of `Write_Process_Schedule`, or what the write refuses: a value
// above `WEIGHT_FULL`, as for a weight limit (`Thread_Write_Refusal`
// `New_Thread_Weight_Limit`). 0 is `WEIGHT_FULL`.
process_schedule_after_write :: proc "contextless" (written: Process_Schedule) -> (after: Process_Schedule, refusal: Thread_Write_Refusal) {
	if written.new_thread_weight_limit > WEIGHT_FULL {
		return {}, .New_Thread_Weight_Limit
	}
	return {new_thread_weight_limit = written.new_thread_weight_limit == 0 ? WEIGHT_FULL : written.new_thread_weight_limit}, .None
}

// new_thread_weight_limit_of_creation gives the limit of a thread that a
// thread creates, or of the first thread of a process that it starts: the
// smaller of the new-thread weight limit of the creating thread and the one
// of its process. The value of the process closes every thread of the
// process in one write; the value of the thread keeps a limit that the
// holder wrote for one thread.
new_thread_weight_limit_of_creation :: proc "contextless" (thread_value, process_value: u32) -> u32 {
	return min(thread_value, process_value)
}

// process_slot_and_serial gives the `number` of the two commands of the
// schedule of a process: the slot of the process in the low 32 bits and
// its serial in the high 32 bits. The serial changes for each new process
// of a slot, so the number of a process that ended names no later one.
process_slot_and_serial :: proc "contextless" (slot, serial: u64) -> u64 {
	return (slot & 0xFFFF_FFFF) | (serial << 32)
}

// thread_schedule_of_new_thread gives the schedule of a thread that
// `Thread_Create` or `Process_Start` makes. `new_thread_weight_limit` is the
// limit of a new thread of the calling thread
// (`new_thread_weight_limit_of_creation`); `weight` and `request` are
// the values of the call, 0 for the defaults. The new thread gets that
// limit as its weight limit and as its own new-thread weight limit, so a
// thread that it creates gets it too. ok false: a value is above the most
// of the contract, or the weight is above that limit, and no thread is
// made.
thread_schedule_of_new_thread :: proc "contextless" (new_thread_weight_limit: u32, weight, request: u64) -> (schedule: Thread_Schedule, ok: bool) {
	if !thread_schedule_accepted(weight, request) || weight > u64(new_thread_weight_limit) {
		return {}, false
	}
	return {
			weight = weight == 0 ? new_thread_weight_limit : u32(weight),
			request = request == 0 ? u32(REQUEST_DEFAULT) : u32(request),
			weight_limit = new_thread_weight_limit,
			new_thread_weight_limit = new_thread_weight_limit,
		},
		true
}

// thread_schedule_accepted says if a weight and a request are values that a
// thread can have: `Thread_Create` and `Write_Schedule` refuse the others
// with `Bad_Operation`. 0 is accepted for each: the default. A weight above
// the full weight would raise the share of a thread above the share of a
// thread that asked for nothing. The kernel also refuses a weight above the
// weight limit of the thread, which this check does not know.
thread_schedule_accepted :: proc "contextless" (weight, request: u64) -> bool {
	return weight <= WEIGHT_FULL && request <= REQUEST_LIMIT
}

// The most processors that a set of processors names: one bit of a `u64`
// for each. The kernel runs threads on no more processors than this.
PLACEMENT_PROCESSOR_CAPACITY :: 64

// The placement of a thread: the processors that can run it, and the most
// that this set can be. `Thread_Control` reads it (`Read_Placement`) and
// writes it (`Write_Placement`) while the thread lives, also while it runs.
// See [thread placement](term:thread-placement) and (docs/SCHEDULING.md,
// "The placement of a thread").
//
// A set of processors is a `u64`: bit `n` is the processor `n` of
// `Processor_Report`. A read gives sets that hold only processors that the
// machine has, and that are never 0. A thread that never got a placement
// has every processor of the machine in both sets.
//
// Who writes decides what a write can do (`thread_placement_after_write`):
//
// - A write through 0 (a thread of the calling process) or through a thread
//   handle with **Control** only **narrows**: a set with a processor that
//   the set of the thread does not have gives `Bad_Operation`, and nothing
//   changes. 0 keeps the set that the thread has. `processors_limit` is not
//   read.
// - A write through the machine handle with **Schedule** and **Inspect**
//   gives the two sets, and it alone widens a set. 0 is the default of
//   each: every processor for the limit, the limit for the set. The part
//   of the set that is outside the new limit is dropped. As a write of a
//   `Thread_Schedule` through the machine handle, it always gives each
//   value: the set 0 is the whole limit, not the set that the thread has,
//   so it undoes a narrowing that the process of the thread made. A
//   holder that keeps the set reads the placement first and writes the
//   set that it read.
//
// For each writer, the bits of processors that the machine does not have
// are dropped, so a writer can give all ones. A set that then has no
// processor, and a set with no processor inside the limit, give
// `Bad_Operation`: a thread with no processor never runs, and that is
// `Stop`, which has its own right.
//
// The limit is the most that the set of the thread can be. A new thread,
// and the first thread of a process that a thread starts, get the limit
// of the thread that creates them, as their set and as their limit. So a
// limit that the holder of **Schedule** wrote stays.
//
// A thread whose processor left its set leaves that processor at the end
// of its stint at the latest: the write sends no interrupt.
//
// Example: `{processors = 0b0100}` keeps a thread on the processor 2.
Thread_Placement :: struct {
	processors:       u64, // Bit n: the processor n can run the thread. 0 in a write: the set that the thread has, or the limit in a write through the machine handle.
	processors_limit: u64, // The most that `processors` can be. 0 in a write is every processor. Read from a write through the machine handle only.
}
#assert(size_of(Thread_Placement) == 16)

// thread_placement_after_write gives the placement that a thread has after
// a write of `Write_Placement`, or what the write refuses. `written` is the
// record of the writer, `held` the placement that the thread has, and
// `machine_processors` the set of the processors that the machine has.
// `by_machine`: the machine handle names the thread; else the process of
// the thread or the holder of a thread handle writes.
//
// With a refusal, `after` is `held`, and `most` is the set that the
// refused set had to stay inside: the set of the thread for a write that
// only narrows, the limit for a set with no processor inside it, and the
// processors of the machine for a set or a limit that names none of them.
// The refused value is `written.processors`, or `written.processors_limit`
// for the refusal `Processors_Limit`.
//
// The kernel runs this procedure on its own copy of the record, under the
// lock that guards the placement of the thread.
thread_placement_after_write :: proc "contextless" (written, held: Thread_Placement, machine_processors: u64, by_machine: bool) -> (after: Thread_Placement, refusal: Thread_Write_Refusal, most: u64) {
	if !by_machine {
		if written.processors == 0 {
			return held, .None, 0
		}
		processors := written.processors & machine_processors
		if processors == 0 {
			return held, .Processors, machine_processors
		}
		if processors &~ held.processors != 0 {
			return held, .Processors, held.processors
		}
		return {processors = processors, processors_limit = held.processors_limit}, .None, 0
	}
	limit := machine_processors
	if written.processors_limit != 0 {
		limit = written.processors_limit & machine_processors
		if limit == 0 {
			return held, .Processors_Limit, machine_processors
		}
	}
	processors := limit
	if written.processors != 0 {
		processors = written.processors & machine_processors
		if processors == 0 {
			return held, .Processors, machine_processors
		}
		processors &= limit
		if processors == 0 {
			return held, .Processors, limit
		}
	}
	return {processors = processors, processors_limit = limit}, .None, 0
}



// What ended a run of a guest processor: the first result of `Guest_Run`.
// The comment of each member says what the results `a`, `b` and `c` hold.
// The fifth result is the address of the instruction after the one that
// exited, for the four kinds that name an instruction.
//
// Example: `out dx, al` with dx 0x80 and al 42 gives `Port_Write`, a 0x80,
// b 1, c 42.
Guest_Exit_Kind :: enum u64 {
	None          = 0, // Not an exit: a completion with a status that is not Ok.
	Port_Write    = 1, // `out`: a the port, b the size in bytes (1, 2 or 4), c the value.
	Port_Read     = 2, // `in`: a the port, b the size in bytes. The process writes the value in `rax` and the next instruction in `rip`.
	Halt          = 3, // `hlt`: the guest waits for an interrupt.
	Cpuid         = 4, // `cpuid`: the leaf is in `rax` and `rcx` of the record. The process writes the four answers and the next instruction.
	Memory        = 5, // An access to a guest physical address that no mapping allows: a the address, b the access (`Fault_Access`).
	Interrupted   = 6, // An interrupt of the machine ended the run, or its process stopped: nothing to answer. Run again.
	Shutdown      = 7, // The guest processor shut down: a fault while it delivered a double fault. Its state means nothing now.
	Refused_State = 8, // The processor refused the state of the guest processor: no instruction of the guest ran.
	Other         = 9, // Another instruction that the guest may not run alone: the exit code of the processor is the sixth result. `rdtsc` (0x6E) and `rdtscp` (0x87) are here: the process answers them from its own clock.
	// The guest opened its interrupt window: the record asked for an `External_Interrupt` while the guest
	// took no interrupt (its interrupt flag clear, or in its interrupt shadow), and the guest now takes one.
	// The request stays in the record: the next run delivers it.
	Interrupt_Window = 10,
	// An instruction writes the page of a switching mapping that holds it: `a` is the guest physical address
	// that it writes, `b` is 1 when the instruction is 64-bit code (its code segment has L, in long mode), else
	// 0. A page is never writable and executable at once, so the instruction never completes: the
	// process does the write for it through its own mapping of the memory and moves `rip` past it, or
	// stops the guest.
	Writes_Own_Page = 11,
}

// A module record: one module that a loader put in a process (Process_Module).
// The identity of a process that runs is the list of its module records: the
// hash of each module, and the hash that a replacement put it in place of.
//
// A loader writes it with `Process_Module`; the kernel keeps at most
// `PROCESS_MODULE_CAPACITY` for each process and gives them in a
// `Module_Report`, in a `Stop_Report` and in each `Stop_Frame`. The kernel
// does not check the hash: it is what the loader asserted. The kernel writes
// `writer`: a record of the writer `Starter` is a claim of the starter of
// the process, which the process cannot change; a record of the writer
// `Process` is a claim of the process. 88 bytes. See
// [module record](term:module-record).
//
// The writer is a word, not a member: a reader takes it from a report of
// the kernel through module_writer_of_word, and refuses a word that names
// no writer.
Module_Record :: struct {
	base:     u64, // The address of the first byte of the module in the process.
	size:     u64, // The bytes of addresses of the module. 0: no module.
	hash:     [32]u8, // The hash of the module that is loaded: BLAKE3 of its file, the name of the module in the module store.
	replaces: [32]u8, // Zero, or the hash that an import names and that a replacement changed to `hash`.
	writer:   u64, // Who wrote the record: the word of a Module_Writer. The kernel writes it; `Process_Module` does not read it.
}
#assert(size_of(Module_Record) == 88)

// Who wrote a module record (`Module_Record.writer`). The kernel knows it at
// each `Process_Module`: it compares the process of the record with the
// process that calls.
//
// Example: the root service starts `imports` and writes the record of its
// module: `Starter`. `imports` loads `agenda` in its own memory and writes
// its record: `Process`. `imports` cannot remove the first record, nor unmap
// or map at its addresses (`No_Right`).
Module_Writer :: enum u64 {
	Process = 0, // The process wrote the record for itself. It can replace or remove it.
	Starter = 1, // Another process wrote it, through the process handle with Control: the starter, or a process to which it gave that handle. The kernel writes the record of the root service so. The process cannot change it.
}

// The most bytes of the word of a writer: the field `writer` of a row of
// `inspect.modules()` and of `manual.running()` has this size.
MODULE_WRITER_NAME_CAPACITY :: 8

// module_writer_of_word reads the word of a writer. A word that names no
// writer is refused: a reader that took it for a writer would say who made
// a claim that no kernel marked.
module_writer_of_word :: proc "contextless" (word: u64) -> (writer: Module_Writer, ok: bool) {
	for member in Module_Writer {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// The word of each writer in a row of a table. The compiler checks that the
// array names each writer, so a new writer cannot have no word.
@(rodata)
MODULE_WRITER_NAMES := [Module_Writer]string {
	.Process = "process",
	.Starter = "starter",
}

// module_writer_name gives the word of a writer in a row of a table:
// "process" or "starter". Each word fits MODULE_WRITER_NAME_CAPACITY bytes.
// It takes a member that module_writer_of_word gave: there is no word for a
// writer that names nothing.
module_writer_name :: proc "contextless" (writer: Module_Writer) -> string {
	return MODULE_WRITER_NAMES[writer]
}

// The module records of one process: its own module, the modules that
// it imports and the modules that it loads while it runs. `Process_Module`
// gives `No_Slot` for one more.
PROCESS_MODULE_CAPACITY :: 16

// Where a process stopped on a fault (Process_State). Zero: the process
// runs, or it stopped with no fault.
//
// The kernel writes it when it stops a process on a fault; a holder of the
// process handle with **Read** gets it whole from `Process_State`, and a
// holder of the machine with **Inspect** gets it from `Inspect` with the kind
// `Stop`, with the values that can show memory of the process taken out.
// The console and the process `errors` turn it into a stack trace with names
// (see [stop report](term:stop-report)).
//
// Example: a null pointer read gives `cause = u32(Stop_Cause.Fault)`,
// `vector = 14`, `address = 0`, and `frames[0].address` the instruction.
Stop_Report :: struct {
	cause:       u32, // The word of the `Stop_Cause`: `Fault`, `Not_Committed` or `Cannot_Return`, which a reader takes through `stop_cause_of_word`. 0 in a report of another stop, which stays zero.
	vector:      u32, // The vector of the processor exception: a `Fault_Kind` when the kernel delivers that kind.
	instruction: u64, // The address of the instruction.
	address:     u64, // A page fault: the address that the instruction used. 0 for another fault.
	module:      Module_Record, // The module of the instruction, as the loader recorded it: the module that ran. Zero: no record.
	// The stack trace: frame 0 is the instruction, each next frame the
	// return address of a call, from the frame pointers of the thread.
	// At most `STOP_FRAME_CAPACITY`. The walk also stops at a frame
	// pointer that is 0, not aligned on 8, not readable, or not above the
	// one before it, and at a return address 0.
	frame_count: u64,
	frames:      [STOP_FRAME_CAPACITY]Stop_Frame,
	// Inspect_Kind.Stop only: the serial of the process of the slot, and the
	// values that the kernel took out (see Inspect_Kind.Stop).
	process_serial: u64,
	hidden_value_count: u64,
	// Optional typed error record attached to a Failed or Refused self-stop
	// through Process_Stop; zero for every other stop.
	error: errors.Error_Record,
}

// The frames of one stack trace in a `Stop_Report`. A deeper stack is cut
// at this count.
STOP_FRAME_CAPACITY :: 16

// One frame of a stack trace. A reader names it "module + offset": the
// offset is address - base. A return address is the instruction after
// the call.
//
// Example: `address = 0x0040_1234`, `base = 0x0040_0000` is the offset
// 0x1234 in the module of `hash`; the process `errors` finds the procedure
// there in the debug object of that module.
//
// A frame has no writer (`Module_Writer`). A reader that must know whether
// the module of a frame is a claim of the process matches `base` with the
// record of the same base in the `Module_Report` of the process, which
// carries the writer. `Stop_Report.module` carries the writer of the module
// of the instruction.
Stop_Frame :: struct {
	address: u64, // The instruction (frame 0) or a return address. All zero: the kernel hid a value that no module holds.
	base:    u64, // The base of the module record that holds the address. 0: no record holds it.
	hash:    [32]u8, // The hash of that module.
}

// The module records of one process, in the order of their addresses.
// `Inspect` with the kind `Modules` writes it, with the right **Inspect** of
// the machine. The developer tools name each address of a sample with it.
Module_Report :: struct {
	count:   u64, // The records in `modules`: at most `PROCESS_MODULE_CAPACITY`.
	modules: [PROCESS_MODULE_CAPACITY]Module_Record,
	process_serial: u64, // The serial of the process of the slot: a reader drops reports of two processes.
}

// A budget: what its holders can still create. No operation creates an
// object from nothing: Memory_Create, Process_Create and Thread_Create take
// a budget handle, and the budget pays.
//
// The record holds five amounts. Four of them are **amounts that move**:
// `Budget_Create` takes them from a budget for a new budget, and an object
// or a budget that ends gives them back. The log records of each second
// move too: a budget counts only the records of its own processes against
// what it holds, so a refusal tells a process nothing of what the others
// wrote. Processor time is a **limit for each period**.
//
// A limit is for a budget and for each budget that came from it: what a
// thread uses counts in its budget and in each budget above. A new budget
// cannot have a limit above the limit of the budget that it came from. With
// the limit 0 a budget has no time: its threads do not run. With no log
// records, Log gives No_Budget. The processor limit holds in each period of
// 100 ms, the log records in each second.
//
// The kernel gives one budget to the root service: all the free memory and
// all the slots. Budget_Create moves a part of a budget to a new budget.
// When an object ends, what it used returns to the budget that paid.
// When the last handle to a budget closes, what the budget holds returns to
// the budget that it came from, and that budget pays for its objects.
//
// The record travels in two directions: a process gives it to
// `Budget_Create` (through `system.budget_create`), and `Budget_Read` and
// `Process_Report.budget` give what a budget still holds. See
// [budget](term:budget) and [limit](term:limit).
//
// Example: `{pages = 4096, processes = 1, threads = 4, processor = 250_000,
// log_records = 100}` is 16 MiB, one process of four threads, a quarter of
// one processor, and 100 lines of log in each second.
Budget_Amounts :: struct {
	pages:       u64, // Moves. The pages of memory objects, of thread areas, of frame lists and of page tables.
	processes:    u64, // Moves. Process slots: one for each `Process_Create`.
	threads:     u64, // Moves. Thread slots: one for each thread that runs, the first one included.
	processor:   u64, // A limit. Microseconds of processor time in each second, on all the processors together: 1 000 000 is one full processor.
	log_records: u64, // Moves. Records on the log in each second; `Log` gives `No_Budget` above it.
}

// One word of a word wait: the address of 32 bits of memory, and the value
// that they hold while the thread waits.
//
// `Word_Wait` takes a table of them: the thread waits at the end of its
// kernel entry while each word holds its value, and wakes when `Word_Wake`
// names one of its words, or at its deadline. The kernel names a word by
// its page frame, so two processes that map one memory object wait on one
// word. See [word wait](term:word-wait).
Word :: struct {
	address: u64, // The address of the word in the process: a multiple of 4 that the process can read.
	value:   u64, // The low 32 bits.
}

// The words of the wait of one kernel entry, in all its `Word_Wait`
// commands. One more gives `No_Slot`.
WORD_WAIT_CAPACITY :: 64

// What the kernel tells a thread: the kernel adds 1 to the `events` word of
// the thread record and wakes the thread, when
//   an interrupt of the process arrives,
//   a process stops and this process holds its handle,
//   another thread of the process ends.
// The thread reads `events`, reads the state that it needs, then waits on
// the word with the value that it read first.

// What a thread can read about itself, at the address in its `gs` register.
// The kernel writes it when the thread starts. After that it only adds to `events`.
//
// The record is the first page of the thread area of the thread, at
// `THREAD_AREA_BASE + number * THREAD_AREA_PAGES * PAGE_SIZE`; the kernel ring
// of the thread follows it. The process can write the page, so the kernel
// reads back from it only `fault_read`, and treats that value as a claim
// (docs/ARCHITECTURE.md, "The fault ring"). At most one page
// (`#assert` below). See [thread record](term:thread-record).
//
// Example: `system.thread_record().number` is 0 in the first thread of a
// process, and the `events` word is the word that a thread waits on for an
// interrupt.
Thread_Record :: struct {
	self:      u64, // The address of this record. The kernel ring is PAGE_SIZE after it.
	parameter: u64, // The parameter of the entry of the thread.
	number:    u64, // The number of the thread in its process. The first thread is 0.
	events:    u32, // The kernel adds 1 for each event: see Word_Wait.
	processors: u32, // The processors that run threads: a thread that is alone on the machine does not spin. The kernel writes it when the thread starts.
	// The fault ring of the process, when this thread is its fault handler
	// (Fault_Handler_Set; docs/ARCHITECTURE.md, "The fault ring"). The kernel
	// writes fault_records[n % FAULT_RECORD_CAPACITY] for the record n, then
	// fault_written = n + 1, then wakes the threads that wait on
	// fault_written. The handler reads the records from fault_read to
	// fault_written and writes fault_read: a record is free again once
	// fault_read passed it. A fault that finds FAULT_RECORD_CAPACITY records
	// not read stops the process as a fault does with no handler, and the
	// kernel adds 1 to fault_full.
	fault_written: u32, // The kernel writes it: the count of fault records written since the handler was set.
	fault_read:    u32, // The handler writes it: the count of fault records that it read.
	fault_full:    u32, // The kernel writes it: the faults that found the ring full and stopped the process, since the process started.
	fault_reserved: u32, // Not read.
	fault_records: [FAULT_RECORD_CAPACITY]Fault_Record,
}
#assert(size_of(Thread_Record) <= PAGE_SIZE)

// The fault ring: one record for each fault that the kernel gave to the
// fault handler of a process in place of a stop. The thread of the record
// waits until a thread of the process answers (Fault_Answer).
//
// The capacity is the count of faults that can wait for an answer at once:
// a 17th fault stops the process. Sixteen records of 64 bytes fit in the
// thread record with its other fields.
FAULT_RECORD_CAPACITY :: 16

// One fault that the kernel gave to the fault handler of a process, in the
// fault ring of the thread record of the handler.
//
// The kernel writes it; the handler reads it, decides, and answers with
// `Fault_Answer` and the `serial`. The thread of the record waits until the
// answer. A handler that resolves a page fault on first use commits the page
// (`Memory_Commit`) or changes its protection (`Memory_Protect`), then
// answers `Resume`; a debugger reads the registers with `Thread_Control`.
// 64 bytes. See [fault record](term:fault-record) and
// (docs/ARCHITECTURE.md, "The fault ring").
//
// Example: a write to an uncommitted page at 0x1000_0000_2000 gives
// `kind = .Page_Fault`, `address = 0x1000_0000_2000`, `access = {.Write}`
// (2), and `error_code = 2`.
Fault_Record :: struct {
	thread:      u64, // The number of the thread in its process (Thread_Record.number).
	serial:      u64, // The serial of the fault: a count of the faults of this process that went to a ring (the first is 1). Fault_Answer names it, so an answer for an earlier fault, or for an ended thread whose number serves again, is refused.
	address:     u64, // A page fault: the address of the access. 0 for another kind.
	access:      u64, // A page fault: Fault_Access, what the access was. 0 for another kind.
	// The address where the thread continues after Resume. A fault: the
	// instruction that faulted, which runs again. A trap (Debug,
	// Breakpoint): the instruction after the one that trapped, so its
	// length is not known here: int3 (the byte CC) and int1 (the byte F1) are one byte, int 3
	// (CD 03) is two. A debugger that wrote CC subtracts 1. A Debug fault of
	// an execute breakpoint is the one Debug that is a fault: the
	// instruction of the breakpoint, which did not run.
	instruction: u64,
	kind:        u64, // The processor exception: the word of a Fault_Kind, read through fault_kind_of_word.
	// The error code that the processor gave with the exception, whole.
	// General_Protection: 0; a selector that the process loaded or named;
	// or (n << 3) | 2 for an `int n` whose gate a process cannot use (0x72
	// for int 14), which is never the exception n. Segment_Not_Present and
	// Stack_Fault: 0 or a selector. Page_Fault: the bits of the access.
	// Debug: the debug status, what made the exception
	// (`DEBUG_STATUS_STEP`, `DEBUG_STATUS_BREAKPOINTS`); 0 for int1. 0
	// for a kind with no error code.
	error_code:  u64,
	reserved:    u64, // 0.
}
#assert(size_of(Fault_Record) == 64)

// The kind of a fault: the processor exception, named by its vector. These
// are the kinds that the kernel delivers to a fault handler. A fault class
// says where the thread continues after Resume.
//   Fault: the instruction did not run; its address is in the frame, and it
//          runs again.
//   Trap:  the instruction ran; the frame holds the address of the next one.
Fault_Kind :: enum u64 {
	Divide_Error        = 0, // Fault. div or idiv by 0, or a quotient too large.
	Debug               = 1, // Trap: the trap flag after an instruction, int1, or a data breakpoint after the access. Fault: an execute breakpoint, before its instruction. The error code of the record is the debug status.
	Breakpoint          = 3, // Trap. int3.
	Invalid_Opcode      = 6, // Fault. ud2, or an instruction that this processor does not have.
	Segment_Not_Present = 11, // Fault. A load of a segment register with a selector whose descriptor is not present.
	Stack_Fault         = 12, // Fault. A stack access at an address that is not canonical.
	General_Protection  = 13, // Fault. A privileged instruction, an address that is not canonical, a bad selector, `int n` for a vector other than 3; sgdt, sidt, sldt, smsw and str when the processor has UMIP.
	Page_Fault          = 14, // Fault. An access that the page table refuses.
	X87_Floating_Point  = 16, // Fault. An unmasked exception of the x87 unit, at the next x87 instruction (the kernel sets CR0.NE on each processor).
	Alignment_Check     = 17, // Fault. An access that is not aligned, with the flag AC set (the kernel sets CR0.AM on each processor).
	Simd_Floating_Point = 19, // Fault. An unmasked exception of an SSE or AVX instruction.
}

// fault_kind_of_word is the border of the kind of a fault record
// (Fault_Record.kind): the member, or false for a word that names no kind.
// The record is in memory that the handler can write, so its reader never
// takes the word for a kind that the kernel did not give.
fault_kind_of_word :: proc "contextless" (word: u64) -> (kind: Fault_Kind, ok: bool) {
	for member in Fault_Kind {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}
// A set of fault kinds, by their vectors: the form of the argument of
// `Fault_Handler_Set` (`fault_kinds_of_argument`).
Fault_Kinds :: bit_set[Fault_Kind; u64]

// The vectors of the kinds above: the kinds that Fault_Handler_Set takes.
// The kernel never delivers the other vectors: the non-maskable interrupt
// (2), the double fault (8) and the machine check (18) are not faults of an
// instruction of a thread; overflow (4) and bound (5) are invalid
// instructions in 64-bit mode, which give Invalid_Opcode; device not
// available (7) and invalid task state (10) are mistakes of the kernel, which
// keeps the extended state and the task state of each processor; the other
// vectors below 32 are reserved or for modes that the kernel does not use.
FAULT_KINDS_DELIVERED :: u64(1 << 0 | 1 << 1 | 1 << 3 | 1 << 6 | 1 << 11 | 1 << 12 | 1 << 13 | 1 << 14 | 1 << 16 | 1 << 17 | 1 << 19)
// The kinds whose class is Trap.
FAULT_KINDS_TRAPS :: u64(1 << 1 | 1 << 3)
// The kinds that the debugger of a process takes (Fault_Handler_Set with a
// process handle): Debug and Breakpoint. Each other fault of the process
// stays with the process: its own fault handler, or its stop.
FAULT_KINDS_DEBUGGER :: FAULT_KINDS_TRAPS

// The debug status: the error code of a fault record of the kind Debug. It
// says what made the debug exception, from the status register of the
// processor (DR6), which the kernel reads and clears at each exception. 0:
// an `int1` of the process.
//
// Example: a thread that reaches the address of its breakpoint 2 gives a
// record with `kind = .Debug`, `error_code = 4` and the address in
// `instruction`.
DEBUG_STATUS_BREAKPOINTS :: u64(0b1111) // Bit n: the breakpoint n of the thread (Thread_Breakpoints) was reached.
DEBUG_STATUS_STEP :: u64(1) << 14 // One instruction ran with the trap flag set: a single step.
// The kinds after which Resume is accepted by itself: a trap continues after
// its instruction, and a handler changes what a page fault finds with
// Memory_Commit and Memory_Protect. Each other fault would run the same
// instruction on the same registers, and fault again with no end: after it,
// Resume is accepted only when Thread_Control wrote the registers or the
// extended state of the thread since the fault (the handler moved the
// instruction address, or changed the value that faulted).
FAULT_KINDS_RESUMABLE :: FAULT_KINDS_TRAPS | u64(1) << 14

// The class of a vector of the processor (fault_kind_class): Fault and Trap
// as above; a vector that is not a Fault_Kind is never delivered.
Fault_Class :: enum u8 {
	Never_Delivered = 0, // The kernel never gives this vector to a fault handler: it stops the process, or it is not a fault of a thread.
	Fault           = 1, // The instruction did not run: after Resume it runs again.
	Trap            = 2, // The instruction ran: after Resume the thread continues at the next one.
}

// fault_kind_class gives the class of a vector of the processor.
fault_kind_class :: proc "contextless" (vector: u64) -> Fault_Class {
	if vector >= 64 || FAULT_KINDS_DELIVERED & (u64(1) << vector) == 0 {
		return .Never_Delivered
	}
	if FAULT_KINDS_TRAPS & (u64(1) << vector) != 0 {
		return .Trap
	}
	return .Fault
}

// fault_kind_resumes says if Fault_Answer accepts Resume for a fault of a
// vector with no write of the registers of the thread.
fault_kind_resumes :: proc "contextless" (vector: u64) -> bool {
	return vector < 64 && FAULT_KINDS_RESUMABLE & (u64(1) << vector) != 0
}

// fault_kinds_of_argument gives the kinds that the argument of
// Fault_Handler_Set names, as a mask of vectors: 0 is page faults only, so
// that a handler of pages never gets a kind that it does not know. ok is
// false for a kind that the kernel never delivers.
fault_kinds_of_argument :: proc "contextless" (argument: u64) -> (mask: u64, ok: bool) {
	if argument & ~FAULT_KINDS_DELIVERED != 0 {
		return 0, false
	}
	if argument == 0 {
		return u64(1) << u64(Fault_Kind.Page_Fault), true
	}
	return argument, true
}

// fault_kinds_of_debugger_argument gives the kinds that the argument of
// Fault_Handler_Set names for a debugger, as a mask of vectors: always
// each kind of FAULT_KINDS_DEBUGGER. The argument is 0 or that whole set;
// ok is false for any other. A debugger that took one of the two kinds
// would leave the other to the process: a breakpoint that the debugger
// set would then stop the process.
fault_kinds_of_debugger_argument :: proc "contextless" (argument: u64) -> (mask: u64, ok: bool) {
	if argument != 0 && argument != FAULT_KINDS_DEBUGGER {
		return 0, false
	}
	return FAULT_KINDS_DEBUGGER, true
}

// What `Fault_Handler_Set` does, in its argument `end`. Its word crosses
// the command record, so each value is explicit.
Fault_Handler_Action :: enum u64 {
	Set = 0, // The thread becomes the fault handler of the process, or the debug handler of the process of `process`.
	End = 1, // The delivery ends: each fault stops the process again. With `process`: the debugging ends (the detach).
}

// What a faulting access was: the bits of the error code of the processor.
Fault_Access_Bit :: enum u64 {
	Present = 0, // The page has a translation: the access was not permitted. Without it: the page has no frame (not committed, or no mapping).
	Write   = 1, // The access was a write. Without it: a read, or an instruction fetch.
	Execute = 4, // The access was an instruction fetch.
}
// What a faulting access was, as the bits of the error code of a page fault:
// `Fault_Record.access`.
Fault_Access :: bit_set[Fault_Access_Bit; u64]

// The answer for a thread that waits in the fault ring.
//
// A thread of the process gives it to `Fault_Answer` with the serial of the
// fault record. A kind that is not `Resume` or `Stop` is refused.
Fault_Answer_Kind :: enum u64 {
	None   = 0, // No answer: refused.
	Resume = 1, // The thread continues with its registers: at the instruction of its record (the faulting instruction again, or the next one after a trap), or where Thread_Control wrote. For a kind of FAULT_KINDS_RESUMABLE, or after a write of Thread_Control.
	Stop   = 2, // The process stops as if no handler were set: the stop cause and the stop report of the fault.
}

// What Thread_Control does. The results are in the completion record.
//
// Each command of the registers and of the stop count needs **Inspect** on
// the thread handle, and a write of the registers
// and a read of the memory need **Write** too
// (`thread_control_rights`). A write of the breakpoints takes only the
// process handle with **Debug** of the debugger. A read or a write of the
// registers or of the breakpoints needs the thread held: its stop count
// above 0 and its processor
// left (`Bad_State` before). The two commands of the schedule, the two of
// the placement and the read of the memory need no hold. The three
// commands of the thread counters act on the calling thread: a start and a
// read through the machine handle with Counters, a stop with no handle.
// See [thread control](term:thread-control) and
// (docs/ARCHITECTURE.md, "The control of a thread").
Thread_Control_Command :: enum u64 {
	None                 = 0, // Refused.
	// Adds 1 to the stop count -> the count. When the operation returns, the
	// thread runs no instruction until its count is 0 again: a thread on
	// another processor left it; a thread in a wait stays in it, and does
	// not run when it ends. The calling thread itself stops after its kernel
	// entry. At most THREAD_STOP_COUNT_LIMIT (Bad_State above).
	// One case returns earlier: when the calling thread is itself held (it
	// stopped itself earlier in the same entry, or another thread stopped
	// it), the operation does not wait for a thread on another processor to
	// leave it, so that two threads that stop each other do not wait for
	// each other. That thread then leaves its processor at the interrupt
	// that the stop sent, and a read of its registers gets Bad_State until
	// it left.
	Stop                 = 1,
	// Takes 1 from the stop count -> the count. Bad_State at 0. At 0, a
	// thread whose wait ended runs again. The debugger of the process
	// takes back only the stops that it made, and the other callers only
	// the stops that the debugger did not make: Bad_State when the caller
	// has no stop of its own on the thread.
	Resume               = 2,
	// Writes a Thread_Registers at the address (size: at least its size) ->
	// the bytes written.
	Read_Registers       = 3,
	// Reads a Thread_Registers at the address (size: at least its size): the
	// thread continues with these registers. Bad_Operation for values that
	// a thread cannot hold (thread_registers_refusal): nothing changes.
	Write_Registers      = 4,
	// Writes the extended state area of the thread at the address (size: at
	// least the bytes of the area, Thread_State) -> the bytes written, the
	// components. The layout is the one of the processor: the standard form
	// of xsave, with the offset of each component from CPUID leaf 0xD; or
	// the 512 bytes of fxsave on a processor with no xsave.
	Read_Extended_State  = 5,
	// Reads the extended state area at the address: the thread continues
	// with it. Bad_Operation for an area that the processor would refuse
	// (extended_state_refusal): nothing changes.
	Write_Extended_State = 6,
	// Writes the Thread_Schedule of the thread at the address (size: at
	// least its size) -> the bytes written. The values are the ones in use:
	// never 0. The thread is not held. A thread handle needs Inspect; the
	// machine handle with Schedule and Inspect names any thread by its
	// machine number.
	Read_Schedule        = 7,
	// Reads a Thread_Schedule at the address: the thread has this weight and
	// this request from now on, also while it runs. Through 0 or a thread
	// handle (with Control) the write only lowers: Bad_Operation for a
	// weight above the weight of the thread or a request above its request,
	// and nothing changes; 0 keeps a value. The machine handle with Schedule
	// and Inspect names any thread by its machine number; its write gives
	// the four values, raises too, and sets the weight limit and the
	// new-thread weight limit: a weight above the new limit becomes the
	// limit (thread_schedule_after_machine_write). A raised weight starts the
	// thread again as a new thread for its strategy.
	Write_Schedule       = 8,
	// Writes the Thread_Breakpoints of the thread at the address (size: at
	// least its size) -> the bytes written. The thread is held.
	Read_Breakpoints     = 9,
	// Reads a Thread_Breakpoints at the address: the thread has these
	// breakpoints from now on, and no other. The thread is held. Only
	// through the process handle with Debug, from the debugger of the
	// process (thread_control_needs_the_debugger): Bad_Handle with 0 or a
	// thread handle.
	// Bad_Operation for a breakpoint that a thread cannot have
	// (thread_breakpoints_refusal): nothing changes. A reached breakpoint is
	// a fault of the kind Debug of the thread.
	Write_Breakpoints    = 10,
	// Copies `size` bytes (at most THREAD_MEMORY_READ_LIMIT) from the
	// address `source` of the process of the thread to the address -> the
	// bytes copied. The thread is not held. The copy reads only pages that
	// the process maps, that it can read and that have a frame: no read
	// gives a frame to a page. It stops before the first page that is not
	// so, and gives the count before it; Bad_Address when that page holds
	// the first byte. Device memory is never read.
	Read_Memory          = 11,
	// Writes the Thread_Placement of the thread at the address (size: at
	// least its size) -> the bytes written. Each set holds only processors
	// that the machine has, and is never 0. The thread is not held. A
	// thread handle needs Inspect; the machine handle with Schedule and
	// Inspect names any thread by its machine number.
	Read_Placement       = 12,
	// Reads a Thread_Placement at the address: only the processors of the
	// set run the thread from now on, also when it runs now: it then
	// leaves a processor that is not in the set at the end of its stint at
	// the latest. Through 0 or a thread handle (with Control) the write
	// only narrows: Bad_Operation for a set with a processor that the set
	// of the thread does not have, and nothing changes; 0 keeps the set.
	// The machine handle with Schedule and Inspect names any thread by its
	// machine number; its write gives the set and the limit, and widens
	// too. Bad_Operation for a set or a limit with no processor that the
	// machine has, and for a set with no processor inside the limit
	// (thread_placement_after_write): nothing changes.
	Write_Placement      = 13,
	// Writes the Process_Schedule of a process at the address (size: at
	// least its size) -> the bytes written. Only the machine handle with
	// Schedule and Inspect; `number` names the process by its slot and its
	// serial (process_slot_and_serial). The value in use: never 0.
	Read_Process_Schedule = 14,
	// Reads a Process_Schedule at the address: each thread of the process
	// creates its threads under it from now on (the creations that come
	// after the write in the order of the kernel). Only the machine handle
	// with Schedule and Inspect. Bad_Operation for a value above
	// WEIGHT_FULL (process_schedule_after_write): nothing changes.
	Write_Process_Schedule = 15,
	// The calling thread counts the four events of Thread_Counters from 0,
	// from now on, in user mode only -> nothing. A thread that counts starts
	// again from 0. Only the machine handle with Counters; `number` is not
	// read (thread_control_counts_the_caller). Read_Counters takes the same
	// handle.
	Start_Counters       = 16,
	// Writes the Thread_Counters of the calling thread at the address (size:
	// at least its size) -> the bytes written. The thread goes on counting.
	// Bad_State when the thread does not count.
	Read_Counters        = 17,
	// The calling thread stops counting -> nothing. A thread that does not
	// count is left as it is. It needs no handle and no right, and gives Ok
	// on each machine: it only takes a capability away, so a thread whose
	// right was revoked can still stop.
	Stop_Counters        = 18,
	// Starts recording process inputs of the target process (handle in
	// `thread` with Debug) into the contiguous memory object named by the
	// handle in `number` (with Read and Write) -> nothing. The target must
	// be in state Created, hold no device or shared writable mapping, and
	// not already be recorded or replayed.
	Record_Start         = 19,
	// Ends recording or replay of the target process (handle in `thread`
	// with Debug), writes the end record into the input history, and
	// restores any point copies -> nothing.
	Record_End           = 20,
	// Starts replaying the target process (handle in `thread` with Debug)
	// from the input history in the contiguous memory object named by the
	// handle in `number` (with Read and Write) -> nothing. The target must
	// be in state Created and not already be recorded or replayed.
	Replay_Start         = 21,
}

// thread_control_records_a_process says if a command of Thread_Control
// controls record or replay of a process: it takes the process handle with
// the right Debug (and for Record_Start / Replay_Start, the memory handle of
// the contiguous input history in `number`).
thread_control_records_a_process :: proc "contextless" (command: Thread_Control_Command) -> bool {
	return command == .Record_Start || command == .Record_End || command == .Replay_Start
}

// thread_control_counts_the_caller says if a command of Thread_Control is a
// command of the thread counters: it acts on the calling thread, and takes
// only the machine handle with the right Counters (THREAD_COUNTERS_RIGHTS),
// but Stop_Counters, which reads no handle.
// The counts of a thread that runs are in the registers of its processor,
// and the calling thread runs on the processor of its kernel entry: the
// kernel reads them there with no hold and no interrupt to another
// processor.
thread_control_counts_the_caller :: proc "contextless" (command: Thread_Control_Command) -> bool {
	return command == .Start_Counters || command == .Read_Counters || command == .Stop_Counters
}

// The rights of the machine handle that the commands of the thread counters
// need.
THREAD_COUNTERS_RIGHTS :: Rights{.Counters}

// The counts of the events of the processor for the code of one thread, in
// user mode only, since its last Start_Counters (Read_Counters). 32 bytes.
// The order of the fields is the order of the general counters 0 to 3.
//
// The cache misses are the misses of one level of one vendor: the last level
// cache on Intel, the L2 cache on AMD. Compare two counts on one machine,
// not two machines. See [thread counters](term:thread-counters) and
// (docs/ARCHITECTURE.md, "The counters of a thread").
//
// Example: a loop of 1 000 000 turns of 3 instructions each gives
// `instructions_retired` of at least 3 000 000.
Thread_Counters :: struct {
	instructions_retired: u64,
	cycles:               u64, // Cycles of the processor while it runs the thread, not halted.
	cache_misses:         u64,
	branch_misses:        u64, // Branches mispredicted, retired.
}
#assert(size_of(Thread_Counters) == 32)

// thread_control_names_a_process says if a command of Thread_Control names
// a process, by its slot and its serial, in place of a thread: the two
// commands of the schedule of a process. Only the machine handle takes
// them (thread_control_machine_rights).
thread_control_names_a_process :: proc "contextless" (command: Thread_Control_Command) -> bool {
	return command == .Read_Process_Schedule || command == .Write_Process_Schedule
}

// thread_control_rights gives the rights that a thread handle needs for a
// command of Thread_Control: Inspect for a hold and for each read, and Write
// too for a write of the registers. A write of the registers lets its
// holder choose the code that the process of the
// thread runs, so it has its own right; a hold and a read do not, so a
// profiler gets them with no write. A writer also reads the frame before it
// writes it. Control, the right to end a thread, gives none of them. It
// gives the write of the schedule, which only lowers: a holder that can end
// a thread can also give it a smaller share, which is less. A write of the
// breakpoints takes no thread handle and no number of an own thread
// (thread_control_needs_the_debugger). A read of the memory of the process
// needs Write too: a handle with Inspect alone sees how the thread runs,
// and never the bytes that its process holds. Control also gives the write
// of the placement, which only narrows: a holder that can end a thread can
// also give it fewer processors, which is less.
//
// The switch names each command, so that a new command gets no rights by a
// default: its author chooses them.
thread_control_rights :: proc "contextless" (command: Thread_Control_Command) -> Rights {
	switch command {
	case .Write_Registers, .Write_Extended_State, .Read_Memory:
		return {.Inspect, .Write}
	case .Write_Schedule, .Write_Placement:
		return {.Control}
	case .None, .Stop, .Resume, .Read_Registers, .Read_Extended_State, .Read_Schedule, .Read_Breakpoints, .Write_Breakpoints, .Read_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Start_Counters, .Read_Counters, .Stop_Counters, .Record_Start, .Record_End, .Replay_Start:
		return {.Inspect}
	}
	// Only a cast that skipped the border of the command reaches this line:
	// every right, with the bits of no right, which no handle holds. The
	// result is a requirement, never a grant: a caller that used it as the
	// rights of a handle or as a mask would give every right.
	return transmute(Rights)max(u32)
}

// thread_control_machine_rights says if a command of Thread_Control also
// takes the machine handle, with a machine number in place of a thread
// handle, and gives the rights that the machine handle then needs. The two
// commands of the schedule and the two of the placement only, each with
// Schedule and Inspect. A read by
// machine number is a report of the machine, and each report needs
// Inspect: it gives values of any thread, and says which machine numbers
// name a thread. A write through the machine handle gives the four values
// of the record, also the two limits: its holder reads the schedule
// first to keep what it does not change, and it gets the machine numbers
// from a report. So Schedule with no Inspect names no thread. A write of a
// placement through the machine handle gives the set and the limit, for
// the same reason. The two commands of the schedule of a process take the
// machine handle only, with the same rights: a read of any process is a
// report of the machine.
thread_control_machine_rights :: proc "contextless" (command: Thread_Control_Command) -> (rights: Rights, taken: bool) {
	switch command {
	case .Read_Schedule, .Write_Schedule, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule:
		return {.Schedule, .Inspect}, true
	case .None, .Stop, .Resume, .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State, .Read_Breakpoints, .Write_Breakpoints, .Read_Memory, .Start_Counters, .Read_Counters, .Stop_Counters, .Record_Start, .Record_End, .Replay_Start:
		return {}, false
	}
	// Only a cast that skipped the border of the command reaches this line.
	return {}, false
}

// thread_control_takes_debug_handle says if a command of Thread_Control
// also takes the process handle with Debug of the process that the caller
// debugs, with the number of a thread of that process in place of a thread
// handle: each command but the two of the schedule, the two of the
// placement and the three of the thread counters. A debugger holds, reads
// and writes a thread; the share of a thread and its processors are not a
// part of debugging, and the thread counters are of the calling thread.
thread_control_takes_debug_handle :: proc "contextless" (command: Thread_Control_Command) -> bool {
	switch command {
	case .None, .Read_Schedule, .Write_Schedule, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Start_Counters, .Read_Counters, .Stop_Counters:
		return false
	case .Stop, .Resume, .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State, .Read_Breakpoints, .Write_Breakpoints, .Read_Memory, .Record_Start, .Record_End, .Replay_Start:
		return true
	}
	// Only a cast that skipped the border of the command reaches this line.
	return false
}

// thread_control_needs_the_debugger says if a command of Thread_Control
// takes only the process handle with Debug, from the debugger of the
// process of the thread: the write of the breakpoints. A process has no
// use for a breakpoint on itself, and a breakpoint that a process could
// set on its own threads would let each process put a debug exception at
// the place where the kernel copies its memory. With 0 or a thread handle
// the command gives Bad_Handle.
thread_control_needs_the_debugger :: proc "contextless" (command: Thread_Control_Command) -> bool {
	return command == .Write_Breakpoints
}

// The most bytes of one `Read_Memory` of `Thread_Control`: one page.
THREAD_MEMORY_READ_LIMIT :: 4096

// The breakpoints of one thread: the four debug address registers of the
// processor.
THREAD_BREAKPOINT_CAPACITY :: 4

// What a breakpoint of a thread stops on.
Thread_Breakpoint_Kind :: enum u32 {
	None          = 0, // No breakpoint in this place.
	Execute       = 1, // The thread reaches the instruction at the address: a Debug fault before the instruction runs.
	Write         = 2, // The thread writes a byte of the range: a Debug trap after the instruction.
	Read_Or_Write = 3, // The thread reads or writes a byte of the range: a Debug trap after the instruction.
}

// One breakpoint of a thread: an address of its process, and what stops
// there. 16 bytes.
//
// Example: `{address = 0x40_1000, kind = .Execute}` stops the thread before
// the instruction at 0x40_1000; `{address = 0x7FFF_0010, kind = .Write,
// length = 8}` stops it after a write to one of the 8 bytes from that
// address.
Thread_Breakpoint :: struct {
	address: u64, // Below USER_END: an address of a process, never of the kernel. A data breakpoint: a multiple of `length`.
	kind:    Thread_Breakpoint_Kind,
	length:  u32, // A data breakpoint: 1, 2, 4 or 8 bytes. Execute and None: 0.
}
#assert(size_of(Thread_Breakpoint) == 16)

// The breakpoints of one thread, as `Read_Breakpoints` and
// `Write_Breakpoints` of `Thread_Control` give and take them. The place of
// a breakpoint is its number in the debug status of a fault record
// (`DEBUG_STATUS_BREAKPOINTS`). A breakpoint is of one thread: no other
// thread and no other process stops on it. A written image is hostile
// input to the kernel: it must pass `thread_breakpoints_refusal`. 64 bytes.
// See [breakpoint](term:breakpoint).
Thread_Breakpoints :: struct {
	breakpoints: [THREAD_BREAKPOINT_CAPACITY]Thread_Breakpoint,
}
#assert(size_of(Thread_Breakpoints) == 64)

// thread_breakpoints_refusal says what a write of the breakpoints of a
// thread refuses, and the value that it refuses: a kind that does not
// exist, a length that the kind cannot have, an address that is not an
// address of a process or that is not a multiple of the length. With these
// checks no breakpoint is ever at an address of the kernel.
thread_breakpoints_refusal :: proc "contextless" (breakpoints: ^Thread_Breakpoints) -> (refusal: Thread_Write_Refusal, value: u64) {
	for breakpoint in breakpoints.breakpoints {
		length := u64(breakpoint.length)
		switch breakpoint.kind {
		case .None:
			if length != 0 {
				return .Breakpoint_Length, length
			}
			if breakpoint.address != 0 {
				return .Breakpoint_Address, breakpoint.address
			}
		case .Execute:
			if length != 0 {
				return .Breakpoint_Length, length
			}
			if breakpoint.address >= USER_END {
				return .Breakpoint_Address, breakpoint.address
			}
		case .Write, .Read_Or_Write:
			if length != 1 && length != 2 && length != 4 && length != 8 {
				return .Breakpoint_Length, length
			}
			if breakpoint.address >= USER_END || breakpoint.address & (length - 1) != 0 || length > USER_END - breakpoint.address {
				return .Breakpoint_Address, breakpoint.address
			}
		case:
			return .Breakpoint_Kind, u64(breakpoint.kind)
		}
	}
	return .None, 0
}

// The bits of the debug control register of the processor (DR7) that the
// kernel writes for a thread: bit 10, which the processor always reads as
// 1; the local enable bit of each breakpoint (bit 2n); and for each
// breakpoint the two bits of its kind and the two bits of its length, from
// bit 16 + 4n. Never a global enable bit, never the exact bits and never
// the general detect bit.
DEBUG_CONTROL_NO_BREAKPOINT :: u64(0x400)

// thread_breakpoints_control gives the value of the debug control register
// (DR7) for the breakpoints of a thread, which passed
// thread_breakpoints_refusal: DEBUG_CONTROL_NO_BREAKPOINT with no
// breakpoint.
thread_breakpoints_control :: proc "contextless" (breakpoints: ^Thread_Breakpoints) -> (control: u64) {
	control = DEBUG_CONTROL_NO_BREAKPOINT
	for breakpoint, place in breakpoints.breakpoints {
		kind_bits, length_bits: u64
		switch breakpoint.kind {
		case .None:
			continue
		case .Execute:
			kind_bits = 0b00
		case .Write:
			kind_bits = 0b01
		case .Read_Or_Write:
			kind_bits = 0b11
		}
		// The length field of the processor: 1 byte is 00, 2 bytes 01,
		// 8 bytes 10, 4 bytes 11. An execute breakpoint has 00.
		switch breakpoint.length {
		case 2:
			length_bits = 0b01
		case 8:
			length_bits = 0b10
		case 4:
			length_bits = 0b11
		}
		control |= u64(1) << (2 * u64(place))
		control |= (kind_bits | length_bits << 2) << (16 + 4 * u64(place))
	}
	return control
}

// The highest stop count of a thread: `Thread_Control` `Stop` gives
// `Bad_State` above it.
THREAD_STOP_COUNT_LIMIT :: 1 << 16

// The general registers, the instruction address and the flags of a thread
// that Thread_Control holds. The names are the names of the registers of
// the processor.
//
// `Read_Registers` writes it into memory of the caller; `Write_Registers`
// reads it from there. A written image is hostile input to the kernel: it
// must pass `thread_registers_refusal`, so that the return of the processor
// to the thread never faults in the kernel. 176 bytes. See
// [register image](term:register-image).
//
// Example: a debugger that wrote `int3` (the byte CC) at a breakpoint reads
// the registers after the trap, subtracts 1 from `rip`, writes them back,
// and answers `Resume`.
Thread_Registers :: struct {
	// The general registers. `rsp` is the stack address: a write refuses an address that is not canonical.
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rbp, rsp: u64,
	r8, r9, r10, r11:   u64,
	r12, r13, r14, r15: u64,
	rip:    u64, // The address of the next instruction of the thread: below USER_END.
	rflags: u64, // THREAD_FLAGS_REQUIRED set, and no bit outside THREAD_FLAGS_ALLOWED.
	cs:     u64, // THREAD_CODE_SELECTOR: the one code selector of a process.
	ss:     u64, // THREAD_STACK_SELECTOR: the one stack selector of a process.
	// Read only, 1: the last entry of the thread into the kernel was a
	// syscall that has not returned yet: the thread waits in it, or its
	// processor left it after the operations of the entry and before the
	// return (its time slice ended, or a stop held it). At that return, rax
	// is the time, as after each kernel entry (the line at the top of this
	// file): a write of rax is lost; rcx and r11 hold what the syscall
	// instruction left there. 0: the thread left at an interrupt or a fault
	// of its own code, and each register is its own.
	in_kernel_entry: u64,
	reserved:        u64, // Not read.
}
#assert(size_of(Thread_Registers) == 176)

// The selector of the code segment of each thread of a process: the 64-bit
// code segment of privilege 3 of the kernel.
THREAD_CODE_SELECTOR :: 0x23
// The selector of the stack segment of each thread of a process: the data
// segment of privilege 3 of the kernel.
THREAD_STACK_SELECTOR :: 0x1B
// Interrupts on, and bit 1, which the processor always sets.
THREAD_FLAGS_REQUIRED :: u64(0x202)
// The flags that a thread of a process can hold: carry, parity, adjust,
// zero, sign, trap, interrupt, direction, overflow, resume, alignment check
// and identification, and bit 1. Not: the I/O privilege level, nested task,
// virtual-8086, the virtual interrupt flags, the reserved bits.
THREAD_FLAGS_ALLOWED :: u64(0x0025_0FD7)

// Which part of a Thread_Registers, of an extended state area, of a
// Thread_Schedule, of a Thread_Breakpoints or of a Thread_Placement a write
// refused.
//
// `Thread_Control` gives `Bad_Operation` for a refused write, and the error
// record names the refusal and the value. Nothing of the thread changes.
Thread_Write_Refusal :: enum u64 {
	None                = 0, // Nothing refused: the write is accepted.
	Code_Selector       = 1, // `cs` is not `THREAD_CODE_SELECTOR`.
	Stack_Selector      = 2, // `ss` is not `THREAD_STACK_SELECTOR`.
	Flags               = 3, // A required flag is clear, or a flag outside THREAD_FLAGS_ALLOWED is set.
	Instruction_Address = 4, // Not below USER_END.
	Stack_Address       = 5, // Not canonical.
	Mxcsr               = 6, // A bit that the processor does not take (its MXCSR mask).
	Header_Components   = 7, // XSTATE_BV names a component that the kernel does not save.
	Header_Reserved     = 8, // A byte of the header after XSTATE_BV is not 0.
	Weight              = 9, // The weight of a Thread_Schedule is above WEIGHT_FULL, or, in a write that only lowers, above the weight that the thread has: the error record gives the most that applied.
	Request             = 10, // The request of a Thread_Schedule is above REQUEST_LIMIT, or, in a write that only lowers, above the request that the thread has: the error record gives the most that applied.
	Weight_Limit        = 11, // The weight limit of a Thread_Schedule, in a write through the machine handle, is above WEIGHT_FULL.
	Breakpoint_Kind     = 12, // The kind of a breakpoint of a Thread_Breakpoints is not a Thread_Breakpoint_Kind.
	Breakpoint_Length   = 13, // The length of a data breakpoint is not 1, 2, 4 or 8; or the length of an execute breakpoint or of an empty place is not 0.
	Breakpoint_Address  = 14, // The address of a breakpoint is not below USER_END, is not a multiple of the length of a data breakpoint, or is not 0 in an empty place.
	Processors          = 15, // The set of processors of a Thread_Placement has no processor that the machine has, has none inside the limit, or, in a write that only narrows, has a processor that the set of the thread does not have: the error record gives the set that it had to stay inside.
	Processors_Limit    = 16, // The limit of a Thread_Placement, in a write through the machine handle, has no processor that the machine has: the error record gives the processors of the machine.
	New_Thread_Weight_Limit = 17, // The new-thread weight limit of a Thread_Schedule or of a Process_Schedule, in a write through the machine handle, is above WEIGHT_FULL.
}

// thread_registers_refusal says what a write of the registers of a thread
// refuses, and the value that it refuses. The checks are the conditions of
// the return of the processor to a process (iretq): with them, the kernel
// never faults at the return.
thread_registers_refusal :: proc "contextless" (registers: ^Thread_Registers) -> (refusal: Thread_Write_Refusal, value: u64) {
	switch {
	case registers.cs != THREAD_CODE_SELECTOR:
		return .Code_Selector, registers.cs
	case registers.ss != THREAD_STACK_SELECTOR:
		return .Stack_Selector, registers.ss
	case registers.rflags & THREAD_FLAGS_REQUIRED != THREAD_FLAGS_REQUIRED || registers.rflags & ~THREAD_FLAGS_ALLOWED != 0:
		return .Flags, registers.rflags
	case registers.rip >= USER_END:
		return .Instruction_Address, registers.rip
	case registers.rsp >> 47 != 0 && registers.rsp >> 47 != (u64(1) << 17) - 1:
		return .Stack_Address, registers.rsp
	}
	return .None, 0
}

// The places of an extended state area that a write checks (Intel SDM,
// volume 1, chapter 13).
EXTENDED_STATE_MXCSR_OFFSET :: 24
EXTENDED_STATE_LEGACY_BYTES :: 512 // The area of fxsave, and the first part of the area of xsave.
EXTENDED_STATE_HEADER_BYTES :: 64 // At EXTENDED_STATE_LEGACY_BYTES: XSTATE_BV, then XCOMP_BV and reserved bytes.

// The layout of the extended state area of a thread on this machine: the
// result 5 of `Thread_State`. Its word crosses the completion record, so
// each value is explicit; a reader takes it through `member_of_word`.
Extended_State_Layout :: enum u64 {
	Legacy      = 0, // The EXTENDED_STATE_LEGACY_BYTES bytes of fxsave, with no header.
	With_Header = 1, // The header of xsave at EXTENDED_STATE_LEGACY_BYTES, then the components of XCR0.
}

// extended_state_refusal says what a write of an extended state area
// refuses: the conditions under which xrstor or fxrstor fault on it, in the
// standard form. area holds the bytes of the area of this machine;
// components is XCR0; with_header is false for the form of fxsave, which
// has no header.
extended_state_refusal :: proc "contextless" (area: []u8, components: u64, mxcsr_mask: u32, with_header: bool) -> (refusal: Thread_Write_Refusal, value: u64) {
	if len(area) < EXTENDED_STATE_LEGACY_BYTES {
		return .Header_Reserved, u64(len(area))
	}
	mxcsr := u32(area[EXTENDED_STATE_MXCSR_OFFSET]) | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 1]) << 8 | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 2]) << 16 | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 3]) << 24
	if mxcsr & ~mxcsr_mask != 0 {
		return .Mxcsr, u64(mxcsr)
	}
	if !with_header {
		return .None, 0
	}
	if len(area) < EXTENDED_STATE_LEGACY_BYTES + EXTENDED_STATE_HEADER_BYTES {
		return .Header_Reserved, u64(len(area))
	}
	little_endian_word :: proc "contextless" (bytes: []u8, at: int) -> (result: u64) {
		for index in 0 ..< 8 {
			result |= u64(bytes[at + index]) << u64(8 * index)
		}
		return
	}
	if header := little_endian_word(area, EXTENDED_STATE_LEGACY_BYTES); header & ~components != 0 {
		return .Header_Components, header
	}
	// XCOMP_BV 0 is the standard form; the reserved bytes are 0 in each
	// area that a save of the processor wrote.
	for at := EXTENDED_STATE_LEGACY_BYTES + 8; at < EXTENDED_STATE_LEGACY_BYTES + EXTENDED_STATE_HEADER_BYTES; at += 8 {
		if reserved := little_endian_word(area, at); reserved != 0 {
			return .Header_Reserved, reserved
		}
	}
	return .None, 0
}

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"). The kind of a
// kernel event, and what the fields of its Event_Record hold:
//   Operation: one operation of a kernel entry. detail: the Operation;
//              value_0: its cycles of the cycle counter, from the start of
//              its execution to its end; value_1: its Status.
//   Switch:    a processor takes a thread from a run queue. The process and
//              the thread of the record are the thread taken; value_0: the
//              process slot of the thread that the processor left just
//              before (0: none: it was idle, or it took no thread first);
//              value_1: the number of that thread.
//   Fault:     an exception of a thread of a process. detail: the vector;
//              value_0: the address of a page fault, only when a rule that
//              names the process accepted the event (a rule for every
//              process gets 0: the order of the pages that a process
//              touches can show its data); 0 for another vector;
//              value_1: the Event_Fault_Outcome.
//   Lock_Wait: a processor took a lock of the kernel after a wait. detail:
//              the Lock_Kind; value_0: the cycles of the wait. The process
//              and the thread are the current thread of the processor (0:
//              none).
//
// A process with the right **Events** on the machine chooses the kinds to
// record with the rules of its event table (`Events_Set`). See
// [kernel event](term:kernel-event).
Event_Kind :: enum u32 {
	None      = 0, // No kind: a rule of this kind is refused.
	Operation = 1, // One kernel operation, at its end.
	Switch    = 2, // A processor takes a thread from a run queue.
	Fault     = 3, // An exception of a thread of a process.
	Lock_Wait = 4, // A processor took a lock of the kernel after a wait.
}

// event_kind_of_word is the border of the kind of an event record
// (Event_Record.kind): the member, or false for a word that names no kind.
// The ring is memory that its reader shares with the kernel, so the reader
// never takes the word for a kind that the kernel did not write.
event_kind_of_word :: proc "contextless" (word: u32) -> (kind: Event_Kind, ok: bool) {
	for member in Event_Kind {
		if u32(member) == word {
			return member, true
		}
	}
	return {}, false
}

// What the kernel did with a fault of a process (Event_Record.value_1 of a
// Fault).
Event_Fault_Outcome :: enum u64 {
	None      = 0,
	First_Use = 1, // A page on first use: the page has its frame, and the instruction runs again.
	Fault_Ring = 2, // A record of the fault ring of the process: the thread waits for an answer.
	Stopped   = 3, // The process stops.
}

// A flag of an event rule. A flag that the kernel does not know makes the
// rule not valid: `Events_Set` gives `Bad_Operation`.
Event_Rule_Flag :: enum u32 {
	Match_Detail = 0, // The detail of the event must be the detail of the rule. Not for Switch.
}
// The flags of one `Event_Rule`.
Event_Rule_Flags :: bit_set[Event_Rule_Flag;u32]

// One rule of the event table. A rule accepts a kernel event of its kind
// when each of its tests passes: the process, the detail with Match_Detail,
// the least duration; then "one in N": of the events that passed the other
// tests of this rule, since the table was given, the event N, 2N, 3N and so
// on. A kernel event that a rule accepts is one Event_Record, whatever the
// other rules say. The kernel tests the rules in their order: at most
// EVENT_RULE_CAPACITY tests of a few fields, with no lock.
//
// A process gives a table of rules to `Events_Set`; the kernel copies it and
// checks each rule first: an unknown kind or flag, a reserved word that is
// not 0, a duration for Switch or Fault, a detail for Switch or a duration
// above `EVENT_LEAST_NANOSECONDS_MOST` gives `Bad_Operation`; a bad process
// handle gives `Bad_Handle`. "One in N" is a count, never a random choice.
// 64 bytes. See [event rule](term:event-rule).
//
// Example: `{kind = u32(Event_Kind.Operation), flags = {.Match_Detail}, detail =
// u64(Operation.Memory_Map), least_nanoseconds = 10_000}` records each
// `Memory_Map` of the machine that takes 10 µs or more.
Event_Rule :: struct {
	kind:    u32, // The word of an Event_Kind (event_kind_of_word). None is refused.
	flags:   Event_Rule_Flags, // `Match_Detail`, or no flag.
	// A process handle of the caller with the right Read: only the events
	// of that process, with the address of its page faults (Read gives its
	// stop report, which has that address already). 0: every process and
	// the kernel itself (process 0), with no address of a fault.
	process: u64,
	detail:  u64, // With Match_Detail: the Operation, the vector of a Fault, or the Lock_Kind.
	// Operation and Lock_Wait: the least duration in nanoseconds, at most
	// EVENT_LEAST_NANOSECONDS_MOST. 0 for Switch and Fault.
	least_nanoseconds: u64,
	one_in:  u64, // 0 and 1: each event. N: one in N, at most EVENT_ONE_IN_MOST.
	reserved: [3]u64, // 0.
}
#assert(size_of(Event_Rule) == 64)

// event_rule_check_fields validates the non-handle fields of an Event_Rule
// and decodes its kind through event_kind_of_word. Used by both the kernel
// and host tests so one border enforces every rule constraint.
event_rule_check_fields :: proc "contextless" (rule: Event_Rule) -> (kind: Event_Kind, ok: bool) {
	parsed_kind, known := event_kind_of_word(rule.kind)
	if !known || parsed_kind == .None || rule.flags - {.Match_Detail} != {} || rule.reserved[0] | rule.reserved[1] | rule.reserved[2] != 0 {
		return {}, false
	}
	if rule.least_nanoseconds > EVENT_LEAST_NANOSECONDS_MOST || rule.one_in > EVENT_ONE_IN_MOST {
		return {}, false
	}
	switch parsed_kind {
	case .None:
		return {}, false
	case .Switch:
		if .Match_Detail in rule.flags || rule.least_nanoseconds != 0 {
			return {}, false
		}
	case .Fault:
		if rule.least_nanoseconds != 0 {
			return {}, false
		}
	case .Operation, .Lock_Wait:
	}
	return parsed_kind, true
}

// The rules of one event table. The bound makes the cost of an event point
// a bound that does not depend on the table: at most 16 tests of a few
// fields. `Events_Set` gives `No_Slot` for more.
EVENT_RULE_CAPACITY :: 16
// The longest least duration of a rule: one second. The kernel converts it
// to cycles once, when the table is given.
EVENT_LEAST_NANOSECONDS_MOST :: 1_000_000_000
// The largest N of "one in N".
EVENT_ONE_IN_MOST :: 1 << 32
// The fewest records of one event ring. The count of records of a ring is
// a power of two from this to `EVENT_RING_RECORDS_MOST`: the kernel indexes
// a ring with its own count and the capacity, never with a value of the
// process.
EVENT_RING_RECORDS_LEAST :: 16
// The most records of one event ring: 2^20 records of 64 bytes, 64 MiB for
// each processor.
EVENT_RING_RECORDS_MOST :: 1 << 20

// One kernel event, in the event ring of the processor where it came.
//
// The kernel writes it at an event point when a rule accepts the event; the
// process that gave the event table reads it with no kernel entry. What
// `detail`, `value_0` and `value_1` hold depends on `kind` (see
// `Event_Kind`). A record shows the address of a page fault only when a rule
// names its process with a handle with **Read**. 64 bytes. See
// [event record](term:event-record).
//
// Example: a `Switch` record with `process = 7`, `thread = 2`, `value_0 = 0`:
// the processor was idle, and took the thread 2 of the process in slot 7.
Event_Record :: struct {
	time:      u64, // The cycle counter at the event point (Time_Record: cycle_start and cycle_frequency).
	kind:      u32, // The word of an Event_Kind, read through event_kind_of_word.
	processor: u32, // The index of the processor.
	process:   u32, // The slot of the process. 0: the kernel, with no thread.
	thread:    u32, // The number of the thread in its process (Thread_Record.number). 0 when process is 0.
	process_serial: u64, // The serial of the process of the slot (Process_Report.process_serial).
	detail:    u64, // By kind: the Operation, the vector of a Fault, or the Lock_Kind. 0 for Switch.
	value_0:   u64, // By kind: see `Event_Kind`.
	value_1:   u64, // By kind: see `Event_Kind`.
	reserved:  u64, // 0.
}
#assert(size_of(Event_Record) == 64)

// The head of one event ring. The ring of processor p starts at the byte
// p * (EVENT_RING_HEAD_BYTES + records * 64) of the memory object; its
// records follow its head. The kernel writes the record n at the index
// n % records, then `written` = n + 1. The process reads the records from
// `read` to `written`, then writes `read`: a place is free for the kernel
// again once `read` passed it. When records - (written - read) is 0, the
// kernel drops the record and adds 1 to `lost`: it never waits, and it
// never writes over a record that the process did not read. The kernel
// keeps its own counts; it reads only `read` from this memory, and a false
// value there loses records of this process, or lets the kernel write over
// records that this process did not read: nothing else.
//
// The two lines of 64 bytes keep the words that the kernel writes and the
// word that the process writes on two cache lines. 128 bytes. See
// [event ring](term:event-ring).
Event_Ring :: struct {
	// The line that the kernel writes.
	written:   u64, // The count of records written in this ring since the table was given.
	lost:      u64, // The records that the kernel dropped because the ring was full (the lost count).
	records:   u64, // The capacity of the ring, written when the table is given.
	processor: u64, // The index of the processor of this ring.
	reserved_kernel: [4]u64, // Not written.
	// The line that the process writes.
	read:      u64, // The count of records that the process read: the kernel can write over each record before it.
	reserved_process: [7]u64, // Not read.
}
#assert(size_of(Event_Ring) == 128)
// The bytes of the head of one event ring, before its records.
EVENT_RING_HEAD_BYTES :: size_of(Event_Ring)

// The result kind of a kernel operation: the `kind` of its completion
// record.
//
// The kernel writes one completion for each command of the kernel ring;
// `src/library/modus/system` gives it back as the second result of each wrapper
// (`system.Status` is this type). With `Ok` the values of the completion
// are the results of the operation. With another status the operation
// failed, and the values are an
// `errors.Error_Record`: which argument was wrong, its value, and what the
// kernel found. A status says which class of mistake it is; the error record
// says which one. The comment of each `Operation` lists its statuses and when
// each comes. See [status](term:status).
//
// Example: `memory, status := system.memory_create(1 << 20)` gives
// `Bad_Operation`: the count is above `MEMORY_PAGE_LIMIT`.
Status :: enum u32 {
	Ok            = 0, // The operation ran: the values of the completion are its results.
	Bad_Operation = 1, // An argument has a value that the operation never takes.
	// A kind, a flag or a command that the kernel does not know, a count of 0 or above its limit, a combination
	// that the operation refuses (`Write` with `Execute`). The same call with the same arguments fails again: it
	// is a mistake of the caller.
	Bad_Handle    = 2, // A handle argument names no object of the kind that the operation needs.
	// The handle number is 0 where 0 is not allowed, was never given, was closed, or names an object of another
	// kind. Each operation that takes a handle can give it.
	Bad_Address   = 3, // An address argument is wrong.
	// The process cannot read or write the memory that it names, the address is not aligned as the operation
	// needs, or a range is outside its object, below 4096 or above `USER_END`, or meets another mapping.
	No_Memory     = 4, // No page frame is free, though the budget can pay.
	// A contiguous run of the length asked does not exist, or a page table finds no frame. `Memory_Create`,
	// `Memory_Map`, `Process_Start` and `Thread_Create` give it. Another try can pass after other objects end.
	No_Slot       = 5, // A table of fixed capacity is full.
	// The handle table of a process, the 128 mappings of a process, the threads of a process
	// (`THREAD_CAPACITY`), the module records (`PROCESS_MODULE_CAPACITY`), the words of a wait
	// (`WORD_WAIT_CAPACITY`), the message interrupts (`MESSAGE_CAPACITY`), the rules of an event table, or a
	// table of the kernel. Another try can pass after a slot frees.
	Bad_State     = 6, // The object is not in a state where the operation applies.
	// The process is stopped or not created, the thread is not held or ended, no thread waits for the fault
	// that an answer names, another process has the event table, the memory object has a protection of its
	// own. The arguments are right; the moment is wrong.
	No_Right      = 7, // The handle names the object, but it does not have the right for this operation.
	// The `Handle_State` of the handle gives the rights that it has. No operation adds a right: a process
	// that needs it asks the holder of a handle with that right for a new grant. A process also gets it
	// when it changes a module record of its starter in itself, or maps or unmaps over it
	// (`Module_Writer`): only a holder of its process handle does that.
	No_Budget     = 8, // The budget cannot pay for the operation.
	// The budget, or a budget above it, does not hold the pages, the process slot or the thread slot that the
	// operation takes; or for `Log`, the budget accepted all the records of its amount in this second. See
	// `Budget_Amounts`.
}

// The kernel keeps the page frames of a memory object in a frame list: in
// the record of the object for at most MEMORY_INLINE_PAGES pages; else in
// list pages of MEMORY_LIST_ENTRIES frames each, and for more than one list
// page, a top page that names them. The budget pays for the list pages too.
//
// A small object costs only its pages; an object of 5 to 512 pages costs one
// list page more; a larger one costs one list page for each 512 pages, and
// the top page (`memory_cost`). See [frame list](term:frame-list).
MEMORY_INLINE_PAGES :: 4 // The frames that the record of a memory object holds itself.
MEMORY_LIST_ENTRIES :: 512 // The frames that one list page holds: 4096 bytes of 8-byte entries.
// The pages of one memory object: 1 GiB. The top page names at most 512
// list pages of 512 frames each. A `Contiguous` object has no frame list and
// no such limit.
MEMORY_PAGE_LIMIT :: MEMORY_LIST_ENTRIES * MEMORY_LIST_ENTRIES

// memory_list_pages gives the list pages of a memory object of `page_count`
// pages that is not contiguous: 0 up to `MEMORY_INLINE_PAGES` pages, 1 up to
// `MEMORY_LIST_ENTRIES`, else one for each 512 pages and the top page.
//
// Example: `memory_list_pages(1000)` is 3: two list pages and the top page.
memory_list_pages :: proc "contextless" (page_count: u64) -> u64 {
	switch {
	case page_count <= MEMORY_INLINE_PAGES:
		return 0
	case page_count <= MEMORY_LIST_ENTRIES:
		return 1
	}
	// The division rounds up with no sum: a count near the top of the type
	// would wrap the sum to a few list pages.
	list_pages := 1 + page_count / MEMORY_LIST_ENTRIES
	if page_count % MEMORY_LIST_ENTRIES != 0 {
		list_pages += 1
	}
	return list_pages
}

// memory_cost gives the pages that Memory_Create takes from a budget for an
// object of `page_count` pages that is not contiguous and not
// `Uncommitted`: the pages and the list pages. A cost past the type is the
// largest value: no budget holds it, so the cost of a count that a caller
// asks for and that no object has never wraps to a small one.
//
// Example: `memory_cost(16)` is 17; `memory_cost(4)` is 4.
memory_cost :: proc "contextless" (page_count: u64) -> u64 {
	list_pages := memory_list_pages(page_count)
	if page_count > max(u64) - list_pages {
		return max(u64)
	}
	return page_count + list_pages
}

// A flag of `Memory_Create`: how the pages of a new memory object get their
// page frames and who pays them. A flag that the kernel does not know gives
// `Bad_Operation`.
Memory_Flag :: enum u64 {
	// Each page gets its page frame at creation, not at its first use. With no flag the frames come on first
	// use: the budget pays now, and the first access takes the frame (a page on first use).
	Frames_Now = 0,
	// The page frames follow each other in physical memory, each one from the creation, and they do
	// not move: memory that a device reads and writes (Memory_Physical). The budget pays for no frame
	// list. It can give No_Memory when the budget can pay: no free run is long enough.
	Contiguous = 1,
	// The pages are not paid at the creation: the budget pays the frame list only. Memory_Commit pays pages
	// and makes them usable; a page that is not committed has no frame, and an access to it is a fault.
	Uncommitted = 2,
	// Contiguous, in one run aligned on 2 MiB, and the page count is a multiple of LARGE_PAGE_PAGES: a mapping
	// uses a large page for each 2 MiB whose address and first page are aligned.
	Large_Pages = 3,
}
// The flags of one `Memory_Create`. Example: `{.Frames_Now}`.
Memory_Flags :: bit_set[Memory_Flag;u64]
// The flags that `Memory_Create` knows, as the word of its argument: a word
// with another bit gives `Bad_Operation`, so that a later kernel can give
// that bit a meaning.
MEMORY_FLAGS_KNOWN :: u64(1) << u64(Memory_Flag.Frames_Now) | u64(1) << u64(Memory_Flag.Contiguous) | u64(1) << u64(Memory_Flag.Uncommitted) | u64(1) << u64(Memory_Flag.Large_Pages)

LARGE_PAGE_PAGES :: 512 // The pages of 4096 bytes of one large page (2 MiB): one entry of the page directory of the processor.
RANGE_TABLE_CAPACITY :: 256 // The ranges of one Memory_Commit or Memory_Protect. More gives `Bad_Operation`.
// The pages of all the ranges of one Memory_Commit or Memory_Protect (256 MiB): the kernel walks each page with
// interrupts off; a larger change is several calls.
RANGE_TABLE_PAGE_LIMIT :: 65536

// A range of pages of a memory object (Memory_Commit).
//
// A process writes a table of them in its own memory; the kernel reads it
// as hostile input: the ranges must be in increasing order, with no overlap,
// inside the object. Example: `{first = 16, page_count = 4}` is the pages 16
// to 19.
Page_Range :: struct {
	first:      u64, // The first page of the object, from 0.
	page_count: u64, // The pages of the range, from 1.
}

// A range of addresses of the process (Memory_Protect).
//
// The same rules as `Page_Range`, on addresses: in increasing order, with no
// overlap, inside one mapping. Example: `{address = 0x1000_0000_0000,
// page_count = 1}` is one page.
Address_Range :: struct {
	address:    u64, // A multiple of PAGE_SIZE.
	page_count: u64, // The pages of the range, from 1.
}

// A flag of `Memory_Commit`.
Commit_Flag :: enum u64 {
	Decommit = 0, // The committed pages of the ranges are no longer paid: their frames return to the budget at once, and a page committed again is zero.
}
// The flags of one `Memory_Commit`: `{}` commits, `{.Decommit}` decommits.
Commit_Flags :: bit_set[Commit_Flag;u64]
// The flags that `Memory_Commit` knows, as the word of its argument.
COMMIT_FLAGS_KNOWN :: u64(1) << u64(Commit_Flag.Decommit)

// A flag of `Memory_Map` and of `Memory_Protect`: the access that a mapping
// gives. No flag is read only. A page is never writable and executable.
Map_Flag :: enum u64 {
	Write           = 0, // The pages can be written. Needs **Write** on the memory handle.
	Execute         = 1, // The pages can be executed. Needs **Execute** on the memory handle. With `Write` in Memory_Map: guest memory, with `No_Access`.
	No_Access       = 2, // Memory_Map: a mapping whose pages fault until Memory_Protect gives them access. Memory_Protect: no access.
	Receive_Handles = 3, // Memory_Map: this process agrees to receive handles through this memory object (`Handle_Give`). Refused by `Memory_Protect`.
	At_Address_Zero = 4, // Memory_Map: the mapping starts at the address 0, the guest physical address 0 of a guest. Refused by `Memory_Protect`.
	// Memory_Map: the pages are write-combining: the processor gathers the writes and sends them to the
	// device in bursts, and does not cache a read. Only for device memory of `Device_Kind.Memory`, which
	// is else mapped with no cache, and never with `Execute` (map_write_combining_refused). The mappings of a
	// device memory object, and of each object whose pages meet its pages, have one cache type at a time: a
	// live mapping with no cache refuses a write-combining one, and the reverse. Refused by
	// `Memory_Protect`. For the memory of a device that the processor fills and the device reads: a
	// shared memory region of a GPU.
	Write_Combining = 5,
}
// The flags of one `Memory_Map` or `Memory_Protect`. Example: `{.Write}`.
Map_Flags :: bit_set[Map_Flag;u64]
// The flags that `Memory_Map` knows, as the word of its argument.
MAP_FLAGS_KNOWN :: u64(1) << u64(Map_Flag.Write) | u64(1) << u64(Map_Flag.Execute) | u64(1) << u64(Map_Flag.No_Access) | u64(1) << u64(Map_Flag.Receive_Handles) | u64(1) << u64(Map_Flag.At_Address_Zero) | u64(1) << u64(Map_Flag.Write_Combining)
// The flags that `Memory_Protect` knows, as the word of its argument: protection bits only.
PROTECT_FLAGS_KNOWN :: u64(1) << u64(Map_Flag.Write) | u64(1) << u64(Map_Flag.Execute) | u64(1) << u64(Map_Flag.No_Access)

// map_write_combining_refused says if `Memory_Map` refuses the flag
// `Write_Combining` of a mapping: on normal memory, the kernel reads and
// writes its frames through its direct map, write-back, and two cache types
// over one frame break the coherence of the caches; on the device memory of
// a screen (`Device_Kind.Display_Memory`), the type is the one of the
// firmware; with `Execute`, the processor would fetch instructions from
// memory that it does not cache. Over the registers of a device, the kernel
// then keeps one cache type across the live mappings of an object and of
// each object whose pages meet its pages (`Bad_State` with `Object_Shared`
// else).
map_write_combining_refused :: proc "contextless" (flags: Map_Flags, device_registers: bool) -> bool {
	if .Write_Combining not_in flags {
		return false
	}
	return !device_registers || .Execute in flags
}

// The largest code of `Machine_Stop`: the host receives one byte.
MACHINE_STOP_CODE_MOST :: 255

// The state of a process or of a thread. A process is Ready when one of
// its threads is Ready.
//
// `Process_State` gives the state of a process; `Thread_State` and
// `Thread_Report.state` give the state of a thread. The states of a process:
// `Created`, then `Ready` and `Waiting` in turn while it runs, then
// `Stopped`, which it never leaves.
Process_State :: enum u32 {
	None    = 0, // No process or no thread in the slot.
	Created = 1, // `Process_Create` made the process; `Process_Start` has not started it. It has no thread.
	Ready   = 2, // A thread runs or waits for a processor in a run queue.
	Waiting = 3, // Each thread is in a wait: a deadline or a word wait. A wake makes it Ready again. A hold does not change it.
	// The process ended: `Process_Stop`, a fault with no fault handler, the close of the last handle to it, or
	// the end of its last thread. Its `Stop_Cause` says which. A thread that ended is Stopped too.
	Stopped = 4,
}

// The kind of a part of the machine that `Device_Create` gives to a device
// service. The two values `a` and `b` of the call have a meaning for each
// kind.
Device_Kind :: enum u64 {
	None      = 0, // Refused: `Bad_Operation`.
	Ports     = 1, // A range of input and output ports: `a` the first port, `b` the count.
	Interrupt = 2, // A line of the 8259: `a` from 1 to 15.
	Memory    = 3, // The registers of a device: `a` the physical address, `b` the count of pages; mapped with no cache, or write-combining with `Map_Flag.Write_Combining`.
	Message   = 4, // A message interrupt (MSI-X): the results give the address and the value that the device writes.
	// The video memory of a display, which holds its screen pages: `a` the physical address, `b` the count of
	// pages; the range must hold the address of the framebuffer of the firmware. The same device memory as
	// `Memory`, with no requester for the IOMMU, and its mapping has the page attribute of the framebuffer of the
	// firmware: the default entry of the page attribute table, so the memory type ranges (MTRR) that the
	// firmware set decide the type. A mapping with no cache makes each write of a pixel a write to the device
	// (src/md/infrastructure/whole_frame.md).
	Display_Memory = 5,
}

// What `Device_Create` of the kind `Memory` says of the device whose
// registers the range holds, in its second result. The root service reads
// it to choose the memory that it makes for the device: with `Windows`, an
// object that is not contiguous serves (src/md/infrastructure/iommu.md,
// "Device addresses"). An empty set: no IOMMU in use, or a device that gets
// no domain.
Device_Memory_Fact :: enum u64 {
	Domain  = 0, // The IOMMU gives the device a device domain: it reaches only the memory that its service declares. Behind a conventional bridge, the one domain of each device there.
	Windows = 1, // The remapping unit of the device gives device windows: `Memory_Physical` accepts an object that is not contiguous.
}
Device_Memory_Facts :: bit_set[Device_Memory_Fact; u64]

// The message interrupts: each one has a vector of its own on the first
// processor. `Device_Create` gives `No_Slot` for a 17th.
MESSAGE_CAPACITY :: 16

// What `Inspect` writes: the kind of a report of the kernel, and what its
// `index` argument names. Each kind needs **Inspect** on the machine. A slot
// or a processor with no process, or out of the table, gives a report of
// zeros.
Inspect_Kind :: enum u64 {
	None    = 0, // Refused: `Bad_Operation`.
	System  = 1, // The `System_Report` of the machine. `index` is not read.
	Process   = 2, // The `Process_Report` of the process slot `index`.
	Processor = 3, // The `Processor_Report` of the processor `index`, from 0.
	Boot      = 4, // The `Boot_Report`. `index` is not read.
	Mappings  = 5, // The `Mapping_Report` of a page table. `index` 0: the kernel half of the addresses. Another value: the half of the process that asks.
	Modules   = 6, // The `Module_Report` of the process slot `index`.
	// The reports of a developer tool (docs/TOOLS.md): what one process has,
	// read with the right Inspect: counts, places and states. A process
	// without that right sees no other process.
	// Each one has the serial of the process, so that a reader drops a
	// sample of two processes in one slot.
	Process_Mappings = 7, // Process_Mapping_Report of process slot `index`.
	Threads          = 8, // Thread_Table_Report of process slot `index`.
	// Stop_Report of process slot `index`: zero when it did not stop on a
	// fault, or when the slot has no process. A frame of a stack trace comes
	// from the stack of the process, and a corrupt chain of frame pointers
	// gives values of its memory; the address of a page fault can be a
	// value too. So the kernel gives a frame only when a module record of
	// the process holds its address (else the frame is all zero), and the
	// address of the fault only in the first page or in a module record
	// (else 0). hidden_value_count counts what it took out. The holder of the
	// process handle with Read still reads the whole report (Process_State).
	Stop             = 9,
	// Page_Report of the process that asks, for the address that it writes
	// in the Page_Report: which of the 64 pages from it have a frame. Index
	// must be 0: a page that gets a frame in another process is a fact that
	// it can watch page by page (a side channel), so no slot but its own.
	Pages            = 10,
}

// A fact about one mapping of a process, in `Process_Mapping.flags`.
Process_Mapping_Flag :: enum u32 {
	Write       = 0, // The process can write the pages.
	Execute     = 1, // The process can execute the pages.
	Uncached    = 2, // The registers of a device.
	Device      = 3, // The frames are not from the page frame table: a framebuffer, boot data, a device.
	Contiguous  = 4, // The memory object was made `Contiguous`: its frames follow each other and do not move.
	Shared      = 5, // Another mapping or another handle names the memory object.
	Thread_Area = 6, // The thread record and the kernel ring of a thread.
	Uncommitted = 7, // An object made with Uncommitted: `committed` says which part its budget pays.
	Large       = 8, // The mapping uses large pages of 2 MiB.
	Protected   = 9, // Memory_Protect changed the protection of pages of the mapping.
	No_Access   = 10, // The protection of the mapping is No_Access now.
	Write_Combining = 11, // Memory_Map gave `Write_Combining`: the pages of device memory are write-combining, not uncached.
}

// One mapping of a process: Process_Mapping_Report.
//
// The kernel writes it for a developer tool from its own table of mappings
// and from the page table. Example: a stack of 64 pages of which the process
// touched 3 has `page_count = 64`, `present = 3` and the flag `Write`. 64
// bytes.
Process_Mapping :: struct {
	address:       u64, // The first byte of the mapping in the process.
	page_count:    u64, // The pages of the mapping.
	first:         u64, // The first page of the memory object.
	present:       u64, // The pages of this mapping that have a page frame, from the page table.
	region_pages:  u64, // The pages of the memory object.
	region_serial: u64, // The memory object: two mappings with one serial map one object.
	flags:         bit_set[Process_Mapping_Flag;u32], // What the mapping and its memory object are.
	references:    u32, // The handles and the mappings that name the memory object, in all processes.
	committed:     u64, // The committed pages of the memory object: all its pages, unless it was made Uncommitted.
}
#assert(size_of(Process_Mapping) == 64)

MAPPING_REPORT_CAPACITY :: 128 // MAPPING_CAPACITY of the kernel: the mappings of one process. `Memory_Map` gives `No_Slot` for one more.
// HANDLE_CAPACITY of the kernel: the places of the handle table of one process. The place 0 holds no handle,
// so a process holds `HANDLE_TABLE_CAPACITY - 1` handles at most, and one more gives `No_Slot` with the
// record `Full` of the unit `Handles`.
HANDLE_TABLE_CAPACITY :: 128

// The mappings of one process, in the order of their addresses. `Inspect`
// with the kind `Process_Mappings` writes it; the developer tools show the
// memory of a process with it.
Process_Mapping_Report :: struct {
	process_serial: u64, // The serial of the process of the slot: a reader drops reports of two processes.
	count:    u64, // The records in `mappings`.
	mappings: [MAPPING_REPORT_CAPACITY]Process_Mapping, // By address; `count` of them are used.
}

// One thread of a process: Thread_Table_Report. The kernel reads the
// fields of the scheduler with no lock: each field is whole, two fields can
// come from two instants.
Thread_Report :: struct {
	// The machine number of the thread: the name of this thread among all the threads of the machine. A new
	// thread never has the machine number of a thread that ended. `Thread_Control` takes it with the machine handle.
	machine_number:   u64,
	number:           u32, // The thread area of the thread in the process.
	state:            Process_State, // Ready or Waiting (Stopped: it ended).
	processor:        u32, // 1 + the processor that runs it now. 0: none.
	home:             u32, // The processor of its run queue.
	weight:           u32, // From 1 to `WEIGHT_FULL`.
	request:          u32, // Microseconds.
	words:            u32, // The words of the word wait that it is in. 0: no word.
	queued:           u32, // 1: it is in the run queue of home.
	virtual:          u64, // Its virtual time, in weighted cycles: the fair strategy and EEVDF.
	virtual_deadline: u64, // Its virtual deadline under EEVDF, in weighted cycles.
	lag:              i64, // Its lag: under EEVDF the time that it is owed; under the fair strategy its distance to the queue clock while it waits.
	run_time:         u64, // Milliseconds of processor time: the ticks in which it ran.
	deadline:         u64, // The end of its wait, in milliseconds since the start. WAIT_FOREVER: none.
}
#assert(size_of(Thread_Report) == 80)

THREAD_REPORT_CAPACITY :: 32 // The thread areas of one process: `THREAD_CAPACITY`.

// The threads of one process, with the state of the scheduler of each.
// `Inspect` with the kind `Threads` writes it.
Thread_Table_Report :: struct {
	process_serial: u64, // The serial of the process of the slot: a reader drops reports of two processes.
	count:   u64, // The records in `threads`.
	threads: [THREAD_REPORT_CAPACITY]Thread_Report, // `count` of them are used.
}

// The pages of a range of a process that have a page frame: a reader that
// shows the bytes of memory knows which pages it can read with no fault,
// and does not give a frame to a page by its read.
//
// The 64 pages are the bits of one word.
PAGE_REPORT_CAPACITY :: 64

// Which of 64 pages of the process that asks have a page frame, and which
// are mapped. The process writes `address`; `Inspect` with the kind `Pages`
// writes the two sets. A memory viewer reads only the present pages, so its
// read gives no frame to a page.
//
// Example: `present = 0b101`, `mapped = 0b111`: the pages 0 and 2 have a
// frame, the page 1 is mapped and has none yet.
Page_Report :: struct {
	address: u64, // The first page: the caller writes it, a multiple of 4096.
	present: u64, // Bit n: page n has a frame.
	mapped:  u64, // Bit n: page n is in a mapping.
}

// The state of the whole machine: the memory, the slots, the counts of the
// kernel and of its locks. `Inspect` with the kind `System` writes it.
System_Report :: struct {
	time:          u64, // Milliseconds since boot.
	page_count:    u64, // Pages of memory that the kernel manages.
	free_pages:    u64, // The free frames: in the frame table and in the frame caches of the processors.
	process_slots: u64, // The process slots in use.
	region_count:  u64, // Memory objects in use.
	entries:       u64, // Kernel entries since boot.
	interrupts:    u64, // Interrupts since boot.
	budget_pages:  u64, // The pages of all the budgets. free_pages - reserved_pages is always budget_pages, exactly: each page is free or paid.
	// free_pages and reserved_pages alone are not values of one instant: the processors take frames from their
	// caches while the kernel reads them; their difference is exact (docs/ARCHITECTURE.md, "The frame caches").
	processors:    u64, // The processors that run threads.
	reserved_pages:   u64, // Pages that a budget paid for and that have no page frame yet: pages on first use.
	first_use_faults: u64, // Page faults of processes after which the page was present.
	locks:            [LOCK_KIND_CAPACITY]Lock_Count, // By Lock_Kind.
	strategy:         Strategy, // The scheduling strategy of the machine (Strategy_Set): the new one as soon as a change starts, before each run queue converted (Processor_Report.strategy).
	strategy_changes: u32, // The calls of Strategy_Set since boot.
}

// The locks of the kernel, by the data that each one protects
// (docs/ARCHITECTURE.md, "Locks of the kernel"). The order of the kinds is
// the lock order: a processor takes a lock only if it holds no lock of a
// later kind.
Lock_Kind :: enum u64 {
	Control = 0, // The paths that cross processes or end objects that several processes name: rare.
	Process = 1, // The handles, the mappings and the page table of one process.
	Origin  = 2, // The origin tree of the holdings.
	Region  = 3, // One memory object: it gives a page on first use one frame.
	Frame   = 4, // The page frames, the reserved pages, the pages of the budgets, the slots of the memory objects.
	Cache   = 5, // The stack of free page frames of one processor (its frame cache).
	Log     = 6, // The records of the log and the own log rings. The serial port has its own writer.
	Wait    = 7, // One bucket of the wait table: the threads that wait on its words.
	Run     = 8, // The run queue of one processor, and the scheduling state of its threads.
}

LOCK_KIND_CAPACITY :: 12

// The name of each kind of lock, for a report and for the log.
@(rodata)
LOCK_KIND_NAMES := [Lock_Kind]string {
	.Control = "control",
	.Process = "process",
	.Origin  = "origin",
	.Region  = "region",
	.Frame   = "frame",
	.Cache   = "cache",
	.Log     = "log",
	.Wait    = "wait",
	.Run     = "run",
}

// What the kernel counts for one kind of lock, on all the processors.
// `System_Report.locks` holds one for each `Lock_Kind`. See
// [lock count](term:lock-count).
Lock_Count :: struct {
	takes: u64, // The times that a processor took a lock of this kind.
	waits: u64, // The times that the lock was held, and the processor had to wait for it.
}

// The state of one processor: what it runs, its scheduler and its frame
// cache. `Inspect` with the kind `Processor` writes it.
Processor_Report :: struct {
	process:   u64, // The slot of the process that the processor runs. 0: the processor is idle.
	busy_time: u64, // Milliseconds with a thread.
	same:      u64, // 1: the process is the process that asks.
	apic_id:   u64, // The number that the machine gives to the processor.
	// The scheduler (docs/SCHEDULING.md), since boot.
	strategy:    Strategy, // The strategy of the run queue of the processor.
	queued:      u32, // The threads in the run queue now.
	picks:       u64, // Threads that a pick gave to the processor.
	preemptions: u64, // Stints that a wake preemption ended.
	moves:       u64, // Threads that the processor took from the queue of another processor.
	pick_cycles: u64, // Cycles of the cycle counter in all the picks.
	interrupt_preemptions: u64, // Wake preemptions by an interrupt from another processor.
	preempt_cycles: u64, // Their cycles in the kernel: from the handler of the interrupt to the next thread.
	// The frame cache of the processor: a stack of free page frames.
	cache_frames:        u64, // The frames on the stack now.
	cache_batches_taken: u64, // Batches that the stack took from the frame table.
	cache_batches_given: u64, // Batches that the stack gave back.
	cache_drains:        u64, // Drains that took the frames of the stack, for a take that found no free frame.
}

// The log: records of text, each with its process and its level.
//
// The kernel keeps the last LOG_RECORD_CAPACITY records in one memory
// object. The kernel is the one writer: it sets the time, the process and
// the thread of each record, so a process cannot write a record of another
// process. A process chooses only the level and the text.
// A reader maps the memory object without Write. It reads Log_Head.written,
// and it waits on the low 32 bits of that word (Word_Wait).
//
// Record n is at index n % LOG_RECORD_CAPACITY, after the head. A reader
// that is late by more than the capacity lost records: it knows how many.
// The kernel can write over a record while a reader copies it: the reader
// reads `written` again after the copy, with the two rules of
// `log_first_kept` and `log_copy_kept` (log_ring.odin).
//
// The level of one record of the log: how much the text matters. A process
// gives it to `Log`; a reader of the log filters on it. See
// [level](term:level).
Log_Level :: enum u8 {
	Info    = 0, // A fact of the normal work: a service started, a file was written.
	Debug   = 1, // For the principal who looks for a fault: details that a normal reader hides.
	Warning = 2, // Something went wrong and the process went on: a refused request, a retry.
	Error   = 3, // Something failed: an operation that the process needed, a check of a test.
}

// The bytes of text in one log record. With the other fields, a record is
// 256 bytes; a longer text continues in the next records (`more`).
LOG_TEXT_CAPACITY :: 168
// The value runs that one record keeps: the kind of each typed part of its
// text (modus:contract/value_kinds). A text with more typed parts keeps its first
// runs; the rest of its text is plain.
LOG_RUN_CAPACITY :: 8
// The value runs that one Log operation takes, after its text.
LOG_CALL_RUN_LIMIT :: 32
// The bytes of the text of one Log operation. A longer text gives
// `Bad_Address`. The kernel copies the text whole before it checks it.
LOG_TEXT_BYTES_MOST :: 4096
// 128 pages: 2047 records. A reader that starts late copies the newest 2046
// of them.
LOG_PAGES :: 128
// The records that the log keeps: the pages of the log less the head, in
// records of 256 bytes.
LOG_RECORD_CAPACITY :: LOG_PAGES * 4096 / size_of(Log_Record) - 1
// The log records that the kernel writes for itself in each second after
// its first tick, at most: the stops on a fault, the refused returns, the
// full fault rings, that a process can cause as fast as it faults. A line
// past the bound is counted, and one record says the count.
LOG_RECORDS_OF_THE_KERNEL :: 64
// The log records of each second of a process of normal use: what the root
// service gives each process that it starts.
LOG_RECORDS_OF_A_PROCESS :: 1000
// The process slots of the kernel.
PROCESS_SLOTS_OF_THE_MACHINE :: 64
// The bytes of the name of a process (`Process_Create`). The kernel keeps
// the name with a zero byte after it.
PROCESS_NAME_BYTES_MOST :: 31
// The log records of each second of the whole machine: the amount of the
// root budget, which divides it among every budget, a process of normal use
// in each process slot. The serial port can lose the lines of a flood of
// these records, and says how many (src/md/features/log_side_channels.md).
LOG_RECORDS_OF_THE_MACHINE :: PROCESS_SLOTS_OF_THE_MACHINE * LOG_RECORDS_OF_A_PROCESS

// The pages of the own log ring of a process: the kernel keeps a copy of
// each record of the process there, which only the records of that process
// push out (src/md/features/own_log_ring.md). The budget that pays the
// process pays them at `Process_Create`. 4 pages hold 64 records: the rows
// of one call of a reader with 64 rows, for 16 KiB of each process.
OWN_LOG_PAGES :: 4
// The records that an own log ring keeps. The ring has no head: the kernel
// keeps the count of the records of the process, and the record with the
// count n is in the place n % OWN_LOG_RECORD_CAPACITY.
OWN_LOG_RECORD_CAPACITY :: OWN_LOG_PAGES * 4096 / size_of(Log_Record)

// The head of the memory of the log: the first 256 bytes, before the
// records. A reader reads `written`, copies the records that it has not
// read, then reads `written` again: a record that the kernel wrote over in
// the meantime is lost, and the reader knows how many.
Log_Head :: struct {
	written:  u64, // The count of records since the start of the machine.
	capacity: u64, // LOG_RECORD_CAPACITY.
	reserved: [30]u64, // 0: the head has the size of a record.
}

// One record of the log of the kernel: one text, or a part of a longer
// text, of one thread, with its time and its level.
//
// The kernel writes it for a `Log` operation, or for a line of its own; the
// root service gives the memory of the records (`ROOT_LOG_RECORDS`) to the
// readers of the log. The kernel sets `time`, `process`, `process_serial`,
// `own_number`, `thread` and `name`: a process cannot write a record of
// another process. The process slot with the process serial names one
// process: the log service gives a reader that does not act for the
// principal the records of those two numbers only, numbered by `own_number`
// (modus:contract/log_scope), from the own log ring of its process
// (`Log_Read`): the kernel writes each record of a process in the whole log
// and in that ring. The slots have one byte each: the kernel has
// at most 256 process slots and 256 thread slots, which leaves room for the
// two numbers in 256 bytes. See [log record](term:log-record).
//
// Example: the line `[console] started` on the serial port is one record
// with `name = "console"`, `level = .Info`, `text_count = 7`.
Log_Record :: struct {
	sequence:       u64, // The number of the record in the whole log, from 0.
	time:           u64, // Microseconds since the start of the machine.
	process:        u8, // The process slot. 0: the kernel.
	thread:         u8, // The slot of the thread. 0: the kernel.
	level:          Log_Level, // The level that the writer gave.
	more:           u8, // 1: the text continues in the next record.
	process_serial: u32, // The process serial: it changes for each new process in the slot. 0: the kernel.
	own_number:     u32, // The number of the record among the records of its process, from 0 at its start; it starts again from 0 after 2^32 records. 0 for the kernel.
	text_count:     u16, // The bytes of `text` in use, at most `LOG_TEXT_CAPACITY`. 0 for a fact.
	run_count:      u8, // The value runs of the text: runs[:run_count]. 0 for a fact.
	form:           u8, // The byte of a `Log_Record_Form` (`log_record_form`): what the bytes after the name hold. 0: a text.
	name:           [PROCESS_NAME_BYTES_MOST + 1]u8, // The name of the process, or "kernel".
	runs:           [LOG_RUN_CAPACITY]value_kinds.Value_Run, // In order, inside text[:text_count]. A fact: the first bytes of its `Log_Fact`.
	text:           [LOG_TEXT_CAPACITY]u8, // The text, UTF-8, `text_count` bytes. A fact: the rest of its `Log_Fact`.
}

#assert(size_of(Log_Record) == 256)
#assert(offset_of(Log_Record, name) == 32)
#assert(offset_of(Log_Record, runs) == 64)

// The form of a log record: what its bytes after the name of the process
// hold. A reader takes the byte `Log_Record.form` through `log_record_form`,
// and shows a record of a byte that names no member with its head only
// (src/md/features/log_facts.md, "The record").
Log_Record_Form :: enum u8 {
	Text = 0, // The value runs and the text. A zero record is a text record.
	Fact = 1, // A part of a log fact: one `Log_Fact`. A fact of more values than one record holds is several records, each with `more` but the last (`log_fact_join_take`).
}

// The bytes of the values of one record of a log fact: the fields of its
// record type, with no padding, beside the module hash and the fact key.
LOG_FACT_VALUE_CAPACITY :: 144

// The bytes of the out-of-line area of one log fact, at most: the texts of
// its text views that do not fit in their 16 bytes (a path, a line of the
// console, the target of a link), after its fixed record, which the records
// after the first carry (src/md/features/log_facts.md, "Text views"). A
// writer cuts a text that does not fit, on a whole character, with the cut
// mark; the kernel refuses a longer fact.
LOG_FACT_TEXT_AREA_BYTES_MOST :: 1024
// The bytes of the values of one log fact, at most: its fixed record, which
// one record holds, and its out-of-line area.
LOG_FACT_VALUES_MOST :: LOG_FACT_VALUE_CAPACITY + LOG_FACT_TEXT_AREA_BYTES_MOST
// The records of one log fact, at most: its value bytes cut in parts of
// one record each, which follow each other in the log of its process (src/md/features/log_facts.md, "A fact of several records").
LOG_FACT_RECORDS_MOST :: (LOG_FACT_VALUES_MOST + LOG_FACT_VALUE_CAPACITY - 1) / LOG_FACT_VALUE_CAPACITY
#assert(LOG_FACT_RECORDS_MOST == 9)

// The bytes of a log record after the name of the process, for the form
// Fact: the module hash, the fact key, the count of the value bytes, and
// the values. The writer gives it to `Log`, up to the end of its values;
// the kernel writes `value_count` from the length and copies the bytes with
// no check of their content (src/md/features/log_facts.md, "The record").
//
// Example: the fact `storage.Bad_Block{block = 12, ...}` of the module whose
// hash starts with 1a 2b is the hash, the key 18017458693634389201, a count
// of 16, and the 16 bytes of the record.
Log_Fact :: struct {
	module_hash: [32]u8, // The hash of the module that holds the description of the fact: its own-hash place. Zero: no module.
	key:         u64, // The fact key: the typeid of the record type. Never 0 from `system.log_fact`.
	value_count: u16, // The bytes of `values` in use in this record, at most `LOG_FACT_VALUE_CAPACITY`: the kernel writes it.
	part:        u8, // The place of this record among the records of its fact, from 0: the kernel writes it.
	part_count:  u8, // The records of its fact, 1 to `LOG_FACT_RECORDS_MOST`: the kernel writes it.
	reserved:    [4]u8, // 0: the kernel writes it.
	values:      [LOG_FACT_VALUE_CAPACITY]u8, // The bytes of the record of the fact type from the place part * LOG_FACT_VALUE_CAPACITY, in the order of its fields.
}
// The bytes of a fact before its values: the least `length` of a fact.
LOG_FACT_HEAD_BYTES :: 48
#assert(offset_of(Log_Fact, values) == LOG_FACT_HEAD_BYTES)

// The bytes that a writer gives to `Log` of the form Fact: the head of a
// fact, then each value byte of its fact type, up to `LOG_FACT_VALUES_MOST`.
// The writer fills the module hash, the key and the values; the kernel
// writes the count, the part and the count of the parts of each record.
Log_Fact_Call :: struct {
	module_hash: [32]u8,
	key:         u64,
	value_count: u16,
	part:        u8,
	part_count:  u8,
	reserved:    [4]u8,
	values:      [LOG_FACT_VALUES_MOST]u8,
}
#assert(offset_of(Log_Fact_Call, values) == LOG_FACT_HEAD_BYTES)
#assert(offset_of(Log_Fact_Call, key) == offset_of(Log_Fact, key))
// The most bytes of `Log` of the form Fact.
LOG_FACT_CALL_BYTES_MOST :: LOG_FACT_HEAD_BYTES + LOG_FACT_VALUES_MOST
// A fact fills the bytes of a record after the name of the process, which
// end at the offset 64.
#assert(size_of(Log_Fact) + 64 == size_of(Log_Record))
// A value run names its start and its length in the text of its record
// with one byte each (value_kinds.Value_Run).
#assert(LOG_TEXT_CAPACITY <= 256)
#assert(size_of(Log_Head) == size_of(Log_Record))

// The stacks of the kernel. Each processor has one slot of addresses: a
// guard page with no memory, the kernel stack, a guard page, the stack of
// the double fault, then the interrupt stacks of the debug exception, the
// non-maskable interrupt and the machine check, each after a guard page,
// and guard pages to the end of the slot.
KERNEL_STACK_BASE :: 0xFFFF_FF00_0000_0000 // The slot of processor n starts at `KERNEL_STACK_BASE + n * KERNEL_STACK_SLOT_PAGES * 4096`.
KERNEL_STACK_SLOT_PAGES :: 32 // The pages of addresses of the slot of one processor.
KERNEL_STACK_PAGES :: 16 // From page 1 of the slot.
KERNEL_FAULT_STACK_PAGES :: 4 // From page 2 + KERNEL_STACK_PAGES of the slot.
// Each of the three other interrupt stacks. Each one holds only the frame
// and the report of a fault of the kernel: a debug exception of a process
// leaves it for the kernel stack at once.
KERNEL_INTERRUPT_STACK_PAGES :: 2
KERNEL_INTERRUPT_STACK_COUNT :: 3 // The debug exception, the non-maskable interrupt and the machine check.
// The first page in the slot of an interrupt stack (0: debug, 1:
// non-maskable interrupt, 2: machine check).
kernel_interrupt_stack_first_page :: proc "contextless" (stack_index: u64) -> u64 {
	return 2 + KERNEL_STACK_PAGES + KERNEL_FAULT_STACK_PAGES + 1 + stack_index * (KERNEL_INTERRUPT_STACK_PAGES + 1)
}
// The pages of the slot that hold a stack; each other page is a guard page.
KERNEL_STACK_SLOT_STACK_PAGES :: KERNEL_STACK_PAGES + KERNEL_FAULT_STACK_PAGES + KERNEL_INTERRUPT_STACK_COUNT * KERNEL_INTERRUPT_STACK_PAGES
#assert(1 + KERNEL_STACK_PAGES + 1 + KERNEL_FAULT_STACK_PAGES + KERNEL_INTERRUPT_STACK_COUNT * (1 + KERNEL_INTERRUPT_STACK_PAGES) < KERNEL_STACK_SLOT_PAGES)

// A run of pages that a page table gives, with one protection.
Mapping_Flag :: enum u64 {
	Write   = 0, // The pages can be written.
	Execute = 1, // The pages can be executed.
	Process = 2, // A process can use the pages.
	Large   = 3, // The table holds pages of 2 MiB.
}

// One run of a `Mapping_Report`: pages that follow each other in the
// addresses, with the same flags.
Mapping_Run :: struct {
	start:      u64, // The address of the first page.
	page_count: u64, // Pages of 4096 bytes.
	flags:      bit_set[Mapping_Flag;u64], // The protection of the run.
}

// The runs that a `Mapping_Report` holds. A table with more runs gives the
// count in `run_count` and the first runs only.
MAPPING_RUN_CAPACITY :: 96

// What the page table says, as the kernel reads it from the table itself.
//
// `Inspect` with the kind `Mappings` writes it, for the kernel half of the
// addresses or for the half of the process that asks. A test reads it to
// prove that no page is writable and executable and that each kernel stack
// has its guard pages: the report comes from the table that the processor
// uses, not from the records of the kernel.
Mapping_Report :: struct {
	run_count:           u64, // The runs of the table. `runs` has the first ones.
	runs:                [MAPPING_RUN_CAPACITY]Mapping_Run, // By address.
	pages:               u64, // The pages of all the runs.
	write_pages:         u64, // The pages that can be written.
	execute_pages:       u64, // The pages that can be executed.
	write_execute_pages: u64, // Always 0: no page is both.
	guard_pages:         u64, // Kernel half: the pages around the kernel stacks that have no memory.
	guards_expected:     u64, // Kernel half: the guard pages that the layout of the kernel stacks has. Equal to `guard_pages` when each guard is in place.
	kernel_guard:        u64, // 1: the processors refuse the memory of processes to the kernel, outside a copy.
	kernel_no_execute:   u64, // 1: the processors refuse to execute the memory of processes in the kernel.
}

// The record of how the machine started. A time is a number of
// microseconds since the machine started.
BOOT_STAGE_CAPACITY :: 12 // The stages of the start in a `Boot_Report`.
BOOT_RANGE_CAPACITY :: 64 // The runs of memory in a `Boot_Report`; the runs after it are counted in `firmware_ranges` only.

// One stage of the start of the machine: the boot program or the kernel
// timed it. See [stage](term:stage).
Boot_Stage :: struct {
	name:     [48]u8, // Zero bytes after the name.
	start:    u64, // Microseconds since the machine started.
	duration: u64, // Microseconds.
}

// A run of physical memory, as the firmware gave it. kind is a
// boot_info.Memory_Kind: 0 not usable, 1 free, 2 loaded by the boot program.
Boot_Range :: struct {
	start:      u64, // The physical address of the first page.
	page_count: u64, // Pages of 4096 bytes.
	kind:       u64, // A `boot_info.Memory_Kind`.
}

// boot_range_add adds a run of memory to a report. The runs come by
// address. A run that continues the last one, with the same kind, joins it.
// A run after the first `BOOT_RANGE_CAPACITY` runs is counted in
// `firmware_ranges` and not kept. A run of no page is counted and not kept:
// it holds no memory. A join whose end would pass the last address, or be
// exactly 2^64, is refused, and the run is a run of its own: the end of
// the last run would wrap to a low address and join a run that does not
// follow it. No physical memory is at the top, so the refusal of an end of
// 2^64 loses nothing.
boot_range_add :: proc "contextless" (report: ^Boot_Report, start, page_count, kind: u64) {
	report.firmware_ranges += 1
	if page_count == 0 {
		return
	}
	if report.range_count != 0 && report.range_count <= BOOT_RANGE_CAPACITY {
		last := &report.ranges[report.range_count - 1]
		last_end_fits := last.page_count <= (max(u64) - last.start) / 4096
		pages_fit := page_count <= (max(u64) - last.start) / 4096 - last.page_count
		if last_end_fits && pages_fit && last.kind == kind && last.start + last.page_count * 4096 == start {
			last.page_count += page_count
			return
		}
	}
	if report.range_count < BOOT_RANGE_CAPACITY {
		report.ranges[report.range_count] = {start = start, page_count = page_count, kind = kind}
		report.range_count += 1
	}
}

// How the machine started: the stages and their times, the memory that the
// firmware gave, the framebuffer, the sizes of the kernel and of the boot
// image, and the trust record of the boot program. `Inspect` with the kind
// `Boot` writes it. The kernel keeps it from the boot record; nothing in it
// changes after the start, but `time`.
Boot_Report :: struct {
	time:                   u64, // Now: microseconds since the machine started.
	stage_count:            u64, // The stages in `stages`.
	stages:                 [BOOT_STAGE_CAPACITY]Boot_Stage, // In the order of their start; `stage_count` of them are used.
	range_count:            u64, // The runs in `ranges`.
	ranges:                 [BOOT_RANGE_CAPACITY]Boot_Range, // By address. Neighbours of one kind are one range.
	firmware_ranges:        u64, // The ranges that the firmware gave.
	firmware_vendor:        [32]u8, // The name of the firmware vendor, as ASCII; zero bytes after it.
	firmware_revision:      u64, // The revision of the firmware, as the firmware gives it.
	framebuffer_address:    u64, // The physical address of the framebuffer. 0: no framebuffer.
	framebuffer_width:      u64, // Pixels.
	framebuffer_height:     u64, // Pixels.
	framebuffer_line:       u64, // Pixels from one line to the next.
	framebuffer_format:     u64, // A boot_info.Pixel_Format.
	kernel_size:            u64, // Bytes of the kernel in memory.
	kernel_file_size:       u64, // Bytes of the file of the kernel.
	boot_image_size:        u64, // Bytes of the boot image.
	direct_map_size:        u64, // Bytes of physical memory that the direct map of the kernel covers.
	acpi_root:              u64, // The physical address of the root table of ACPI. 0: none.
	cycle_frequency:        u64, // Cycles of the cycle counter per second.
	timer_frequency:        u64, // Counts of the timer of a processor per second.
	trust:                  info.Boot_Trust, // The trust record of the boot program, as it wrote it.
	// The remapping units of the IOMMU that translate the accesses of the devices. 0: no IOMMU in use, and
	// each device reaches all memory. Whether one device has a domain and device windows is the second
	// result of `Device_Create` of its registers (`Device_Memory_Facts`).
	iommu_unit_count:       u64,
	// The words of the start request of the boot program, as it wrote them: a
	// boot_info.Start_Request and a boot_info.Start_Request_Source, which the root
	// service reads through boot_info.start_request_of_words.
	start_request:          u64,
	start_request_source:   u64,
}

// The state of one process slot: its state, its name, its counts and what
// its budget still holds. `Inspect` with the kind `Process` writes it; the
// developer tools list the processes with it. A slot with no process gives
// zeros.
Process_Report :: struct {
	state:          Process_State, // `None` for a slot with no process.
	// The word of its `Stop_Cause`: 0 while the process runs. A record of the kernel holds the word, which a
	// reader takes through `stop_cause_of_word`.
	stop_cause:     u32,
	// The word of its `Stop_Outcome`: 0 while the process runs, and for each cause but `Itself`. A reader
	// takes it through `stop_outcome_of_word`.
	stop_outcome:   u32,
	name:           [PROCESS_NAME_BYTES_MOST + 1]u8, // The name that `Process_Create` gave; zero bytes after it.
	mapped_pages:   u64, // The pages of all its mappings.
	handle_count:   u64, // The handles currently in its handle table.
	run_time:       u64, // Milliseconds of processor time.
	entries:        u64, // Its kernel entries since its start.
	thread_count:   u64, // Its threads that did not end.
	start_time:     u64, // Microseconds since the machine started.
	budget:         Budget_Amounts, // What the budget that pays for the process still holds.
	present_pages:  u64, // The mapped pages that have a page frame.
	process_serial: u64, // A number that changes for each new process in the slot: two reports with the same serial are of one process.
	handles_peak:   u64, // Largest count of handles held at once since this process was created.
	mapping_count:  u64, // Mappings currently in its mapping table.
	mappings_peak:  u64, // Largest count of mappings held at once since this process was created.
}

// The context: the one record that a process receives when it starts, in
// place of text arguments that it must parse. The address of the record is
// the parameter of the entry.
//
// The record has 18 handles and 24 values of 64 bits. Its starter writes
// it and maps it read-write at `CONTEXT_ADDRESS` before the first thread
// runs (the kernel does both for the root service, which has no starter). A process finds each thing at a **fixed place**: the
// index of a handle or of a value is its role. So a process needs no name,
// no path and no parser to find what it was given:
// `ctx.handles[CONTEXT_LOG]` is its log, and a handle that its starter did
// not give is 0. A process that starts with a context of zeros has no
// handle: it can compute and stop, and reach nothing.
//
// Three groups of places exist:
//
// - **The places that the system fixes for every process**: the log, the
//   budget, the wiring ring, the seed, the fixed ranges that the starter
//   mapped. Every starter writes them in the same way.
// - **The places of the first process**, the root service: the kernel
//   writes them at boot, with every handle that exists then (the machine,
//   the framebuffer, the boot image, the records of the log).
// - **The places that a starter and its process agree on**: the handles
//   0 to 13 and the values 0 to 8. The root service gives each process the
//   handles of its grants there (`src/library/modus/system`, `GRANT_...`); a call
//   host receives its call ring at 0 and its call region at 1.
//
// A handle of the context has the rights that the starter chose, never
// more than the starter holds. Who starts a process decides what it can
// reach: the context is the whole of its authority at its start. The
// design: (docs/MODULE_CONTRACT.md, "The context").
//
// The handles 0 to 13 are the places of a starter and its process, and
// each is taken by some role. The handles 14 to 18 have the roles of the
// system below; a new role of the system takes the handle 19, never under
// 14. The handle 19 has no role yet.
CONTEXT_HANDLES :: 20
// The values 0 to 15 began as free values, and the roles of the system
// took 9 to 15 one after the other until two roles wanted one number. The
// values 16 to 23 are for the roles that the system fixes for every
// process: a new role of the system takes a number there, never under 16.
// A starter and its process use 0 to 8 for their own values.
CONTEXT_VALUES :: 24

// It holds no text: a process has nothing to parse.
//
// The starter writes the record in one page that it maps at
// `CONTEXT_ADDRESS` in the new process, and gives that address as the
// parameter of the entry. The process reads it once, at its start
// (`system.context_record`). Each starter and its process agree on the role of
// each index below 16; the roles that the system fixes have constants here.
// A handle at an index that the starter did not grant is 0. See
// [context](term:context).
//
// Example: the handle of the log is `handles[CONTEXT_LOG]`, the budget of
// the process `handles[CONTEXT_BUDGET]`, and the random seed the four values
// from `values[CONTEXT_VALUE_SEED]`.
Context :: struct {
	handles: [CONTEXT_HANDLES]Handle, // The granted handles. The role of each index below 14 is fixed by who starts the process,
	// from 14 by the system.
	values:  [CONTEXT_VALUES]u64, // Numbers that the starter gives: sizes, addresses, flags. The role of each index is fixed by who starts the process, from 16 by the system.
}

// The roles of the handles that the system fixes for each process. A
// handle that the process was not granted is 0.
//
// The handle 14: the log of the kernel, with the right **Write**. A process
// writes its lines with the kernel operation `Log` on it (`system.log`
// does). The starter gives it, and the root service gives it to each
// process that has the grant log; a call host gets it from the console.
// With no log handle, a line of the process goes nowhere.
CONTEXT_LOG :: 14 // The log of the kernel.
// The values 9 to 12: the random seed of the process, 32 bytes, that its
// starter writes (docs/RANDOMNESS.md). A start with a seed of zeros is
// refused. The root service has none: it gathers its own. A process does
// not use the values 9 to 12 for another role.
//
// The generator of the process (`src/library/modus/random`) reads the seed, then
// writes zeros over the four values: a copy of the context made later
// holds no seed. A starter makes the seed of each child from its own
// generator (`random.values_with_seed`).
CONTEXT_VALUE_SEED :: 9
CONTEXT_VALUE_SEED_COUNT :: 4 // The values of the seed: 4 values of 8 bytes.
// The value 16: the strength of the seed of the system, from which the seed
// of the process comes: the word of a Seed_Strength. The starter writes it
// with the seed.
//
// The seed itself cannot say how it was made: the generator of the process
// keeps this value. The handshake of `src/library/modus/quic` refuses a seed weaker
// than its least strength, and the process `randomness` shows it.
CONTEXT_VALUE_SEED_STRENGTH :: 16

// How strong the source of a seed is: the strongest source that gave all
// its values at the gathering of the root service. Its word crosses the
// context (CONTEXT_VALUE_SEED_STRENGTH), so each value is explicit, and the
// order is the order of the strength: `random.fill_for_a_key` refuses a
// seed below the strength that the caller asks.
Seed_Strength :: enum u8 {
	None      = 0, // No gathering yet.
	Weak      = 1, // The cycle counter only: no claim of entropy.
	Processor = 2, // rdrand: the generator of the processor.
	Entropy   = 3, // rdseed: the entropy source of the processor.
}

// The words of each strength, for a window, the log and a sentence.
@(rodata)
seed_strength_names := [Seed_Strength]string {
	.None      = "none",
	.Weak      = "weak (the cycle counter only)",
	.Processor = "processor (rdrand)",
	.Entropy   = "entropy (rdseed)",
}

// seed_strength_of_word reads the word of a strength. A word that names no
// strength is refused: a reader that took it for the strongest would make
// keys from a seed that nothing measured.
seed_strength_of_word :: proc "contextless" (word: u64) -> (strength: Seed_Strength, ok: bool) {
	for member in Seed_Strength {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// status_of_word reads the word of a status that a record of another
// process holds. A word that names no status is refused: a reader that
// named it with a known status would state a fact that the record does
// not hold.
status_of_word :: proc "contextless" (word: u64) -> (status: Status, ok: bool) {
	for member in Status {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}
// The value 17: the pass that the process `settings` runs with no window,
// the word of a settings.Pass: 1 for the pass at boot (it reads the
// settings kept in its store, writes the settings page, and stops), 2 for
// the next appearance that the Control Center asks (modus:contract/settings).
//
// The root service writes it when it starts `settings` for a pass; each
// other start of `settings` has 0 and opens its window. No other process
// reads this value.
CONTEXT_VALUE_SETTINGS_PASS :: 17
// The values 18 and 19: the address and the size of the second pointer
// theme file that the root service gives the compositor (the theme of the
// system, beside the theme of the owner at the values 6 and 7 of the
// compositor). The setting "pointer_theme" chooses between the two.
//
// The value 18 is the address where the root service mapped the file,
// read-only, in the compositor; 0 when it mapped none.
CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS :: 18
// The value 19: the size in bytes of the second pointer theme file at the
// address of the value 18. The compositor reads no byte past it.
CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE :: 19
// The value 20: a set of bits, bit n for the member n of the fixed ranges
// (modus:contract/fixed_addresses, Fixed_Range): the ranges that the starter
// mapped for this process. A set bit is the statement of the starter that
// the range is mapped; a process reads nothing at a fixed range whose bit
// is clear. It is a value of the context, which only the starter writes,
// and not a field of a shared page, which another process can write.
CONTEXT_VALUE_FIXED_RANGES_MAPPED :: 20
// The value 21: the size in bytes of the debug image, which the starter
// mapped at the fixed range Debug_Image (modus:contract/fixed_addresses) when its
// bit of the value 20 is set. The value 23 has no role.
//
// A process that prints a stop report (the console) reads the names of the
// procedures there; with no debug image, a report names offsets only.
CONTEXT_VALUE_DEBUG_IMAGE_SIZE :: 21
// The value 22: the machine runs for a measure (1), or not (0). See
// [measure run](term:measure-run).
//
// The root service writes 1 in the context of each process that it starts
// when the boot image holds the resource `measure_run`: the tool puts it
// in the boot image of `modustool measure` only. A process that starts a
// child copies the value.
//
// A process that measures a rate over a duration (reads in one second,
// records in one second) does so only when the value is 1
// (`system.measure_run`). With 0 it runs its checks, which end after a
// count of work, and writes no rate.
CONTEXT_VALUE_MEASURE_RUN :: 22
// The handle 15: the budget that pays for the process, with the rights
// **Give**, **Read** and **Spend**. Each page and each object that the
// process makes is paid from it; `Memory_Create` and `Process_Create` name
// it. The loader of the starter gives it, and a starter cannot put another
// handle at this place: the process receives its new budget here. The root
// service receives the root budget with **Commit** too. When the process
// stops, what the budget still holds returns to the budget of its starter.
CONTEXT_BUDGET :: 15 // The budget of the process.
// The handle 16: the wiring ring, a memory object with **Read** and
// **Write**, for a process whose module declares a record output or a
// record input; 0 for each other process. The root service gives each end
// of a wiring of the process on it (modus:contract/output, Wiring_Command),
// and gives the handle of each end through its memory, so the process
// proves that the handle came through it. See [wiring ring](term:wiring-ring).
CONTEXT_WIRING_RING :: 16 // The wiring ring.
// The handle 17: the output ring of the record output `log`, a memory
// object with **Read** and **Write**, when the wiring list of the start of
// the process wires `log`; 0 for each other process. The library writes
// there each log record that the kernel took, or refused for its budget
// alone, after it gave it to the kernel (modus:contract/output,
// Log_Output_Record). The end of `log` never goes
// through the wiring ring: a process whose only wiring is `log` has none.
// See [record output log](term:record-output-log).
CONTEXT_LOG_OUTPUT :: 17 // The output ring of the record output log.
// The handle 18: the end page of the wiring of `log`, with **Read** only:
// the root service alone writes its end words, so the writer learns that
// its reader stopped or closed, and no side forges the end of the other.
// 0 when the handle 17 is 0.
CONTEXT_LOG_OUTPUT_END :: 18 // The end page of the record output log.
// The values 13 and 15 have no role: the settings page and the date page
// are fixed ranges, mapped when their bit of the value 20 is set. A new
// role of the system takes a number from 16, never 13 or 15, so that an
// old reader cannot take a new value for a page.

// The roles of the first process (the root service).
//
// The handle 0: the machine, with every right of the machine. The kernel
// gives it at boot to the root service only. The root service gives a
// part of its rights to a process that has a grant for it (Inspect, Stop,
// Schedule, Physical): a machine handle reaches each process, so no other
// process receives it whole.
ROOT_MACHINE :: 0
// The handle 1: the memory of the framebuffer that the firmware set up,
// with **Give**, **Read** and **Write**; 0 when the firmware gave no
// framebuffer. The root service draws the boot display there, then gives
// it to the compositor, which owns the screen.
ROOT_FRAMEBUFFER :: 1
// The handle 2: the memory of the boot image, with **Give** and **Read**:
// every module and resource that the boot program checked. The root
// service starts each process from it, and gives it read-only to a
// process that has the grant image.
ROOT_BOOT_IMAGE :: 2
// The handle 3: the memory of the records of the log of the kernel, with
// **Give** and **Read**. The root service gives it, read-only, to a process
// that has the grant log_records, as the process that shows the log.
ROOT_LOG_RECORDS :: 3 // Memory, with Read: the records of the log.
// The handle 4: the memory of the debug image that the boot program read,
// with **Give** and **Read**: the names of the procedures for the stop
// reports. The kernel reads none of its pages.
ROOT_DEBUG_IMAGE :: 4 // Memory, with Read: the debug image that the boot program read. 0: none.
// The value 0: the width of the framebuffer in pixels; 0 with no
// framebuffer. The values 0 to 3 describe the handle 1.
ROOT_VALUE_WIDTH :: 0
// The value 1: the height of the framebuffer in pixels.
ROOT_VALUE_HEIGHT :: 1
// The value 2: the pixels from the start of one line of the framebuffer to
// the start of the next, which can be more than the width.
ROOT_VALUE_PIXELS_PER_LINE :: 2
// The value 3: the order of the bytes of a pixel, a `Pixel_Format` of the
// boot information (red first or blue first).
ROOT_VALUE_FORMAT :: 3
// The value 4: the size in bytes of the boot image of the handle 2.
ROOT_VALUE_BOOT_IMAGE_SIZE :: 4
// The value 5: the size in bytes of the debug image of the handle 4.
ROOT_VALUE_DEBUG_IMAGE_SIZE :: 5 // 0: no debug image.
