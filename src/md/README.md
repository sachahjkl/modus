# The intent of modus

This folder follows <https://srcmd.org>. It records why each part of the system has its form: the purpose, the constraints, the chosen form, each refused form with its reason, and the subtle points. It is written for a developer or an agent who starts work on a part.

Read this file first. Then read the file of the part that you change. Change that file before you change the code.

## What this folder is not

- It is not the documentation. A guide of `docs/` says what the system does and how to use it, and the site publishes it. An intent file links to a guide; it does not repeat it.
- It is not a record of who decided what, and when. Git keeps that.
- It is not a log of the work. A review, a log and a measure of one run do not go in the repository.
- It is not a plan. The planned work is in `ROADMAP.md`; a plan in progress goes in a folder `tmp/` that git ignores.

## The system on one page

modus is an operating system for x86-64, written in Odin, that runs on one fixed machine: QEMU with virtio devices, UEFI firmware and a TPM. The 21 properties of [`docs/PROPERTIES.md`](../../docs/PROPERTIES.md) are its rules. Each proposal is compared with them before any work.

**The kernel** (`src/kernel/`) is small and counted: 34 kernel operations. A program asks for an operation with a command record in a ring of shared memory, one ring for each thread. The one kernel entry runs the records of the ring, then waits. The kernel holds the handle tables, the memory objects, the page tables, the threads, the scheduler with a closed set of strategies, the budgets, the fault ring, the control of a thread, and the entry of a guest processor, whose nested page table is the page table of a program ([features/guest.md](features/guest.md)). It holds no driver, no file system, no network code, no loader for imports and no text parser. Its check of a line of the log is a filter of bytes, not a text parser: it writes `?` for each byte of an invalid sequence of UTF-8, keeps no state and builds no structure, as the check of the channel and of a program name does ([data/text_encoding.md](data/text_encoding.md)). It imports the contract packages only.

**The contracts** (`src/library/contract/`) are the records and the constants that two parties agree on: the kernel operations, the module format, the ring, the draw and block and frame records, the system description. A contract package holds no kernel operation call. **The support packages** (`src/library/support/`) are what a program compiles in to use the contracts: `system` (the kernel entry, the rings, the loader), `interface` and `graphics`, `tcp`, `quic`, `storage`, `sentence`.

**One code module** is the one format of compiled code. The same file is a program, a service, a library and a sandboxed program. A module describes each export in flat tables: the parameters, their types, their rights. From that description the console completes and checks a call, the manual shows a page, a call host isolates a call, and the loader checks a replacement. A module is named by the BLAKE3 hash of its file. An import names the hash of the imported file.

**The start.** The boot program (`src/boot/`, a UEFI application) checks the signed system description, measures into the TPM, loads the boot image and jumps to the kernel. The kernel starts one program, the root service (`src/programs/root`). The root service holds every grant at the start. It starts each other program with the grants of its role, serves the root ring (start, stop, connect, revoke, replace, debug), and keeps the table of the replacements.

**The programs** (`src/programs/`) are each one module in its own address space, with only the handles that it was given:

- Device services: `block`, `frame` (the network device), `input`. The code of a device is a program.
- Shared services: `storage` (one private store for each program, versions, no save action), `network` (the multiplexer of one network device), `settings`, `log`, `manual`, `debugger`, `remote` (calls from another machine over QUIC), `programs` (a module file from the network into the store `programs`).
- The desktop: `compositor` (the surfaces, the input, the bar, the palette), `terminal` (the window of a program that writes text), `console` (the language: a command is a function, a result has a kind and a drawer).
- About fifty programs that each show one property: `rights`, `origin`, `budget`, `scheduler`, `fault_ring`, `tally`.

**Communication** between two programs is shared memory: a ring of records and, for bytes, a region. A call of a service is a record in a call ring with its arguments in a call region. No program parses the text of another.

**The tool** (`tools/modustool`) is the only automation: the build (incremental, in two steps for a module, reproducible), the machine tests under QEMU with a peer for the network, the checks of the sources, the site, the changelog, the news, the films. `modustool check` and `modustool screenshots` with `nix flake check` are the full check.

## The subtle points

These are the points that an agent gets wrong most often.

