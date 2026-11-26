#+build !freestanding
#+build !modus
package interface

import "core:testing"

@(private = "file")
Job_Result :: struct {
	runs:  int,
	value: int,
}

@(private = "file")
job_add :: proc "contextless" (parameter: rawptr) {
	result := (^Job_Result)(parameter)
	result.runs += 1
	result.value += 7
}

// A work refuses each act that its state does not take, and nothing
// changes: a nil job, a second ask before the take, a take before the end,
// a step with no job. Then a job runs once, the take gives true once, and
// the work takes a new job.
@(test)
background_work_runs_one_job_at_a_time :: proc(t: ^testing.T) {
	work: Background_Work
	result: Job_Result
	testing.expect(t, !background_work_busy(&work))
	testing.expect(t, !background_work_take(&work), "no job: no result")
	testing.expect(t, !background_work_step(&work), "no job: the worker runs nothing")
	testing.expect(t, !background_work_ask(&work, nil, &result), "a nil job is refused")
	testing.expect_value(t, background_state(&work), Background_State.Idle)
	testing.expect(t, background_work_ask(&work, job_add, &result))
	testing.expect(t, background_work_busy(&work))
	other: Job_Result
	testing.expect(t, !background_work_ask(&work, job_add, &other), "a second ask before the take is refused")
	testing.expect(t, !background_work_take(&work), "the job did not run: no result")
	testing.expect_value(t, result.runs, 0)
	testing.expect(t, background_work_step(&work))
	testing.expect(t, !background_work_step(&work), "the job runs once")
	testing.expect_value(t, background_state(&work), Background_State.Done)
	testing.expect(t, !background_work_ask(&work, job_add, &other), "a result not taken refuses an ask")
	testing.expect(t, background_work_take(&work))
	testing.expect(t, !background_work_take(&work), "the take gives true once")
	testing.expect_value(t, result.runs, 1)
	testing.expect_value(t, result.value, 7)
	testing.expect_value(t, other.runs, 0)
	testing.expect_value(t, work.jobs_done, u64(1))
	testing.expect(t, background_work_ask(&work, job_add, &result))
	testing.expect(t, background_work_step(&work))
	testing.expect(t, background_work_take(&work))
	testing.expect_value(t, result.runs, 2)
	testing.expect_value(t, work.done.count, u32(2))
	testing.expect_value(t, work.asked.count, u32(2))
}
