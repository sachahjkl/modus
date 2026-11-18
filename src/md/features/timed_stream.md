# The timed stream, and sound through virtio-snd

A timed stream is a class protocol whose records say when their content must reach the device, not only what to do with it. Sound is its first user: a program plays samples through the sound device of the test machine, each record at the time that it names. Video, and the frames of a display at a rate, are the same class later. The order of this work and its reason are in [desktop_to_browser.md](desktop_to_browser.md), phase A. The device service follows [device_services.md](device_services.md).

The guide is [`docs/SOUND.md`](../../../docs/SOUND.md), "1. What a program does". The terms are in [`docs/glossary/devices.md`](../../../docs/glossary/devices.md), "Timed stream", and in [`docs/glossary/sound.md`](../../../docs/glossary/sound.md): "Sound service", "Stream ring", "Sample region", "Frame", "Sample", "Period", "Stream clock" and "Underrun".

## The constraints

- A device service holds the handles of its device and nothing else (property 7). The kernel carries no sample (property 5).
- The program that asks for the work pays for the memory of its samples (property 14).
- No queue drops a record in silence: a record that cannot play is refused, with a status and an error record.
- The test checks a condition, never a speed of the host.

## The stream clock

The time of a record is the system clock: the nanoseconds since boot that `system.nanoseconds()` gives, the same clock in every program. A program never sees the clock of the device.

The device has its own clock: the count of frames that it played. A frame is one sample of each channel, 4 bytes in the one format. The sound service keeps the map between the two clocks, the anchor: the frame `anchor_frame` plays at the time `anchor_time`. A time `t` at or after the anchor maps to the frame `anchor_frame + round((t - anchor_time) × 48000 / 10⁹)`, and a frame maps back the same way, rounded down. The contract package `timed_stream` computes both with no product that passes 64 bits: 48000 / 10⁹ is 6 / 125000, so the procedures divide by 125000 first and multiply the rest. A host test checks them against a reference at the edges.

The service sets the anchor at `Start`: frame 0 plays at the time of the answer of the device to its start. It moves the anchor only at an underrun (below). It does not correct a drift of the device clock against the system clock yet: on QEMU both clocks come from the clock of the host. On a real device a crystal differs by up to about 100 parts in a million, 0.36 s in an hour. The correction is left: the service will measure the rate from the times of the completions over a long window, and change the slope of the map.

The service sees the first sign of a drift today, in one direction. A device whose clock runs fast takes the periods faster than their time, so the frames given end further and further after now. When they end more than `AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS` (120 ms, three times the periods given) after now, the service holds the next period until the time comes, counts the hold, and writes one line at the first one. At its start QEMU takes some periods at once into its mixer, fewer than the periods given, so the bound is past what a device does at its start. A device whose clock runs slow is the other direction: it takes the periods late, and the latency grows with no sign that the service reads; the correction above covers it.

The stream adds no clock finer than the one that each program has: the completions name times of `system.nanoseconds()`, which reads the cycle counter. Row 17 of property 20 ("a precise clock is a grant") is not met today ([log_side_channels.md](log_side_channels.md) holds the side channels that are closed); the stream neither opens nor closes it.

## The record

One command `Play` is one record: the time of its first frame, its format, its count of frames, and the place of its samples in the sample region in bytes. The border `timed_stream.play_of_record` reads the record once from its copy, and gives a `Play` with its format as the enum, or the refusal. It refuses:

- a format word that names no member of `Format`, `None` included;
- a count of 0, or past `FRAME_COUNT_LIMIT` (10 s of frames);
- a place that is not a multiple of the frame size;
- a damaged record: a value past the four that the command names that is not 0.

`Attach` names one value and `Start` none; a value past them that is not 0 is a damaged record too (`timed_stream.damaged_value`), refused with `Bad_Command`.

The service then checks the place and the count against the size of the region, which it read once at `Attach`. The client can change the bytes of its samples at any time, and any bytes are samples: the service copies them when it fills the period that holds them, and reads no count or place from the region.

### A record whose time is past

A record is late when its first frame maps before the first frame that the service has not yet given to the device: the service cannot change a period that the device holds. It is refused whole, with the status `Late` and the earliest time that it could take (`limit`), and no frame of it plays.

Refused forms: play the part of the record that is still ahead, which cuts the start of a sound and moves what the program meant; play it at the earliest time, which shifts every later record of the program. A late frame of a video is dropped the same way.

### A record too far ahead

A record whose time is more than `AHEAD_LIMIT_NANOSECONDS` (10 s) after the earliest time is refused with `Too_Far`. The bound keeps each accepted record inside the table of the service, which has one place for each place of the ring, and keeps every time and frame of a record far from the end of 64 bits.

### The order of the records

