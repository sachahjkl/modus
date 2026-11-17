title: The tool fuzzes the readers of the system
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

The readers of modus that take bytes from the network or from a disk now get inputs that nobody wrote by hand. `modustool fuzz` runs the real code of the system on the host: the module file, the debug object, the storage format, QUIC and TLS, TCP and the head of an HTTP request.

LLVM adds an edge counter to the packages under test. The tool keeps each input that reaches new code, and makes the next inputs from it. Each input sits against a page with no access, so that a read one byte past it stops the run.

A fault is minimized to its smallest input and printed as the bytes of a host test. After its fix, the input joins the corpus of its target in the repository, and each `modustool check` runs it again with a fixed count of new inputs.
