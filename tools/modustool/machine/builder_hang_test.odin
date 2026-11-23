package machine

import "core:testing"
import "modus:contract/builder"

// The step that waits for the refusal of a builder that never answers has a
// bound larger than the bound of one build, which the service waits first.
@(test)
the_step_of_a_hanging_builder_outlasts_the_bound_of_a_build :: proc(t: ^testing.T) {
	testing.expect(t, BUILDER_HANG_STEP_SECONDS * 1000 > builder.BUILD_TIME_BOUND_MILLISECONDS, "the step must outlast the bound of a build")
}
