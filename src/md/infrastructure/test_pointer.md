# How a machine test names what it presses

A machine test drives the desktop with the virtual mouse of QEMU. A step that presses at a place that the scenario computes by hand breaks in silence when a layout changes: the press lands on another element, or on nothing, and the step fails later with a cause that names something else. A press at the place of an element that another window covers goes to that other window. This file records how a step names the element instead, and how the tool finds where it is.

The steps and their lines are in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "How a step presses an element".

## Constraints

- **The test runs the bytes that ship.** A module is named by its hash. A process that draws other code in a test build is another module, and a test of it says nothing of the module that a principal runs. So no part of this design is a build setting.
  - **One exception: the fuzzing of the kernel operations.** It needs the edge counters of the kernel, so it runs the counted kernel on a test volume of its own, as the self tests of the kernel run on volumes of their own; the release image refuses every test volume. The rule still decides what a finding is: a fault of the kernel is confirmed when the same operation sequence faults the kernel that ships too. A fault that only the counted kernel shows is read to its cause ([kernel_fuzzing.md](kernel_fuzzing.md), "The confirmation on the kernel that ships").
- **No new contract between two processes.** A log line is no contract: no process reads it, and only the tool depends on its form. A record of the display ring, a setting of the settings page and an export of the compositor are contracts, and each one would need a version and a reader in the system.
- **A test waits for a condition, never for a time.** The tool waits for the line that places the element, with the hang bound.
- **The log is shared and read by principals.** A frame that changes nothing writes nothing. A line holds no secret that a principal types, and no fact about it such as its length.

## The chosen form

**The interface package knows each element.** Each frame of a window passes the area of each element to the package (`element_interact`, `button`, `text_input`, `scroll_bar`). So the package is the one place that knows the rectangle of an element in each frame, and the name of a button and a field without help: its label and its placeholder. A process names another element with `element_name` (a row of the debugger: "frame 0").

**The window writes a line only when a rectangle changes.** The window layer keeps the set of the element names that the log has from this window. After a frame that it drew, it compares the set of the frame with that set by name: a new name or a moved rectangle writes `interface: <window>: the element <name> at x,y,w,h`; a name that left the frame writes `... the element <name> is gone`. A window whose layout stays the same writes its lines one time.

**The palette is a panel of the compositor.** It has no window and no window layer: the compositor writes the lines of its elements itself, in pixels of the screen, under the owner `the palette`, after it builds a frame of the panel. Each field that the band shows is "field N", from the first character of its name to the end of its unit; each button of a field is the name of its candidate; each arrow button of the list is "scroll bar arrow up" or "scroll bar arrow down". When the panel closes, each element is gone.

**The tool presses the middle of the last place.** The step `Click_Element` reads the last line of the element. With no line, or with a last line that says that it is gone, it waits for a new line. For a window it adds the place of the window that the compositor gives.

**The window comes to the front first.** With the remote service, `compositor.windows()` gives the place and the order of each window: the tool brings the window to the front only when a window in front of it covers the point. Without the remote service, the log gives the places but not the order, so the tool brings the window to the front each time; a window that is in front already stays in front. The step `Close` does the same before it presses the close button.

## Refused forms

- **A line of each element at each frame.** A window that draws a frame for each change of a value, or each frame of an animation, fills the log with the same lines. The lines of a change carry the same facts.
- **A line only in a test build.** The module of a test build differs from the module that ships (see the constraints).
- **A request of the tool to the window.** The tool has no channel to a window. A new event of the display ring, or an export of the compositor that asks the window, is a new contract between two processes for a need of the tests alone.
- **The rectangles in the record of the act names.** The window already sends its act names to the compositor, and the compositor has an export that the tool calls. A rectangle in that record changes a contract, and the compositor would keep rectangles that no part of the system uses.
- **A setting of the settings page that turns the lines on.** The page is a contract read by each process; a new field changes its version.
- **A place computed by the tool from the layout code.** The tool would compute the layout of each process again, and a change of the process would still break the step in silence. The bar of the compositor is the one exception that stays: the tool measures it from the font cache of the build and checks the measure against the numbers that the compositor writes.
- **The thumb of a scroll bar as an element.** The thumb moves each time the content grows: the console would write a line for each line of text. A step `Drag` of a thumb stays a step at a place.

## Subtle points

- **The line describes the last drawn frame, not the state of the process.** A process can write the line of an act before it draws the frame that moves an element: the window `inspect` writes the choice of a process before it draws the shorter list of a filter. A scenario that presses an element that the act before just moved waits for the new element line first.
- **One name, one rectangle, in each frame.** The first element of a frame with a name keeps it; a second one has no line. A process that has two buttons with one label gives one of them another name.
- **Two windows with one title share the lines of that title.** The tool reads the last line, and the step `Front` brings the last window of that title to the front.
- **A frame left out writes nothing.** When the compositor did not take the picture before, the window draws no frame and keeps the set that the log has; the next drawn frame writes the change.
- **A typed passphrase writes no line.** A line after each key would put the length of the passphrase on the log. The picture of the window `unlock` with its dots therefore has no line to wait for; the condition of a settled screen alone holds it.

## State

Built: the element lines of the interface package (`element_places.odin`), the names of the buttons, text inputs and scroll bars, the rows of the debugger and of `inspect`, the colors of `paint`, the elements of the palette, the step `Click_Element`, and the step `Close` that brings its window to the front.

Left: the window `pointers` builds its frames with no window layer, so its button stays a press at a place; the steps `Point` read the shape of the pointer at a place, which is what they test.