The records of a stream are in the order of their time and do not overlap: a record whose first frame is before the end of the record accepted before it is refused with `Overlap`. Each frame then has one source, and the pending records are a queue. Mixing two records is mixing two programs, below.

## An underrun

The service keeps `PERIODS_GIVEN` periods of `PERIOD_FRAMES` frames with the device, 4 periods of 10 ms. It fills each period from the pending records, and with zeros where no record has a frame: between two records the device plays silence, and a stream with no record plays silence. The device never runs out while the service runs.

When the device completes every period that it holds before the service gives the next one, the service was late: an underrun. The device played nothing in the gap: QEMU writes no frame to its output, a real device plays silence. The service counts it, and moves the anchor: the next frame plays now. A pending record keeps its frames, so it plays later than its time by the gap; its completion gives the time at which it played and the count of the underruns. The service writes one line at the first underrun, and none after it: a loaded machine can give one each 40 ms, and the completions carry the count.

The test of an underrun is by time and not by count: the device can take several periods at once (QEMU takes them into its mixer at the start), so a device that holds no period is an underrun only when the time is past the end of the frames given.

## The latency

The latency that the service holds is the frames that it gave to the device and that the device did not take: from 30 ms to 40 ms. The earliest time that a record can take is the time of the first frame not given, so a program that wants a sound now asks for that time. The answer of `Start` gives the latency in nanoseconds; each completion of `Play` gives the time of its first frame by the stream clock.

A completion says that the device took the period that holds the last frame of the record, not that the frame played. The device adds its own delay after the take, which the service does not know: virtio-snd reports a `latency_bytes` in each status, and QEMU writes there the size of the period, not a delay. QEMU takes a period into its mixer, then into its output, so its latency is higher than the latency that the service holds, by the buffers of its mixer and of its output.

A shorter period gives a lower latency and more wakes of the service: 10 ms is 100 wakes in one second. The choice waits for a measure of underruns on a loaded machine.

## The format

One format: 48000 frames in one second, two channels, signed 16-bit samples in little endian, the left one first (`Format.Signed_16_Stereo_48000`). The device service sets the device to it at its start. A record names its format so that a second format is one more member and one more conversion, and a record of the old programs never plays in the wrong format: the border refuses a word that names no member.

## The budget and who pays

- **The client** makes the sample region from its own budget and lends it with `Attach`, with the right Read only: the service never writes it. The service closes each handle that came through the ring and that it refuses (a second region, a handle that is not memory, a handle with no Read, a damaged `Attach`), so it keeps no handle that it does not use. It never closes a handle that did not come through the ring: such a number can name a handle of the service itself (`sound_device.attach_decision`).
- **The sound service** pays for its copy of the periods, from the budget that the root service gives it by its name. It declares that memory to the IOMMU with `Memory_Physical`: the device reads the periods and the requests, and writes the statuses, and reaches no other memory. It never declares the sample region, so the device never reads memory of the client.
- **The root service** pays for the queues of the device (`pci.QUEUE_PAGES`), as for each device service.

A copy in the service costs one pass over each sample. It is there because the service places the samples of a record at the frame of its time inside a period, with silence around them; the device reads whole periods.

## One program at a time

One program holds the stream: the program with the start grant `Sound_Device`. The root service starts the sound service for it, and stops it when that program stops, as for a block service. A second program with the grant does not start while the first runs: the root service refuses it with the status `Bad_State` and one line. Nothing is mixed.

The refusal lasts a little past the end of the first program. When it stops, the root service stops the sound service, and the place of the sound service stays in its table until the stop of that program is read; a start in that time gets the same `Bad_State` and line. A second try after the reap starts.

The stream ring has the capacity of the contract, `RING_CAPACITY`, and the table of the pending records one place for each place: the service stops at its start when its ring is larger.

Mixing is a sound service of the class, between the programs and the device service, as the storage service is between the programs and the block service: each program gets a stream of its own, and the class service sums the frames of each period. It waits for a second program that plays sound.

## Capture

Capture is later. A program that reads the microphone holds a device queue behind a grant, with a visible indicator while it is in use ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 9). A captured record is the same record: the time of its first frame, its format, its count and its place.

## The device: virtio-snd

The sound service drives a virtio sound device (virtio 1.2, section 5.14; QEMU `virtio-sound-pci`) at the fixed place `pci.SOUND_DEVICE`. It uses the control queue and the transmit queue only:

1. It reads the configuration of the device (the jacks, the streams, the channel maps), and asks `PCM_INFO` for the streams, at most `STREAM_LIMIT`. It takes the first output stream whose formats, rates and channels hold the one format.
2. It sets the parameters of that stream (`PCM_SET_PARAMS`: the period and the buffer of the device in bytes, the format) and prepares it (`PCM_PREPARE`).
3. At `Start` it gives the device the periods and sends `PCM_START`.
4. Each period is a request of the transmit queue: a header with the stream, the frames of the period, and a status that the device writes.

