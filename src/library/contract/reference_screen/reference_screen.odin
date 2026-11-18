// The reference screen: the size of the screen for which the desktop is
// laid out and on which the test machines take their pictures
// (src/md/features/desktop_to_browser.md, "The reference screen"). The boot
// program asks the firmware for this mode, the measure of a frame on the
// processor draws at this size, and the tool checks the pictures of the
// screen and the video memory of its machines against it, so the three
// agree on one size.
//
// The compositor does not read it: it takes the size of its screen from
// the framebuffer of the firmware, which is this size only when the
// firmware offers the mode.
//
// See [reference screen](term:reference-screen).
package reference_screen

WIDTH :: 1920 // In pixels of the screen.
HEIGHT :: 1080
