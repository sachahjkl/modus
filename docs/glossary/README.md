# Glossary

The glossary defines each term of the system. Each concept has one term, and one term names one concept: the documents, the code and the names of the programs use that term and no synonym. A reader who knows another system finds here the word that this system uses, and why it does not use the word that the reader expects.

An entry starts with one sentence that says what the term is. The paragraphs after it explain it, in at most 100 words: what it is for, how a program gets it and uses it, the terms next to it, what it is not, an example from the system, and where its full design is. The last line, "Do not use", lists the words of other systems that the term replaces here.

## The groups

- [Code](code.md): the module, its exports and imports, and what describes them.
- [Running code](running_code.md): the program, its threads, the processors and the scheduler.
- [Access](access.md): the handle, its rights, the memory objects, the budgets and the grants.
- [Communication](communication.md): the rings, the calls between programs and the source library.
- [Devices](devices.md): the device memory, the interrupts and the IOMMU.
- [Network](network.md): the network service, its endpoints and its protocols.
- [Storage](storage.md): the objects, the stores and the tree on the disk.
- [Desktop](desktop.md): the surfaces, the compositor and the elements of the interface.
- [Text](text.md): the text encoding, the fonts and the glyphs.
- [Randomness](randomness.md): the seed, the generator and the entropy device.
- [QUIC](quic.md): the connections and the packets of QUIC.
- [Trusted boot](trusted_boot.md): the signing keys, the measures and the TPM.
- [Project](project.md): the documents, the units of the work and the site of the project.
- [Terms that the system does not have](terms_that_the_system_does_not_have.md): the words of other systems for concepts that this system removed.