The device writes its answers and the statuses. The readers of them are pure procedures in the private part `src/library/private/sound/sound_device`, with host tests: a code shorter than its size, a refused code, a `PCM_INFO` with fewer records than asked, a used entry that names no first descriptor, no period in flight, a period out of order, and a status that is not Ok.

**The order of the periods.** The service requires that the device ends the periods in the order in which it gave them, and stops on a device that breaks it. A period completes the records up to its end, so a period ended out of order would complete a record whose earlier frames the device still holds. The service could instead complete only up to the oldest period in flight, but a device that reorders the periods of one stream plays them out of order too, and no record can be right on it. QEMU 10.2 ends them in order: its stream is one queue.

**A device that does not answer.** A control request waits for its answer until the one hang bound of a program, `system.TEST_HANG_BOUND_MILLISECONDS`: a device answers in microseconds, and the bound only ends a hang. At the start of the service, the service then writes a line that names the request and stops. At `Start`, it first answers the client with `Device_Error` and the record `No_Answer`, then stops, so the client is not left waiting.

QEMU 10.2 consumes a request of the transmit queue when its frames reach its mixer, and its wave output writes the frames that the stream gave: with no request, the output gets no frame. The proof below does not depend on that.

## The proof

The machine test `sound` starts a machine with `virtio-sound-pci` and an output to a file (`-audiodev wav`), at 48000 frames in one second and two channels, so QEMU converts no rate. The program `tone` starts the stream, asks for a tone of 440 Hz of 500 ms at 500 ms after the frame 0, and writes the frame where it played. It checks that the frame is the frame of its time, and, with no underrun, that it played at the time of that frame. It also sends eight commands that the service must refuse (a second region, a damaged `Start`, and six records), and checks each status and error record.

The tool then reads the file. It finds the tone by its own start, the first frame that is not silence, and measures it as a span to its last frame that is not silence. A frame of 0 is a frame of the tone: a cosine has samples of exactly 0 at some crossings (here every eleventh one), so a count of the frames that are not silence would miss them. A run of silent frames inside the span longer than one period of the tone (109 frames) is silence that the device wrote, and counts in neither the length nor the window; a crossing is a run of one frame or two. The checks come in the order of their faults:

- **The window.** The file holds 4800 frames from the start of the tone; else it is too short.
- **The frequency.** The left channel over the first 4800 frames of the tone crosses zero 88 times, within 2: a tone of 440 Hz. A frame of 0 keeps the sign before it, so a crossing on it counts once.
- **The length.** The span, less the inserted silence, is the 24000 frames of the tone, within 2: a crossing on its first or its last frame.
- **The place.** The tone must not start before the frame that `tone` names: the file then holds fewer frames before it than the stream gave, a frame lost. When it starts at that frame, within 2, the file starts with the frame 0 of the stream and the place is proved. When it starts later, the device wrote frames that the stream did not give (a backend that pads by its timer, at a stall of the host): the test passes and says that the place is not proved, with the count of those frames.

What the check proves: the service gives the device the frames of the record, whole and in order, and with a file that holds only the frames of the stream, at the frame of their time. What it cannot prove: the time of the host at which the device played a frame, and the place of the tone when the device writes frames of its own. Silence that the device writes inside the tone changes neither the frequency nor the length that it counts, when it lasts more than one period of the tone; a shorter run of inserted silence counts as a part of the tone, and fails the length.

The tool reads the samples to the end of the file and does not trust the sizes of its header: QEMU writes them only at a clean end.

Refused forms of the proof: a recording of the sound card of the host, which a test machine in the sandbox does not have; a check of the time of the host at which a frame was written, which depends on the speed of the host; a Fourier transform, where a count of crossings is enough for one tone.

## The refused forms

| Form | Why refused |
|---|---|
| The time of a record in frames of the device | A program would need the clock of the device, and two devices would have two clocks. The system clock is one for every program |
| The device reads the samples in the sample region | The device would reach memory of the client, and the frames of a record rarely fall on a period |
| A late record played in part, or at the earliest time | It changes what the program meant, in silence |
| Records that overlap, summed | That is mixing; it waits for a class service |
| A second program that waits for the first | A wait in the root service that no principal sees; the refusal with its line says what holds the device |
| A drift correction now | QEMU has no drift to measure; a correction that no test checks is a guess |

## State

Built: the class protocol in `src/library/contract/timed_stream` with its host tests, the sound service `sound` for virtio-snd with the readers of the device answers in its private part and their host tests, the hold of a device that takes the periods too fast, the start grant `Sound_Device`, the program `tone`, and the machine test `sound` with the check of the file. Left: the correction of the drift, capture, mixing in a class service, a second format, and a measure of the underruns on a loaded machine.
