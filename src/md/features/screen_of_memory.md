# The screen of memory

A machine with no screen of a device (a server, a machine of a home lab) runs the desktop in memory, and a principal sees and drives it through `remote_display` ([remote_display.md](remote_display.md)). The compositor draws into a screen of memory as it draws into a framebuffer, and a viewer with the input can ask the screen of memory for another size.

## The constraints

- **The parts of the machine are what the root service checked.** The machine parts page says "no screen", and no process reads the screen of memory as a display device: it is not a part that the system pretends to have ([missing_hardware.md](missing_hardware.md), "The refused forms").
- **Which processes start is a decision of the start list** ([start_policy.md](start_policy.md)), never a policy in the code of the root service.
- **A budget is decided at the start of a process.** The root service does not raise the budget of a process that runs.
- **The indicator of a viewer never leaves the bar while a viewer looks** ([remote_display.md](remote_display.md), "The authority").
- **The compositor never waits for the service of the remote display.**

## The chosen form

### The start row gives the size

The row of the holder of Display in a start list carries the size of a screen of memory (format version 4 of the start list). With 0 × 0, the row asks for no screen of memory. The border of the list refuses a size on a row that is not the row `display`, a size with one side 0, and a size outside 320 × 240 to 7680 × 4320 (`memory_screen.MIN_WIDTH` to `MAX_WIDTH`, `MIN_HEIGHT` to `MAX_HEIGHT`). The default start list and the rescue list give the reference screen, 1920 × 1080, so a machine with no screen has a desktop and a console.

A start list whose row `display` gives a size gives the machine a screen for its rows: on a machine with no screen, each row that needs the part Screen starts (the input service, the console), and the row `display` starts the holder on a screen of memory. The machine parts page still says "no screen"; the start policy adds the part to its own set only. A start list whose row `display` gives no size starts none of these rows on such a machine, as before.

The start policy sends the size in the command `Start` of the row `display` (`values[6]`, `root_ring.screen_of_memory_word`), and only when the machine has no screen. The root service refuses the word on any other name, from any sender that is not a start policy, on a machine with a screen, and outside the bounds of the contract.

### The root service starts the compositor with no framebuffer

On a machine with no screen and a size in the `Start`, the root service starts the holder of Display with no framebuffer handle, and with the size in the values of the screen (the width, the height, the width as the pixels of a line, the format 0). It keeps the size as the screen in force: the budget of each module that states screen pictures (the compositor, `remote_display`) pays them at that size. From that start until the compositor stops, the machine has a desktop: a process gets a window, a process with the grant Terminal starts, and `unlock` starts for a locked principal, as a viewer with the input can type its passphrase. A compositor of memory that stops gives the line of a compositor that stopped, and the machine has no desktop again.

### The frame is the screen

The compositor builds each frame in its frame in memory, then copies the damage to the screen. With a screen of memory, the frame is the screen: no copy, no screen page, no page flip. The one test `screen_presence.screen_form` gives the form of the screen from the context: a framebuffer that maps with a size is a screen of a device; no framebuffer and a size inside the bounds of the contract is a screen of memory; anything else is no screen, and the compositor stops with its line as before. The compositor writes one line: `compositor: no screen: a screen of memory of 1920 x 1080`.

The capture face copies from the frame, as with a screen of a device ([remote_display.md](remote_display.md), "The service"). The screen of memory costs the frame and the background, the two screen pictures that the compositor states for any screen.

### A viewer asks for a size

A viewer with the input sends `Screen_Size_Ask` with a width and a height (protocol version 3). The border of the record refuses a size outside the bounds of the contract and ends the connection with `Bad_Record`, as for each field out of its range. A viewer with the view alone that asks ends with `Input_Not_Allowed`: a size changes the desktop of the principal, as a key does.

`remote_display` holds one ask in flight. A new ask replaces an ask that waits; the last one holds. It first checks its own budget: the pages left, and the pages of its copies of today, must pay its copies at the new size. Else it answers that viewer with `Screen_Size_Refused` and the cause `Service_Budget`. Then it sends the size to the compositor (`Screen_Size_Set`, on the ring of its window, a command of the capture face).

The compositor refuses the size with one cause, and answers with the event `Screen_Size_Refused`:

