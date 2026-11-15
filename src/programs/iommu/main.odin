// The client of the test of the IOMMU. Its one grant is the disk of the
// measures; for this program the root service starts the test device
// service `iommu_device` on that disk in place of the block service
// (src/programs/iommu_device, src/md/infrastructure/iommu.md, "The
// proof").
//
// **What it shows.** After the test device service gave its device an
// address that it did not declare, the service still runs and answers:
// a DMA fault stops no program. It sends the command Info on the block
// ring, waits for its completion with the hang bound, and writes one line.
//
// **What a reader sees.** No window: the line `iommu: ...` on the log.
package iommu_client

import "modus:contract/block"
import "modus:contract/ring"
import "modus:support/system"

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	blocks, status := system.ring_open(ctx.handles[block.GRANT_RING])
	if status != .Ok {
		system.log_in("iommu", .Error, "iommu: no block ring")
		system.stop(1)
	}
	if !system.send(&blocks.commands, ring.Record{kind = u32(block.Command.Info), tag = 1}) {
		system.log_in("iommu", .Error, "iommu: the block ring has no room")
		system.stop(1)
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		if record, ok := system.receive(&blocks.completions); ok {
			if record.tag == 1 && block.Status(record.kind) == .Ok {
				system.log("iommu: the test device service answered after its read into a page that was not declared: the machine goes on: as it must")
			} else {
				system.log("iommu: the test device service gave the status ", u64(record.kind), " to Info")
			}
			system.stop(0)
		}
		if system.time() >= deadline {
			system.log("iommu: the test device service did not answer before the hang bound")
			system.stop(1)
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		system.wait_end(&wait, deadline)
	}
}