1. **Compare first, then build.** A proposal that contradicts a property or the design of an intent file is named as such before any work. Propose the nearest form that keeps the property. A property changes in the documents first, then in the code.
2. **The described export is the only border between two modules.** There is no second kind of import. A parameter that a description cannot carry (a slice by value, a record that holds an address, a procedure value) means that the border is in the wrong place. The count of the parameters is not such a sign: an export takes up to 12 arguments, past the six registers on the stack. See [api/library_modules.md](api/library_modules.md) and [api/call_form_arguments.md](api/call_form_arguments.md).
3. **A new right for a program is the last answer.** First look for the program that already holds the grant, and give it a new face. The palette gives no program a new authority: see [features/palette.md](features/palette.md).
4. **The policy is outside the kernel, the mechanism inside.** No code of a program runs on the path of the scheduler. A write that a program chooses the moment and the direction of must change no history that a strategy keeps. See [features/scheduling_policy.md](features/scheduling_policy.md).
5. **A count, an offset or a length from another party is copied, then checked.** A value is never checked once and read again from memory that the other party can change. This holds for a table of another program, a file and a packet.
6. **No queue drops a record in silence.** A full queue stops its writer, or it has a stated capacity and counts each refusal on the log. See [features/key_path.md](features/key_path.md).
7. **A test checks a condition. A time in a test only ends a hang.** Never assert a speed, a duration or a rate: print it as a measure. Never wait a fixed delay for a state: wait for the state. See [`docs/TOOLS.md`](../../docs/TOOLS.md), "The bounds of the tests".
8. **The hash of a module is its identity, and many things change it.** A change of an import changes the hash of each importer. A path of a source file is in a debug object, not in a module. Debug information must not change the code. See [infrastructure/debug_information_and_code.md](infrastructure/debug_information_and_code.md).
9. **The kernel never imports a support package.** The compiler accepts such an import, because the system has one source library; the tool refuses it before each build. The kernel is freestanding: `"contextless"`, no allocator, no `fmt`. The build uses `-vet`: no shadowed local, no unused import. See [infrastructure/repository_layout.md](infrastructure/repository_layout.md).
10. **One term for one concept.** Define a term in `docs/GLOSSARY.md` before its first use, and never use a word of its "Do not use" list. A name in the code is long and of complete words.
11. **A document that says what the code no longer does is a fault.** A change of the code changes, in the same commit, the guide, the glossary, the README and the intent file that describe it.
12. **A comment in a source gives the reason in words.** It names no number of a property, a choice, a step or a review finding, no identifier of a decision, and no date. A pointer to a guide names a heading that exists.
13. **No text over another text, and no cut text, in any picture or page.** A text has a box. Compute its width from the font before you place it.
14. **No backward compatibility.** Change a format in place and remove the old path.

## The rules of this folder

- **One file for one part.** `features/` holds a capability that a principal or a program sees. `data/` holds a format or a table. `api/` holds a border between two bodies of code. `infrastructure/` holds the build, the tests, the site and the layout of the repository. A folder exists only when it holds a file.
- **A file exists only when a design exists.** Do not write a file for a part that has no design to record.
- **Each file has a title of level 1**, then its purpose, its constraints, the chosen form with its reasons, the refused forms, the subtle points and the hazards, and a short state: what is built and what is left.
- **High signal.** Omit what the code shows. Keep a measured number only when it decided a choice. Do not keep a plan of work, a list of files to change, or the steps of an agent.
- **The form of today.** When a design changes, the file states the new form, with one line on what changed. It is not a history.
- **No name of a person, no role of the project and no date.** Git keeps who decided and when.
- **No number of a decision, a choice, a step or a review finding.** An intent file states the reason itself.
- **A pointer to a guide** is a link with the path of the guide from the root as its text, then the heading in quotes: [`docs/CONSOLE.md`](../../docs/CONSOLE.md), "8. The palette provider". The tool checks that the heading exists.
- **A link between two intent files** is a relative link. The tool checks that the file exists.
- **The name of a file** has lower case letters, digits and `_`, and ends with `.md`.
- **Simplified Technical English**, with the terms of the glossary.
- `modustool check` runs the check `intent_index_check`: the file index below lists each other file of this folder exactly once, and names no file that does not exist.

## Where older intent lives

The intent of the parts that were built before this folder is in the design sections of the guides. They stay where they are, because the site links them.

