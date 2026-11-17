# The entropy device

## Purpose

The seed of the system comes from the processor: `rdseed`, `rdrand` and the jitter of the cycle counter. A processor whose generator is wrong or hostile then fixes every seed of the boot, with no sign. The fixed machine has a second source: the entropy device of virtio (`virtio-rng-pci` in QEMU). This design reads that device and mixes its bytes into the random generator of the root service, so that each seed that the root service gives after the read depends on the processor and on the device together.

The guide is [`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "3. The seed of the system, and what is claimed". The terms are in [`docs/glossary/randomness.md`](../../../docs/glossary/randomness.md): "Entropy device", "Entropy service", "Entropy report".

## Constraints

- **The code of a device is a program** (property 7). The root service holds the ports of the configuration of the bus; it does not drive a queue.
- **No seed waits for a device.** No program runs before the root service, so its first seed comes from the processor. A device that does not answer must not stop the start.
- **The device is one more source, never the only one.** The bytes of a device can only add to the seed. A device that gives zeros, the same bytes twice, or nothing, leaves the generator as it was.
- **The claim stays the claim of the processor.** The seed strength says what the system can claim. The system cannot check the bytes of a device, as it cannot check `rdseed`.
- **A value from another party is copied, then checked**: the count of bytes in a completion, and the length that the device writes in its ring of used chains.

## The chosen form

**The entropy service** is the program `entropy`: the device service of the entropy device. It has what each virtio device service has (the registers, one message interrupt, the memory of the queues, the machine with the right Physical, a copy of the configuration) and the entropy ring, and nothing else. It drives one queue of the device, with one request in flight. The buffer of a request is in the memory of the queues: the device reaches no other memory, and with the IOMMU only that memory.

**The place.** The device is at the place `pci.ENTROPY_DEVICE` of bus 0, as each device of the fixed machine is at a fixed place. The root service reads the identity there after the compositor starts. With no virtio entropy device at that place, it writes one line at the level information and starts no service:

`root: no entropy device at the place 19 of the bus: the random seed of the system has the sources of the processor only`

**The ring.** The root service is the one client. The contract `entropy_service` has one command, `Read`, with a count of 1 to `READ_BYTES_LIMIT` (48) bytes. Its completion carries the bytes in the six values after the count, so the ring needs no region. The service answers each command in order.

**How much, and when.** At its start the root service puts two commands `Read` of 32 bytes in the ring: 512 bits, as many as the 8 values of `rdseed`. It does not wait for them. Its loop reads the completions with the other rings, and mixes each one into its generator with `random.device_bytes_mix`, which calls `reseed`: the next key is BLAKE3 of a domain text, the old key and the bytes. When both completions are in, it writes one line:

`root: the entropy device gave 64 bytes in 2 reads: 64 bytes mixed into the random generator of the system; refused reads: 0`

Each program that the root service starts after that line has a seed from the stream of the new key. The programs before it (input, the compositor, and the programs that start while the device answers) have a seed from the processor only. The service stays and waits for the next command: after the reads of the start, the root service asks for one read every 30 seconds, and gives each running program 32 bytes of its stream after each one ([fresh_bytes.md](fresh_bytes.md)).

**A read that adds nothing.** `random.device_bytes_mix` refuses a read and leaves the key as it was when:

- it has no byte;
- all its bytes have one value: zeros, all ones, or any one byte again;
- it has the bytes of the read before it (the mixer keeps the BLAKE3 hash of that read, not its bytes).

A refused read counts in the entropy report (`device_reads_refused`) and in the line of the root service. Its bytes count for nothing. A completion with an error (`Bad_Command`, `Device_Error`) counts there too: it is a read that added nothing, and one count keeps the line short. The line of the warning of that completion names its cause.

These checks find a broken device: a model that gives zeros, or a buffer that it never wrote. They are not a protection. A hostile device passes them with ease (two values, or a read that comes back after another one). The protection is the mix: the old key is always an input of the new one.

**The entropy report** says whether the device is there, the bytes mixed and the reads refused. The program `randomness` shows them, from the context values 0 and 7.

## Refused forms

- **The device as the seed, or as the only source.** A device model that the host fakes, or a broken one, would then fix each seed. Mixed into the key, its bytes cannot remove what the processor gave.
- **A higher seed strength from the device.** The strength must hold for each seed of one boot; the programs that start before the answer have no device bytes. The bytes also come from the host, which the system cannot check. A strength for the device needs its own design.
- **A wait for the device before the first program.** A device that does not answer would stop the start, and the seed of the processor already holds the claimed strength.
- **The queue code in the root service.** A fault in it would stop the root service, which holds every grant. A device service stops alone.
- **The device in the program `randomness`.** That program is a window that any principal starts; a device grant there would give a viewer a device.
- **A region for the bytes.** One completion holds 48 bytes; a read of 32 bytes needs no second memory object.
- **A service that gives each program its bytes at each draw.** It is refused for each source ([`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "1. Where a program gets random bytes"): a call for each draw, and one shared state for all programs.

## Subtle points

- **The bytes in the ring are not a secret alone.** They stay in the shared ring after the root service read them. The key also depends on the seed of the processor, so a reader of those bytes does not learn the key. The service erases its own buffer and copy after each completion.
- **The root service reads one completion for each read that it asked, no more.** Each command carries the number of its read in its tag, and a completion with another tag counts as a refused read: a service that writes a completion that was not asked for adds no bytes. The root service waits on the ring only while a read is in flight.
- **The device can say that it wrote more than it was asked.** The service takes the smaller of the two lengths. The root service takes the smaller of the count of the completion and `READ_BYTES_LIMIT`.
- **The used ring is read at each wake.** A device that moves its used index with no read in flight would else keep the loop of the service awake for ever. Such an entry stops the service with the line `entropy: the device used a read that was not given`, as a device that needs a reset does.
- **A device that never answers.** The service waits for its interrupt for ever. The root service never writes its line, asks for no read of a refresh while a read is in flight, and the system runs with the seed of the processor. A stop of the service before both answers writes a line at the level warning; a stop after them writes the line of the end of the fresh bytes.
- **The budget pays for the domain.** With the IOMMU on, the first `Memory_Physical` of the service makes the domain of its device, and the tables of that domain are paid from the working memory of the service ([iommu.md](../infrastructure/iommu.md), "Device addresses"). The service states the working memory of the block service. A first amount of 16 pages, as for the TPM service, which has no device of the bus, made that call fail on the machine with the IOMMU; the service then stopped, and the kernel cleared the entry of its interrupt, which the device then named.
- **The message interrupt.** The root service gives each device service the entry 0 of the table of MSI-X. The tool gives the device two vectors (`vectors=2`), so the device has a table.

## State

Built: the entropy service, the contract, the place of the device, the two reads at the start, the mix with its refusals, the report in the window of `randomness`, a machine of `modustool test random` with the device and two without it, the device on the machine of the part `iommu`, whose two reads arrive through the remapping unit of Intel, and the reads of the fresh bytes ([fresh_bytes.md](fresh_bytes.md)).

Left: a strength that the device can claim.
