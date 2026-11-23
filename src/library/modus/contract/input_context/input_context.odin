// The context of the input service: the slots of the handles that the root
// service gives it and that the input service reads. Both import this
// package, so the two sides cannot name two layouts.
//
// The virtio tablet, when the machine has one, takes the copy of its
// configuration and its BARs at the slots of the device services (package
// pci: the configuration at 4, the BAR n at 5 + n, which modus:virtio reads),
// and its interrupt, its queues and the machine after them: the PS/2
// controller takes the slots 1 to 3, where a device service has those.
// The root service checks the two shared slots against package pci.
//
// This package allocates no memory and calls no kernel operation.
package input_context

GRANT_RING :: 0 // The input ring, which the compositor reads.
GRANT_PORTS :: 1 // The ports of the PS/2 controller.
GRANT_KEYBOARD_INTERRUPT :: 2
GRANT_MOUSE_INTERRUPT :: 3
GRANT_TABLET_CONFIGURATION :: 4 // A copy of the configuration of the tablet: pci.GRANT_CONFIGURATION.
GRANT_TABLET_FIRST_BAR :: 5 // GRANT_TABLET_FIRST_BAR + n: the registers in BAR n: pci.GRANT_BAR.
GRANT_TABLET_BAR_COUNT :: 6
GRANT_TABLET_INTERRUPT :: 11
GRANT_TABLET_QUEUES :: 12
GRANT_TABLET_MACHINE :: 13 // The machine, with the right Physical only.

#assert(GRANT_MOUSE_INTERRUPT < GRANT_TABLET_CONFIGURATION)
#assert(GRANT_TABLET_FIRST_BAR + GRANT_TABLET_BAR_COUNT <= GRANT_TABLET_INTERRUPT)
