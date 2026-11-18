# Sound

This guide says how a program plays sound: the timed stream that it writes, the sound service that plays it, what the service refuses, and how the test proves the time of a sound.

The terms are in `glossary/devices.md`: timed stream; and in `glossary/sound.md`: sound service, stream ring, sample region, frame, sample, period, stream clock, underrun. The design is `src/md/features/timed_stream.md`.

**The idea in plain words.** A program writes its samples in memory of its own, then sends records to the sound service through a ring: "play these frames at this time". The time is the clock of the system, which every program reads; the program never sees the clock of the device. The service puts each frame at its time, plays silence between the records, and says when each record played. A record that comes too late plays nothing and is refused, with the earliest time that it could take.

**For whom.** A reader who writes a program that plays sound, and a reader who must know how exact the time of a sound is.

**Read before.** `ARCHITECTURE.md`, "U4. Device services".

**The map of this guide.** Section 1: what a program does. Section 2: what the service refuses. Section 3: the time, the latency and an underrun. Section 4: the test. Section 5: what is not built.

## 1. What a program does

A program that plays sound has the start grant `Sound_Device`. The root service then starts the sound service `sound` for the sound device of the machine, and gives the program the stream ring in its context, at `timed_stream.GRANT_RING`. One program plays at a time.

1. **The samples.** The program makes a memory object from its own budget, the sample region, and writes its frames there. A frame is one sample of each channel: 4 bytes, the left sample first, each a signed 16-bit number in little endian, at 48000 frames in one second (`Format.Signed_16_Stereo_48000`).
2. **`Attach`.** It gives the region to the sound service through the stream ring with the right Read only (`system.give`), and sends `Attach` with the handle that the give returned. The service never writes the region, and the device never reads it.
3. **`Start`.** The stream starts, and the device plays silence. The completion gives the time of the frame 0 of the stream, the latency that the service holds in nanoseconds, and the format.
4. **`Play`.** Each record names the time of its first frame (`system.nanoseconds()`), its format, its count of frames, and the place of its first frame in the region in bytes. The completion comes when the device played its last frame: the time at which its first frame played, that frame of the stream, and the count of the underruns since `Start`.

The program keeps the samples of a record unchanged until its completion: the service copies them when it fills the period that holds them, as late as it can.

The records of a stream are in the order of their time and do not overlap. The service plays silence between two records, and before the first one.

The ring has 32 places. The service takes a command only when the ring of the completions has a place for it and for each record that waits: a program that sends more waits for room, and no record is dropped.

## 2. What the service refuses

A record that cannot play gets a status and an error record, and no frame of it plays.

| Status | When | The error record |
|---|---|---|
| `Bad_Command` | A word that names no command; a format that names no member; a count of 0 or past 480 000 frames (10 s); a place that is not a multiple of 4; a value past the four of `Play` that is not 0; `Attach` or `Start` a second time | `Bad_Value`, `Too_Small`, `Too_Long`, `Not_Multiple` or `State`, with the number of the value |
| `Out_Of_Range` | A frame of the record is past the end of the region | `Out_Of_Range`, unit `Bytes`: the end of the record and the size of the region |
| `No_Region` | `Attach` with a handle that is not memory, has no Read, or did not come through the ring; `Start` before `Attach` | `Handle_Kind`, `Handle_Rights` or `Absent` |
| `Not_Started` | `Play` before `Start` | `State` |
| `Late` | The first frame is before the first frame that the service has not given to the device | `Too_Small`, unit `Nanoseconds`: the time asked and the earliest time |
| `Too_Far` | The time is more than 10 s after the earliest time | `Over_Limit`, unit `Nanoseconds`: the time asked and the latest time |
| `Overlap` | The first frame is before the end of the record accepted before it | `Overlap`, unit `Frames`: the first frame and the end of the record before |
| `Device_Error` | The device needs a reset: the service stops, and each record that waits gets this status | `Device`, with the status of the device |

A late record is refused whole: the service does not play its end, and does not move it to the earliest time. A program that wants a sound now asks for the earliest time, which the completion of `Late` gives.

## 3. The time, the latency and an underrun

**The stream clock.** The service maps the system clock to the frames of the device: the frame 0 plays at the time that the answer of `Start` gives, and each frame after it 1/48000 s later. A time maps to the nearest frame: a record plays within 10.4 µs of its time.

**The latency.** The service gives the device 4 periods of 480 frames, 40 ms, and fills each new period as the device ends one. The earliest time that a record can take is between 30 ms and 40 ms after now. The device adds a delay of its own after a period, which virtio-snd does not report.

**An underrun.** When the service gives no period in time (it did not run for more than 30 ms), the device plays everything that it held, then nothing. The service counts it and moves its map: the next frame plays now. A record that it accepted before keeps its frames, so it plays later than its time by the gap; its completion says when it played, and counts the underruns. The service writes one line at the first underrun.

**The clock of the device.** The service does not correct a drift of the clock of the device against the clock of the system. On the test machine both come from the clock of the host.

## 4. The test

`modustool test sound` starts a machine with the sound device `virtio-sound-pci`, whose output goes to a wave file beside the log of the machine (`-audiodev wav`), at 48000 frames in one second and 2 channels. The console starts the program `tone`:

- `tone` makes a sample region of 24 pages, writes 500 ms of a tone of 440 Hz, and asks for it at 500 ms after the frame 0.
- It sends six records that the service must refuse, and checks the status, the kind, the unit and the value number of each: over the tone, at the frame 0, 20 s ahead, an unknown format, 480 001 frames, and two frames past the end of the region.
- It checks that the tone played at the frame of its time: the frame 24 000.
- A second `start("tone")` is refused while the first one runs, with the line "root: cannot start tone: the sound device plays for another program; one program plays at a time".

After the machine, the tool reads the wave file. QEMU writes each frame that the stream gave, in order, so a frame of the file is a frame of the stream. The first frame that is not silence must be the frame that `tone` names, within 2 frames. Over the 4800 frames after it, the left channel must cross zero 88 times, within 2: the crossings of a tone of 440 Hz. The check counts frames and reads no time of the host. It reads the frames to the end of the file, because QEMU writes the sizes of the header only at a clean end.

Host tests: the border of a record (`src/library/contract/timed_stream`) refuses an unknown format, a count of 0 and past its bound, a place off a frame, a damaged record, a time before the earliest, too far and over the record before, and checks the map of the clocks against a reference at its edges; the check of the tool refuses a file that is not a wave of PCM, another format, silence, a tone out of its place, a short file and another frequency.

## 5. What is not built

- **Mixing.** One program plays at a time. Two programs need a sound service of the class between them and the device service, which sums the frames of each period.
- **Capture.** A microphone is a device queue behind a grant, with a visible indicator while in use (`PROPERTIES.md`, "20. No ambient access: the other holes to close").
- **A second format.** One more member of `Format`, and its conversion in the service.
- **The drift of the device clock.** The service will measure the rate of the device from the times of the completions, and change its map.
- **A measure of the underruns** on a loaded machine, which decides the size of a period.
