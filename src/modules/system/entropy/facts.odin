package entropy_device_service

// The log facts of the entropy service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the device found and
// ready, as a record of fields. The fact template is the sentence that the
// line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. No field has the name of a column of the
// head of facts(): number, time, process, level.

// The device is ready: the service gave it its queue.
@(log_fact = "entropy: ok, a queue of {queue_size}")
Device_Ready :: struct {
	queue_size: u64,
}

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "entropy: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
