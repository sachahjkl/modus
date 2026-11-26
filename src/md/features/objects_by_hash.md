# One way to read an object

Status: Decided. An adversarial review comes before the code.

## Purpose

A process reads an object that is not its own code: a font, a pointer theme, the link pages of the manual, a glyph cache, a list. Today the system has a second way to do this, named "resource", next to the storage service. It is an older form of storage that was never replaced.

This file records the one form: **an object is read through the storage service, from a tree that the process was granted, the same way whatever channel brought the object**. The boot image becomes one more source of objects that the storage service serves. It is not a second system.

## The fault in the current form

Today the word "resource" names three things with no common call:

- **A file of the boot image that the root service maps into one process.** The root service finds it by name, maps its pages read-only, and writes its address and its size into two numbered context values that the receiver knows by heart. Example: the compositor reads its pointer theme at context values 6 and 7 (`src/modules/system/compositor/pointer_picture.odin`, `src/modules/system/root/resources.odin`).
- **A file at a fixed address range in each process.** The glyph caches, the font outlines and the script font set. The root service checks each one and maps it at a range of the process, outside any call (`src/md/features/glyphs_on_demand.md`... see the links below).
- **A search of the whole image** by a process with the grant `Image` (`system.image_resource_find`).

Each new kind of data added a code path in the root service and a contract of context numbers in a module. That corrupts the model of a module in three ways:

- **A module does not call for its data.** It reads numbers that its starter wrote at places that only the two agree on. A module of another project cannot use the mechanism, because no table of the root service names it.
- **The source decides the code.** The same font read from the image and read from a disk takes two different paths. This contradicts [`docs/STORAGE.md`](../../../docs/STORAGE.md), "1. The model": "The boot image is a transport, not a concept."
- **The root service holds data policy.** It chooses, checks and maps data for others. That is the work of the storage service.

## Constraints

- **Property 11.** The identity of an object is its hash. A name is for people and for the code that chooses.
- **Property 20.** No ambient access. A hash alone is not a right: hashes are public (in plans, in manuals, in logs).
- **One mechanism.** No second API next to storage. A call that a module makes for data is a call of the storage contract.
- **Same code for each channel.** A module reads its object with the same call whether the bytes came in the boot image, from a local disk, from the object cache or from a peer.
- **A process before the disk.** `unlock` and the compositor draw the passphrase screen before any disk is open or unlocked. They need fonts and a pointer theme at that time.
- **No hostile memory.** A receiver never maps a memory object that another client made: the lesson of `Memory_Read` and of the surfaces of the compositor ([window_resize.md](window_resize.md)).

## The chosen form

1. **No resource concept.** The boot image carries objects, as a transport. Its table of non-module files becomes the list of the objects of one read-only tree: the **image tree**. The terms "resource" and "resource of the boot image" leave the glossary and the guides.

2. **The storage service serves the image tree.** At its start, before it opens any disk, the storage service serves the image tree as a read-only store. It needs no disk and no key for it. The boot program and the root service already checked each object of the image against the signed system description, so the storage service does not hash these objects again: their identity is proved once.

3. **One call for a read-only object.** A process maps an object through the storage client. The normal form names the object; the hash is an option (point 4). The answer is a read-only memory object that the storage service made, its size, and a `Call_Outcome`. The receiver checks the format with the reader of that format, as today. The storage service checks the identity, not the format.

4. **A name is the normal address; the hash is the identity.**
   - A reader names an object by a path of entries in the trees that it holds, as people do: `pointer_themes/posy`, `fonts/noto_sans_hebrew`. Source code holds no hash.
   - The storage service resolves the name to exactly one object. A name that matches no object gives `Nothing_Has_That_Name`. A name that matches more than one object (two granted trees that both hold the name, or a name that a search pattern makes match two entries) is refused with `Argument_Refused` and a record that names each match. The system never chooses for the reader.
   - The answer gives the hash of the object beside the mapping. A reader or a plan that must keep exactly those bytes stores that hash and asks by hash the next time; the call then refuses another object under the same name.
   - The hash stays the identity and the check: the storage service proves the bytes by their hash, and a grant names a tree, never a name or a hash.