- [`docs/PROPERTIES.md`](../../docs/PROPERTIES.md): the 21 properties, each with what it forbids, what it costs and what is open.
- The design sections of the guides: [`docs/MODULE_CONTRACT.md`](../../docs/MODULE_CONTRACT.md), "Closed rules"; [`docs/SCHEDULING.md`](../../docs/SCHEDULING.md), "5. What this system refuses, and why"; [`docs/TOOLS.md`](../../docs/TOOLS.md), "The debugger: the design"; [`docs/INTERFACE.md`](../../docs/INTERFACE.md), "10. The decisions of this design"; [`docs/DESIGN.md`](../../docs/DESIGN.md), the design rules of the interface.
- `docs/research/`: the studies of prior art that came before a design.

## File Index

- [api/call_form_arguments.md](api/call_form_arguments.md): why an export takes up to 12 arguments, the six past the registers on the stack, why the bound of six was refused, and why a bound stays
- [api/library_modules.md](api/library_modules.md): which shared library becomes a module that programs import, where the border goes, and why there is no second kind of import
- [api/module_replacement.md](api/module_replacement.md): who may replace a module: a replacement row signed by the key of a principal over the two hashes and the importer scope, the check of the root service at each `replace`, and the refused forms: a flag for tests, a signature over the new hash only, the description check alone
- [api/picture.md](api/picture.md): how a Picture record names its pixels with values in a picture memory that the caller passes, the draw export that takes the rectangles of a frame in one call, with the count of the calls before and after, the compositor that draws one part of its screen for each call with all its rectangles, and the forms that were refused: a table of places, lent memory objects, one span of addresses, a table of the parts
- [api/text_grid.md](api/text_grid.md): how the cells of a text grid cross the border of the drawing module in the text table of the frame, the count of the calls of a full terminal, and the forms that were refused: the compare compiled in, a second damage export, an export for one run of cells
- [data/text_encoding.md](data/text_encoding.md): one rule for text in every contract: UTF-8 with no control character, checked at each border with one contract package, a length in bytes, a cut after a whole character, the cell of a grid as a code point, one replacement glyph for a character that the font lacks, and the names that stay ASCII because they are identifiers of the system
- [features/debug_object_of_a_disk_program.md](features/debug_object_of_a_disk_program.md): where the debug object of a disk program is (beside its module file in the store `programs`, named by the hash of the module), the debugger service that reads it at an attach through a connection that reads only and that the root service ties to the debug access, its bounds and its check, and the refused forms: the object inside the module file, an object that names another hash
- [features/debugger_window.md](features/debugger_window.md): why the window of the debugger is a client of the service with no right over a program, how it reads the rows of the exports, the debug place that it types, its memory view, and a click on a row that does what a key does
- [features/foreign_systems.md](features/foreign_systems.md): why a foreign system runs whole inside a guest, and the forms of a Linux and an NT layer that were refused
- [features/gpu_access.md](features/gpu_access.md): the access to a GPU through a driver domain and one serialization of commands, and the forms that were refused
- [features/guest.md](features/guest.md): a guest as a program whose page table is the nested page table, the one operation Guest_Run with the exits as its completion records, the page on first use that the kernel gives, the state that the exit does not restore, and why Intel VMX first, a hypervisor in the kernel, a type-2 hypervisor and a Guest object kind were refused
- [features/heron_program.md](features/heron_program.md): the program that plays the animations of the mark: one source of each rule in `src/library/support/mark`, a move on the grid against the free way, and the fault of its window that made the rule of the whole frame
- [features/keyboard_layout.md](features/keyboard_layout.md): why the layout of the keyboard is a setting that the input service reads at each key, and why the compositor and a message at each change were refused
- [features/key_path.md](features/key_path.md): why no queue between the keyboard and a program drops a key in silence, and the two forms of a full queue
- [features/mark_pictures.md](features/mark_pictures.md): one generator for every picture of the mark, the two variants that a request names, the one table of the uses with the icons of the site, the formats that all start from the pixels of one picture, and why the browser computes no color
- [features/module_budget_request.md](features/module_budget_request.md): why a module states the budget that it asks for in its file, why its source states only its working memory, its threads and its window, the three parts that the tool counts from the files, and why the starter alone decides
- [features/palette.md](features/palette.md): the palette as a panel of the compositor with the console as its provider, and why no program gets a new right; the form of an entry from its descriptions: a control for each field, a number with its unit, a mode, go to by the act names of the windows
- [features/programs_from_a_disk.md](features/programs_from_a_disk.md): a program whose module file is an object of the store `programs`: why the command names the hash, the load as a state of the loop of the root service, the import scan that finds a library module of the store by the hash of its bytes, why its name gives it no grant, the module file service that stores a file from the network and lists the hashes with no new grant, and the disk grant table: a nickname bound to one hash, the store of the nickname, the grants that no command gives, and the table of principal 0 on the disk under the machine passphrase, with the key that only `unlock` opens
- [features/roadmap.md](features/roadmap.md): the planned work in one plain file, the check of its form, the rule that removes an entry with its changelog fragment, and its page of the site
- [features/scheduling_policy.md](features/scheduling_policy.md): the placement of a thread in the kernel, the share for each program outside it with the rule of one round, what the mechanism lacks, and the hazards that decided both
- [features/scroll_bar.md](features/scroll_bar.md): the scroll bar of the system and of the site from one table, its states, the pointer in the element, and where it leaves the design rules
- [features/site_bar.md](features/site_bar.md): why the bar of the site has three buttons and one menu on one line, and the forms that were refused
- [features/site_gallery.md](features/site_gallery.md): the gallery and the carousel of the site from one table that is checked against the folder of the pictures, and why the carousel needs no script
- [features/site_home.md](features/site_home.md): the home of the site: a line of time of the start on two stated scales, the rule "a chart or nothing" for a measure, a card that starts at its top, and a press on the heron
- [features/site_subscribe.md](features/site_subscribe.md): the menu "Subscribe" of the pages of the releases and of the news: a `details` element with the Atom feed of the page and the releases of the repository, a panel as wide as its longest line, and why a script menu, an RSS feed and a link to X were refused
- [features/text_box.md](features/text_box.md): one rule for a text that is wider than its place in a window: more lines, a break after a separator of a path, a height that the caller owns, and why a cut and a larger buffer were refused
- [infrastructure/assembler.md](infrastructure/assembler.md): why the build keeps `nasm` for the assembly files, and why the assembler of LLVM was refused
- [infrastructure/debug_information_and_code.md](infrastructure/debug_information_and_code.md): why a module is the same bytes with and without debug information, the kind of debug information that a build asks the compiler for, and the forms that were refused
- [infrastructure/iommu.md](infrastructure/iommu.md): why a device reaches only the memory that its service declared with `Memory_Physical`, the tables that the kernel owns on several remapping units, the devices behind bridges, the reserved memory ranges, the device window of an object that is not contiguous, the end of a grant before the frames are free, the queue of invalidations and the invalidation of one domain, a DMA fault as a line of the log, interrupt remapping with the entry of each message interrupt bound to its device and a forged interrupt as a line of the log, the side of the kernel that does not know the vendor and the design of AMD-Vi, which is left
- [infrastructure/llvm_of_the_build.md](infrastructure/llvm_of_the_build.md): why the build uses LLVM 18 with one upstream commit that makes dead store elimination work in a fixed order, the fault of the order of debug records that it removes, and the forms that were refused
- [infrastructure/network_data_path.md](infrastructure/network_data_path.md): what the network service does to the bytes of a packet, the constraint of one pair of queues, the layers that take the service off the data path, and the send with no copy: the read region of the frame service, the completion when the device read the data, who holds the memory until then
- [infrastructure/repository_layout.md](infrastructure/repository_layout.md): one `src` folder for what becomes the system, one source library `modus` for a program of a third party, and the order of the move
- [infrastructure/whole_frame.md](infrastructure/whole_frame.md): why every surface has two pictures, the debt of each picture in the window layer, the wait for the compositor with its bound, and the two counts that prove the rule
- [infrastructure/test_pointer.md](infrastructure/test_pointer.md): how a machine test presses an element by its element name: the line that a window writes when the rectangle of a named element changes, the palette whose lines the compositor writes, the window brought to the front before a press, and why a test build, a request to the window and a new contract were refused
- [infrastructure/third_party_module.md](infrastructure/third_party_module.md): the build of a module whose source is outside the repository: the module build file, where the tool finds the system, the rule of the three places of a source, and why the proof does not compare bytes
