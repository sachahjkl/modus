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

`remote_display` holds one ask in flight. A new ask replaces an ask that waits; the last one holds. It first checks its own budget: the pages left, and the pages of its copies of today, must pay its copies at the new size. Else it answers that viewer with `Screen_Size_Refused` and the cause `Service_Budget`. An ask less than one second after the last change of the size, or after the last ask of the same viewer that went on, gets the cause `Too_Soon` (`memory_screen.RESIZE_INTERVAL_MILLISECONDS`): each change sends each viewer the whole screen, and a viewer that asks in a loop would hold the service and the compositor in whole frames. Then it sends the size to the compositor (`Screen_Size_Set`, on the ring of its window, a command of the capture face).

The compositor refuses the size with one cause, and answers with the event `Screen_Size_Refused`:

- `Device_Screen`: the machine has a screen of a device, whose size the system does not set;
- `Outside_Bounds`: the size is outside the bounds of the contract;
- `Compositor_Budget`: the pages left in its budget, or in its extra budget, do not pay a new frame and a new background.

The service gives causes of its own: `Service_Budget` and `Too_Soon`, and the causes of a refused growth (`Compositor_Budget`, `Service_Budget`).

Else it makes the new frame and the new background first, then frees the old ones, so a refusal changes nothing. It takes the new size as the logical size of the desktop at the scale in force, builds the background and the bar again, sends each window its new work area, fits each window into it (a maximized window takes the new zone, a window larger than the area takes the area), and damages the whole screen. It answers with the event `Capture_Size` and the new size. A size equal to the size in force changes nothing and gets the same answer.

### The budget of a screen of memory

A budget is a reservation: the root service moves its pages into the budget of a process at its start (`Budget_Create`), and no kernel operation adds pages to a budget later. The root service pays the screen pictures of the compositor and of `remote_display` at the size of the start row. A size larger than the start size grows them by one extra budget each, which the root service makes when a viewer asks that size and which ends when another size replaces it. Paying a larger size at the start was refused: it reserves the pages of a 4K or 5K screen, about 190 MiB, on each machine with no screen, also when no viewer asks.

### The growth of the budgets

`remote_display` asks with one command of its root ring, `Screen_Budget` with the step `Grow`, the width and the height, for each size larger than the start size: an extra budget pays one size, the size of its growth. The root service decides both processes together, so both grow or neither does:

1. It refuses the command from any process but the one with the start grant `Screen_Capture`: the command has its own sender, and that start grant gives the root ring that carries it. The service asks only for a viewer with the input, whose ask passed its border and its least time (`Too_Soon`); the root service cannot see a viewer, so it holds the sender to the rest.
2. It refuses it on a machine with a screen of a device, or with no compositor that draws into a screen of memory; a size outside 320 × 240 to 7680 × 4320; and while the compositor or `remote_display` holds two extra budgets: a replacement is not finished, and a process holds at most two.
3. It computes the pages of each extra budget at the new size: the frame and the background of the compositor, which it makes before it frees the old ones (`memory_screen.compositor_grow_pages`), and the capture face and the copy of `remote_display`, which it frees before it makes the new ones (`memory_screen.service_copies_pages`). Each sum of the budget of the process at its start, of the extra budget that it holds, and of the new extra budget must be at most the largest budget of a process of the machine (its share): during a replacement, a process holds the old and the new one at once. A sum past it refuses both, with the process that passed it.
4. It makes the extra budget of the compositor, then the one of `remote_display`, from its own budget (`Budget_Create`). A refusal of the second closes the first. It gives each process its handle with the rights `Read` and `Spend`, and keeps its own handle of each. It numbers the growth: the number names both extra budgets of the growth in a release, and is never 0.
5. It sends the compositor `Screen_Budget_Give` on the control ring, with the handle, the pages, the size and the number, then answers the command with the handle of `remote_display`, its pages and the number. The compositor reads its control ring before the rings of its windows, so it holds its extra budget before the `Screen_Size_Set` that `remote_display` sends after the answer.

