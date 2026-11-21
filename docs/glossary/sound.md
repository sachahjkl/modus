## Sound

### Sound service

The sound service is the device service of the sound device: it plays the records of one timed stream, each at the time that it names, for one client through a stream ring.

The first one is the process `sound`, for a virtio sound device. The root service starts it when the process with the start grant `Sound_Device` starts, and stops it with that process: one process plays at a time. The client sends `Attach` with its sample region, `Start`, then `Play` for each record. The service fills each period from the records and plays silence between them. It is not a mixer: it sums no two streams.

The design: `src/md/features/timed_stream.md`.

Do not use: audio driver, sound server, mixer (for this).

### Stream ring

The stream ring is the ring between the sound service and its one client: one command record is `Attach`, `Start` or the `Play` of one record of frames.

The root service makes it and gives it to both, in the slot of the device ring of the client. The service answers the commands in order; the completion of a `Play` comes when the device took the period that holds its last frame, so a record holds one place of the ring until then. A completion that is not `Ok` carries an error record. It is not a queue of the device: only the service sees those.

The design: `src/library/modus/contract/timed_stream`.

Do not use: audio queue, PCM ring.

### Sample region

The sample region is the memory object of the client of the sound service that holds the samples of its records.

The client makes it from its own budget and lends it with `Attach`, with the right Read only: the service never writes it, and the device never reads it. A record names the place of its first frame in the region in bytes, never an address, and the service refuses a frame past its end. The service copies the frames of a record when it fills the period that holds them, so the client keeps them unchanged until the completion of the record.

The design: `src/library/modus/contract/timed_stream`.

Do not use: audio buffer, DMA buffer.

### Frame

In the group Sound, a frame is one sample of each channel of a timed stream: 4 bytes in the one format, the left sample first.

The frame is the unit of the time of a stream: 48000 frames play in one second, and a record names a count of frames. The sound service maps a time of the system clock to a frame. It is not the Ethernet frame of the group Devices, and not the frame of QUIC: each group of the glossary defines its own.

The design: `src/library/modus/contract/timed_stream`.

Do not use: sample (for this), tick.

### Sample

In the group Sound, a sample is the value of one channel at one frame: a signed 16-bit number in little endian.

Two samples, left then right, make one frame of the one format. The process writes them in its sample region; no service changes them. It is not the sample of a developer tool in the group Network, which is one read of its reports.

The design: `src/library/modus/contract/timed_stream`.

Do not use: frame (for this), PCM word.

### Period

In the group Sound, a period is the 480 frames, 10 ms, that the sound service gives the device in one request.

The service gives the device 4 periods, and fills a new one each time the device ends one: from the frames of the records, and with zeros where no record has a frame. The 4 periods are the latency that the service holds. It is not the period of 100 ms of a budget in the group Access.

The design: `src/md/features/timed_stream.md`, "The latency".

Do not use: buffer (for this), fragment.

### Stream clock

The stream clock is the map of the sound service between the system clock and the frames of its device: the frame of its anchor plays at the time of its anchor.

A process names the time of a record by the system clock (`system.nanoseconds()`), the clock of every process; the service maps it to the nearest frame. The anchor is set at `Start` and moves only at an underrun. A process never sees the clock of the device. The map corrects no drift of the device yet.

The design: `src/md/features/timed_stream.md`, "The stream clock".

Do not use: audio clock, presentation timestamp.

### Underrun

An underrun is a gap in which the device of a timed stream had no frame to play, because its service gave no period in time.

The device plays nothing in the gap. The sound service counts it, and moves its stream clock: the next frame plays at once. A record that it accepted keeps its frames and plays later than its time; its completion says when it played and counts the underruns. An underrun is a fault of speed, never a lost record.

The design: `src/md/features/timed_stream.md`, "An underrun".

Do not use: xrun, glitch, dropout.

### Utterance

An utterance is one record that asks the holder of the role `speech` to say a text: the text, its locale record, a priority (`Queue` or `Interrupt`) and a serial.

A screen reader writes utterances as a record output, and the speech holder turns them into frames of a timed stream. The conformance suite of the assistive role reads the utterances of a reader in place of sound. The queue of the utterances that wait has a stated capacity: a polite utterance that finds it full replaces the oldest polite one, and the count is said after. Designed, not built.

The design: `src/md/features/accessibility.md`, "5. Speech".

Do not use: speech request, TTS job, phrase.
