package kernel

// page_attribute_table_setup does nothing on the software processor: it
// has no cache, and a page has no cache type. A write of the register would
// take a slot of the table of model-specific registers for no effect.
page_attribute_table_setup :: proc "contextless" (cpu: ^Processor) {
}
