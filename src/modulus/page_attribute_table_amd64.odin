package kernel

import "modulus:page_attributes"

// page_attribute_table_setup writes the page attribute table of the kernel
// on the processor that runs it, before any process: a page has one cache
// type whichever processor reads it. The table changes only an entry that
// no page of the kernel or of the boot selects, so no mapping changes its
// type and no cache needs a flush (src/md/features/gpu_access.md,
// "Write-combining device memory").
page_attribute_table_setup :: proc "contextless" (cpu: ^Processor) {
	model_specific_register_write(page_attributes.MODEL_SPECIFIC_REGISTER_PAGE_ATTRIBUTE_TABLE, page_attributes.KERNEL_TABLE_WORD)
	// Each processor reads its table back: a processor with another table
	// would give one page two cache types, so the machine does not start.
	if model_specific_register_read(page_attributes.MODEL_SPECIFIC_REGISTER_PAGE_ATTRIBUTE_TABLE) != page_attributes.KERNEL_TABLE_WORD {
		log("kernel: the processor ", u64(cpu.index), " did not take the page attribute table of the kernel")
		machine_stop(.Start_Failed)
	}
}
