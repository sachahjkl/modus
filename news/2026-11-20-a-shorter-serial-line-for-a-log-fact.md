title: A shorter serial line for a log fact
date: 2026-11-20
release: next
picture: none
kind: Decided
guide: docs/TOOLS.md

modus is an operating system with a small kernel. A program writes a line of its log as a log fact: a record of fields with no text, which a reader writes as a sentence from the module file of the program.

The serial port writes a fact as bytes: `#1a2b3c4d:fa0adf 0cm1a23h1a2b`. The first part names the module by the first 4 bytes of its hash, the second the fact type by the first 3 bytes of its key. A value byte is two hexadecimal digits, and a run of zero bytes is one letter, from `g` for 1 byte to `z` for 20: `m` is the 7 zero bytes of the number 12 in a field of 8 bytes.

The form before wrote the whole key and each zero byte, and took 1.9 times the bytes of the same lines as text. On the facts of three machines of one full check, the new form takes 0.94 to 0.98 times those bytes. A byte costs about 22 µs on the serial port under KVM, so a flood loses fewer lines.