Each process makes the pictures of a size larger than its start size from the extra budget of that size, and the pictures of a size at most its start size from its own budget. After each answer to a size, taken or refused, the process closes each extra budget that holds none of its pictures, and says so with its number: `remote_display` with `Screen_Budget`, the step `Release` and the number, the compositor with `Screen_Budget_Release` and the number on the control ring. The root service then closes its own handle of that extra budget. So a replacement is short: the new pictures are made from the new extra budget, the old ones are freed, and the old extra budget goes back. A size at most the start size gives back each extra budget. The kernel ends a budget when its last handle and its last object are gone, so the pages return to the root service. At the stop of either process, the root service closes its own handle of each extra budget of that process, also in the middle of a replacement: the stop closed the handles and the objects of the process, and the pages return.

A refusal of the root service changes nothing: no budget is made, the extra budgets in force stay, and the viewer gets `Compositor_Budget` or `Service_Budget` by the process that passed its share or holds two extra budgets. At most two extra budgets for each process, the second one only during a replacement, bound what the screen holds: the pages of the size in force and of the size that replaces it.

A growth whose viewer left before the answer, or that the face can no longer take, is not left open. `remote_display` closes its own new extra budget at once, and when its face is open it sends the compositor the size in force: the answer changes nothing, and the compositor closes its unused new extra budget after it, by the rule above.

A machine with no viewer pays only its start size. When the capture face ends, as `remote_display` closes it when its last viewer leaves, or as `remote_display` stops, the compositor makes the frame and the background of the start size from its own budget, which holds no picture then, frees the grown ones, and gives back each extra budget: the one of the grown size, and the new one of a growth whose size never came while the face was closed. `remote_display` gives back each of its own when its face closes, as it holds no copy then. The next face asks the size, and gets the start size, which the budget of `remote_display` pays. Both processes keep their extra budgets with one pure part, `memory_screen.Held_Extras`. The decisions are pure parts with host tests: `memory_screen.screen_budget_grow_decide`, and the table of the extra budgets of the root service (`internal:root/screen_budgets`).

### The capture face across a change of size

At a change, the compositor unmaps the pictures of the capture face and stops to write them. It keeps the client of the face, the list of its viewers and the mark of the bar: the mark never leaves the bar while a viewer looks. A `Capture_Taken` of the old pictures that crossed the change is dropped with no refusal.

`remote_display` takes the new `Capture_Size` when no viewer is in the middle of a viewer frame, as it takes a picture. It drops the picture that it holds, frees its old copies, makes its copies at the new size and gives them with `Capture_Open`. Each viewer then receives `Screen_Size` again, between two viewer frames, and the next viewer frame is the whole screen.

When its copies of the new size are refused, `remote_display` asks the compositor for the size before, before any viewer ends, and the viewer that asked gets `Service_Budget`. Only when the size before is refused too do the viewers end with `Screen_Not_Held`, and the face and the mark of the bar end (`remote_display.screen_change_step`).

## The refused forms

- **A screen of memory as a part of the machine parts page.** The page names what the root service checked. The size is a decision of a start list, and two start lists of one image can disagree.
- **A third picture in the compositor, the screen beside the frame.** It costs one picture and one copy of the damage in each frame for pixels that no device reads.
- **A size from a setting, or from the plan.** A start row already gives a size for each start of the holder; a setting would need a writer before the compositor starts.
- **The pictures paid at the largest size at the start.** A budget is a reservation: about 190 MiB for a 4K or 5K screen on each machine with no screen, also when no viewer asks.
- **A budget of each process that grows by itself.** A process cannot take pages from the root service: it could take the share of others. The root service decides, for both processes together.
- **Two commands, one for each process.** One could grow and the other not, and the screen would have a size that one of them cannot hold.
- **The extra budget given and forgotten by the root service.** It could not refuse a second one, and could not end it at the stop of its process.
- **One extra budget for each process, and no growth past the start size until a smaller size.** A screen that grew could not grow again. Two extra budgets during a replacement, paid by the share, keep the bound.
- **An extra budget that grows, or one that pays each larger size.** No kernel operation adds pages to a budget; an extra budget of the largest size asked so far would keep its pages after a smaller size.
- **A grown screen kept with no viewer.** A screen holds its pages for no one, and a growth whose size never came would hold its pages until the next size; the next face could not open at a size whose extra budget `remote_display` gave back.
- **A release of the oldest extra budget, with no number.** After a growth whose size the compositor never took, the newest one holds no picture and the oldest does: the release would close the wrong one.
- **The old frame freed before the new one is made.** A refused memory would leave the compositor with no frame.
- **The capture face ended at a change and opened again.** The mark would leave the bar while a viewer looks.
- **A refusal of a size that ends the connection.** A size that the budget does not pay is a state of the machine, not a fault of the viewer: the viewer gets a record with the cause and keeps its session. A size outside the bounds is a fault, and ends it.
- **A change of size in the middle of a viewer frame.** The screen pieces of a viewer frame come from one copy of the screen.

