package declaration_eval_module

// Log facts of the sandboxed declaration evaluator module.

@(log_fact = "declaration_eval: evaluated declaration into {bytes} bytes in {steps} steps")
Evaluation_Completed :: struct {
	bytes: u64,
	steps: u64,
}

@(log_fact = "declaration_eval: refused at line {line}, column {column} (failure {failure}) after {steps} steps")
Evaluation_Refused :: struct {
	steps:   u64,
	failure: u64,
	line:    u32,
	column:  u32,
}