- `Device_Screen`: the machine has a screen of a device, whose size the system does not set;
- `Outside_Bounds`: the size is outside the bounds of the contract;
- `Compositor_Budget`: the pages left in its budget do not pay a new frame and a new background.

Else it makes the new frame and the new background first, then frees the old ones, so a refusal changes nothing. It takes the new size as the logical size of the desktop at the scale in force, builds the background and the bar again, sends each window its new work area, fits each window into it (a maximized window takes the new zone, a window larger than the area takes the area), and damages the whole screen. It answers with the event `Capture_Size` and the new size. A size equal to the size in force changes nothing and gets the same answer.

### The capture face across a change of size

At a change, the compositor unmaps the pictures of the capture face and stops to write them. It keeps the client of the face, the list of its viewers and the mark of the bar: the mark never leaves the bar while a viewer looks. A `Capture_Taken` of the old pictures that crossed the change is dropped with no refusal.

`remote_display` takes the new `Capture_Size` when no viewer is in the middle of a viewer frame, as it takes a picture. It drops the picture that it holds, frees its old copies, makes its copies at the new size and gives them with `Capture_Open`. Each viewer then receives `Screen_Size` again, between two viewer frames, and the next viewer frame is the whole screen.

## The refused forms

- **A screen of memory as a part of the machine parts page.** The page names what the root service checked. The size is a decision of a start list, and two start lists of one image can disagree.
- **A third picture in the compositor, the screen beside the frame.** It costs one picture and one copy of the damage in each frame for pixels that no device reads.
- **A size from a setting, or from the plan.** A start row already gives a size for each start of the holder; a setting would need a writer before the compositor starts.
- **A budget raised at a change of size.** The budget of a process is decided at its start. A larger size is paid from the pages that the budget has left; a size past them is refused with its cause.
- **The old frame freed before the new one is made.** A refused memory would leave the compositor with no frame.
- **The capture face ended at a change and opened again.** The mark would leave the bar while a viewer looks.
- **A refusal of a size that ends the connection.** A size that the budget does not pay is a state of the machine, not a fault of the viewer: the viewer gets a record with the cause and keeps its session. A size outside the bounds is a fault, and ends it.
- **A change of size in the middle of a viewer frame.** The screen pieces of a viewer frame come from one copy of the screen.

## The subtle points

- **The records of a viewer that cross a change.** A viewer sends a pointer or a request of screen pieces at the size that it knows. Until it takes a viewer frame at the new size, its border reads its records against the larger of the old and the new screen, and `remote_display` cuts each place and each rectangle to the new screen. The compositor cuts a pointer of a viewer to a screen of memory too: its change can come before the change of `remote_display`.
- **The budget of `remote_display` follows the start row.** The root service pays its three screen pictures at the screen in force, which is the size of the start row of the compositor. A viewer that asks a larger size uses the pages that the budget has left.
- **Two viewers that ask.** The last ask holds; each refusal goes to the viewer that asked.
- **The pointer after a change.** The compositor keeps the pointer inside the new desktop, and the viewers that did not move it receive a warp.

## The tests

- On the host: the border of the start list at its edges (0 × 0, one side 0, 319 × 240, 320 × 240, 7680 × 4320, 7681 × 4320, a size on a row that is not `display`); the word of the `Start` at the same edges; `screen_presence.screen_form` for each form; the records `Screen_Size_Ask` and `Screen_Size_Refused` at their edges, a cause that names no member, a reserved word that is not 0; the decision of the change of size of the compositor and of the service (`memory_screen.resize_decide`, `memory_screen.service_resize_decide`).
- On a machine with no display device (the test part `screen_of_memory`): the line of the screen of memory, the console in it, a viewer that sees the whole desktop of 1920 × 1080, a size of 2560 × 1440 that the viewer asks and receives with the whole screen at that size, a size past the bounds that ends the viewer with `Bad_Record`. On the machine of `remote_display`, which has a screen of a device, an ask gets `Screen_Size_Refused` with `Device_Screen`.

## State

Built: the size of the start row (format version 4), the start of the compositor with no framebuffer, the frame as the screen, the change of size from a viewer with its causes, the capture face across a change, protocol version 3. Left: a size that the plan of principal 0 gives as a machine policy, which waits for machine policy in the plan.
