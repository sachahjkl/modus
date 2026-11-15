# Roadmap

This file holds the planned work of modus. **Now** is the work that is in progress. **Next** is the work that is decided and comes after. **Later** is the work that is wanted and has no order. An entry leaves this file in the commit that ends its work.

## Now

- **The terminal and the compositor import the drawing module.** The terminal, whose text grid needs the cells of two frames for its damage, and the compositor, which shows the surfaces of other programs as pictures, use the drawing module, as 32 programs do today. The code of the drawing is then loaded one time, and one correction reaches every program. [Design](src/md/api/picture.md)

## Next

- **The grants of a disk program of a named principal persist across a restart.** A named principal grants a disk program from its own session, and its signed disk grant table is read after the unlock, as the table of the machine is after the machine passphrase. The monitor and the menu show each nickname with its hash. [Design](src/md/features/programs_from_a_disk.md)
- **A disk program imports a module of the store of the programs.** The root service finds each import of a disk program by its hash in the same store, reads it with the bounds of a load, and checks its hash. A developer then adds a program and its library modules to a machine that runs. [Design](src/md/features/programs_from_a_disk.md)
- **The debug object of an outside module in a machine.** The debug image of a machine holds the debug object of a module that runs from a disk. A stop report of that module then names its procedures and its lines, and the debugger shows its source. [Design](src/md/infrastructure/third_party_module.md)
- **A key sealed by the TPM, and a recovery key.** The TPM releases the key of a principal and the machine key only to the system whose measure it holds, so an older or a changed system opens no store and no grant; the grants of the machine then persist with no passphrase. A principal who loses the passphrase opens the stores again with a recovery key. [Design](src/md/features/programs_from_a_disk.md)
- **The IOMMU of AMD, and interrupt remapping.** A device on a machine with an AMD processor reaches only the memory that its service declared, as on Intel, and a device cannot send an interrupt that its service was not given. [Design](src/md/infrastructure/iommu.md)
- **A guest.** A program runs another system in a guest, with the virtualization support of the processor. The first guest writes to a port, and the write arrives as a record in the program that runs it. [Design](src/md/features/foreign_systems.md)

## Later

- **An outside module imports another outside module.** The import of a module of another project names a module of the same project, and not only a module of the system. A developer then writes a library module and the programs that import it outside the repository. [Design](src/md/infrastructure/third_party_module.md)
- **The option for the debug information in the compiler of the Odin project.** The kind of debug information that adds no instruction is offered to the Odin project. A developer then builds the modules of the system with the compiler of that project, with no fork. [Design](src/md/infrastructure/debug_information_and_code.md)
- **Linux in a guest.** A principal runs Linux, and the programs of Linux, in a guest beside the programs of the system. [Design](src/md/features/foreign_systems.md)
- **Programs of NT.** A program of NT runs through Wine inside the Linux guest, with no work of its own in the system. [Design](src/md/features/foreign_systems.md)
- **Acceleration by a GPU.** The one graphics interface of the system runs in software first, then on the virtual GPU of the test machine, then on a real GPU through a driver domain. The GPU then draws the windows and the pictures, and not the processor. [Design](src/md/features/gpu_access.md)
- **A receive queue for each endpoint.** On a device that has several queues, the frames of an endpoint arrive in the memory of its program. The network service then leaves the path of the data that a program receives. [Design](src/md/infrastructure/network_data_path.md)
- **The stores of a principal are encrypted.** The storage service encrypts the stores of a principal with the key of that principal. A reader of the disk who has no key reads no object.
- **Several principals, and one identity on several machines.** More than one named principal uses a machine, each with its own session and its own stores. A principal has the same identity on another machine, and a grant can be signed for a principal of another machine.
- **A grant for the key of a client of `remote`.** The principal gives the public key of a client to the program `remote` as a grant that can be revoked. A call from another machine then acts only for a principal who allowed that client.
- **Processor counters for a program.** A program reads the counters of the processor for its own code, such as the cache misses. A developer then measures the cost of a data layout, and not only its time.
- **A pager for another program.** A program answers the page faults of another program and supplies its pages.
- **Every window uses the interface package.** The windows of the programs that still draw by themselves are built from the elements of the interface package. Each window then has the same look, the same keys and the same damage rules.
- **The wheel of a pointing device moves a view.** The wheel moves the view that is under the pointer: the lines of a terminal, a list, the palette. A principal then reads a long content with no press on a scroll bar. [Design](src/md/features/scroll_bar.md)
- **Characters outside ASCII.** A key gives a character of Unicode, so the layout of France gives é, è, ç, à and ù. A principal then types the words of a language other than English.
- **The program `manual` opens the links of a page.** A link to a term, a guide or a declaration in the documentation of a module opens its page in the program `manual`. Today only a link to a module or to an export opens.
- **The console colors each field by its value kind.** The description of a field of a record states its value kind, so the console draws a size, a time or a handle in a field in its color. Today a field has the color of its type only.
- **The history of a store.** A version is a state of a whole store, and the versions of each object are found in it. A principal then steps a store back as one thing, not object by object.
- **The same object is kept one time.** The storage service finds an object by its hash, so an object that two entries name takes its blocks once.
- **A faster switch between threads.** A processor that takes again the thread whose extended state its registers hold skips the restore of that state. A measure gives the gain.
- **The history of each measure, release by release.** The measure record keeps the numbers of each release, and the site draws a chart of each measure over the releases. A reader then sees whether a change made the system faster or slower.
- **Measures on a quiet host.** The numbers of the windows, of the calls, of the vector forms and of QUIC are measured on a host with no other load. A reader then compares them from one release to the next.
- **LLVM 22.** The build uses LLVM 22, with a measure of the speed of the code before and after.
- **A block device that drops a write, as a test.** A test runs the storage service on a block device that drops one write, and checks that the service finds the fault at the next start. The rule that a lost write is found then is a test, not a sentence.
- **The share policy counts a thread that starts and ends between two rounds.** A program that creates threads which end before the next round of the share policy gets no more of the processors than a program with one thread. [Design](src/md/features/scheduling_policy.md)