## The subtle points

- **The records of a viewer that cross a change.** A viewer sends a pointer or a request of screen pieces at the size that it knows. Until it takes a viewer frame at the size in force, its border reads its records against the largest side of the screen in force and of each screen before it since that viewer last saw the size in force (`remote_display.Screen_Lag`): two changes in a row keep the largest, and `remote_display` cuts each place and each rectangle to the new screen. The compositor cuts a pointer of a viewer to a screen of memory too: its change can come before the change of `remote_display`.
- **The budget of `remote_display` is decided at its start.** It starts after the compositor, so the root service knows the screen of memory, and pays its three screen pictures at the size of the start row.
- **Two viewers that ask.** The last ask holds; each refusal goes to the viewer that asked.
- **The pointer after a change.** The compositor keeps the pointer inside the new desktop, and the viewers that did not move it receive a warp.

## The tests

- On the host: the border of the start list at its edges (0 × 0, one side 0, 319 × 240, 320 × 240, 7680 × 4320, 7681 × 4320, a size on a row that is not `display`); the word of the `Start` at the same edges; `screen_presence.screen_form` for each form; the records `Screen_Size_Ask` and `Screen_Size_Refused` at their edges, a cause that names no member, a reserved word that is not 0; the decision of the change of size of the compositor and of the service (`memory_screen.resize_decide`, `memory_screen.service_resize_decide`).
- On the host, the growth: `screen_budget_grow_decide` refuses a sender that is not the service, a machine with a screen of a device, a size past the bounds, a process that holds two extra budgets, and a sum of the start budget, the extra budget held and the new one past the share of each process, at its edge; the table of the extra budgets takes a second growth, refuses a third before a release and changes nothing, takes a release by number in any order, refuses a number that it does not hold, and gives each handle to close at the stop of each process in the middle of a replacement; the extra budgets of a process (`memory_screen.Held_Extras`) refuse a third one, give back the old one of a replacement and the new one of a refused size, give back both at the end of the face after a growth no longer needed, and the end of the face after the last viewer leaves a grown screen goes back to the start size.
- On a machine with no display device (the test part `screen_of_memory`): the line of the screen of memory, the console in it, a viewer that sees the whole desktop of 1920 × 1080, a size of 2560 × 1440 that grows both budgets and that the viewer receives with the whole screen at that size, a size of 3840 × 2160 while the screen is grown, which replaces both extra budgets and that the viewer receives, a size of 1280 × 720, which gives both extra budgets back and that the viewer receives with the whole screen, a size of 2560 × 1440 again, a size past the bounds that ends the viewer with `Bad_Record`, after which the face closes, the compositor goes back to 1920 × 1080 and both extra budgets go back. On the machine of `remote_display`, which has a screen of a device, an ask gets `Screen_Size_Refused` with `Device_Screen`.

## State

Built: the size of the start row (format version 4), the start of the compositor with no framebuffer, the frame as the screen, the change of size from a viewer with its causes, the capture face across a change, protocol version 3. The growth of the budgets is built: the command `Screen_Budget`, the extra budget of each process, its replacement, its release, its end at a stop, and the return to the start size when no viewer looks. Left: a size that the plan of principal 0 gives as a machine policy, which waits for machine policy in the plan.