5. **The right comes from a grant of a tree.** A process reads only the trees that its start grants or the plan give it. Example: the compositor gets a read-only share of the tree of the pointer themes. The plan chooses which theme by naming its entry or its hash in that tree, as the plan already names the script font set.

6. **One memory object per object, shared.** Each reader maps the same read-only memory object. For the image tree it holds the pages of the image, with no copy. For a disk object the storage service keeps it while a reader maps it.

7. **The storage service starts first.** The storage service and its block driver are the chain that the root service loads directly from the image, with the loader of modules. That chain is the one exception: it reads modules, not data. Every process after it, the compositor and `unlock` included, reads its data through storage.

8. **Compiled-in data stays where it belongs.** Odin's `#load` puts bytes in a read-only segment of the module. That is right for data that changes with the code and is part of the module's identity. Data that changes alone is an object of a tree.

## What the form replaces

- The numbered context values of each resource (for example the pointer theme at values 6 and 7, then 18 and 19).
- `resource_mapping` and `pointer_theme_choice` in the root service.
- The fixed address ranges as a mechanism of delivery for the glyph caches, the font outlines and the script font set. A process can still map an object at a fixed place of its own; the place is its choice, not a contract of the root service.
- The grant `Image` and `system.image_resources`, `system.image_resource_find` for data. The loader of the storage chain keeps its direct read of modules.
- The read of the script font set by the root service through `disk_processes`: the set is an object of a tree, read through storage like every other.

## The refused forms

- **A resource API next to storage.** It is the fault this file removes: two systems that do the same work.
- **A hash in source code as the only address.** It makes a module change for each new version of its data. A name addresses; a hash pins, when a reader or a plan asks for that.
- **A choice among several matches.** An order of trees or a newest-wins rule would read data that the reader did not expect. An ambiguous name is an error that names each match.
- **A hash as a capability.** Hashes are public. A process that names a hash gets nothing without a grant of a tree that holds it.
- **One delivery path for each source.** The source is a fact of the storage service, never of the reader.
- **A name lookup inside the module, as `FindResource` on Windows.** It binds data to the code that reads it, and the data then cannot change alone.
- **A copy of the object in each process.** The memory object is shared and read-only.
- **The root service as the server of data.** It keeps the start of processes and the grants; data is the work of the storage service.
- **Data before storage, served by the root service.** It would keep a second server for the passphrase screen. The storage service serves the image tree with no disk, so the second server is not needed.

## Subtle points and hazards

- **Start order.** The compositor and `unlock` now wait for the storage service. The storage service must reach its first state of work without a disk: serving the image tree is its first work.
- **No encryption of the image tree.** It holds system objects, which are public. A principal's data is never in it.
- **A shared object across principals.** One memory object of a public system object, mapped by two principals, tells neither anything that the image does not already show. A principal's own objects are never shared this way.
- **Who pays.** The pages of the image tree exist since boot and cost nothing new. A disk object that the storage service keeps mapped is paid by the storage service's budget. That needs a bound of the kept objects, or a part of the reader's budget.
- **Boot verification.** The image tree inherits the check of the signed system description. A disk tree gets its identity from the hash index of the store.

## The owner's decisions

- **The storage service starts first,** before the compositor and `unlock`, and serves the image tree with no disk. It is the base; the other processes wait on it.
- **The storage service pays** for a disk object that it keeps mapped for its readers, with one bound of the kept objects, a value of the plan of principal 0. A reader does not state it: each reader would count the same object again.
- **Pinning is explicit.** A reader or a plan pins an object by its hash only when it asks for it; the storage service counts the pins of each object and shows them, so an unused pin costs nothing and a used one can be traced.
- **A name is a path in the trees of the reader.** It is walked entry by entry from a place that the reader holds, never from a root that the reader did not get. It names the same thing as a path of a usual file system, with no global path.

## State

Not built. Today the three forms of "Resource" listed above are built: [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "U2b. Resources of the boot image"; [script_fonts.md](script_fonts.md); [glyphs_on_demand.md](glyphs_on_demand.md). When this design is decided, those sections change to this form in the same commit as the code.
