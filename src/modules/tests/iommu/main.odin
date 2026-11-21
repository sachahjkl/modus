// The client of the test of the IOMMU. Its one grant is the disk of the
// measures; for this process the root service starts the test device
// service `iommu_device` on that disk in place of the block service
// (src/modules/tests/iommu_device, src/md/infrastructure/iommu.md, "The
// proof").
//
// **What it shows.** After the test device service gave its device an
// address that it did not declare, the service still runs and answers:
// a DMA fault stops no process. It sends the command Info on the block
// ring, waits for its completion with the hang bound, and writes one line.
//
// **What a reader sees.** No window: the line `iommu: ...` on the log.
package iommu_client

import "modus:contract/block"
import "modus:contract/ring"
import "modus:system"

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	blocks, status := system.ring_open(ctx.handles[block.GRANT_RING])
	if status != .Ok {
		system.log_fact(.Error, No_Block_Ring{})
		system.stop(.Failed)
	}
	if !system.send(&blocks.commands, ring.Record{kind = u32(block.Command.Info), tag = 1}) {
		system.log_fact(.Error, Block_Ring_Full{})
		system.stop(.Failed)
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		if record, ok := system.receive(&blocks.completions); ok {
			if record.tag == 1 && block.Status(record.kind) == .Ok {
				system.log_fact(.Info, Machine_Goes_On{})
			} else {
				system.log_fact(.Info, Info_Refused{status = block.Status_Word(record.kind)})
				system.stop(.Failed)
			}
			system.stop(.Done)
		}
		if system.time() >= deadline {
			system.log_fact(.Info, Device_Service_Silent{})
			system.stop(.Failed)
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		system.wait_end(&wait, deadline)
	}
}
