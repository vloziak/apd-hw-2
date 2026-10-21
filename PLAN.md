# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

First, I check that the input is correct. When someone creates the processor,
I check the limit (maximumConcurrency, how many jobs can run at the same
time). If it is 0 or less, init throws `.nonPositiveMaximumConcurrency`.
Then, at start of process, I go through the jobs from left to right and
save every ID in `Set` (collection that remembers which values I have
already seen). If I find ID that is already in set, I throw
`.duplicateID` with this ID. I do this check before any worker starts (the
worker is function that does the work only for one job), so no job runs if
the input has duplicate. If list of jobs is empty, I just return empty `[]`.

Next, I start jobs, but never more than limit at the same time, this
is called bounded scheduling (running jobs with fixed maximum number at
once). For this I use `withTaskGroup` (Swift tool that runs several child
tasks and lets me wait for them one by one). At the beginning I start the
first jobs from list, as many as limit allows. Every time one job
finishes, there is free place, so I start next job that has not
started yet, I take jobs from left to right.

Jobs can finish in any order, but results must be in the same order as input. 
To make this work I use indexed result storage (I save each result
by job's position number, not in order they finish). I create 
array `outcomes` with one empty place for every job. Each child task returns
its job's index together with its outcome, and I put outcome in that
place. At the end I build the list of `JobResult` from this array, so ID
and order are the same as in `jobs`.

For each job, I turn what worker gives back into outcome (final
state of job). If worker returns number, outcome is
`.succeeded` with this number. If worker throws `CancellationError` (
special error that means work was stopped), outcome is `.cancelled`.
If it throws any other error, outcome is `.failed`. I catch all errors
inside child task, so one failed job does not stop other jobs.

Last, I handle cancellation (when code that called `process` asks it to
stop). Before I start every new job, I check `Task.isCancelled` (flag that
is true when current task was asked to stop). If it is true, I call
`group.cancelAll()` (this sends stop signal to all jobs that are still
running), I do not start any new jobs, and I wait until running jobs end.
Jobs that never started still have empty place in array, so I mark
them as `.cancelled`. Jobs that finished before the cancellation keep their
`.succeeded` or `.failed` result, `process` doesn't throw in this case; it
still returns one result for every job.

## Bonus task

For the bonus I add `RetryPolicy` (rule that says how many times one job
may be tried) and second `process` method, its worker also gets 
attempt number, if `maximumAttempts`is 0 or less, `RetryPolicy` throws `.nonPositiveMaximumAttempts`.

I don't copy scheduler for this. I move the code with limit, 
order of results and cancellation into one private function `runJobs`.
It gets closure that runs one job and returns its outcome. 
Normal `process` passes "call the worker once", and 
retry `process` passes "call the worker up to N times". So
both versions use the same tested scheduling rules.

Inside one job I try worker in loop from attempt 1 to maximum.
If it returns number, outcome is `.succeeded`, if it throws
`CancellationError`, outcome is `.cancelled` right away, without retry. 
If it throws any other error, I try again, and after last
attempt outcome is `.failed`. All attempts happen inside the same
child task, so retry uses same place in limit and never adds 
extra running job, there is no delay between attempts.

One case is not described in rules - processor is cancelled after
attempt failed with ordinary error. I decided not to start new
attempt, because after cancellation no new worker call may start,
outcome is `.failed`, because the last attempt that really ran failed with
ordinary error. 

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.

## Risks and checks

- **Wrong limit:** limit can be 0 or negative. 
- **Duplicate ID:** no worker may start before error, in my test
  worker increases counter in actor (type that keeps shared data
  safe), and I check that it stays 0.
- **Wrong duplicate reported:** for `["a", "b", "b", "a"]` I expect
  `.duplicateID("b")`, because "b" is first ID that repeats.
- **Too many jobs at once:** probe (helper actor that counts running
  workers and remembers biggest number) checks that limit is never
  exceeded. Gate (helper that holds job until test releases it)
  shows that new job starts only when place is free.
- **Wrong order of results:** I use gate to make jobs finish in reverse
  order and check that results still follow input order.
- **One bad job stops the others:** I test mix of success, ordinary error,
  and `CancellationError` and check that each job gets right outcome.
- **Jobs start after cancellation:** I hold job on gate, cancel
  `process`, and check that waiting jobs never started and are `.cancelled`,
  while job that already finished keeps `.succeeded`.
- **Limit bigger than the number of jobs:** I test that all jobs still
  finish correctly.

My tests do not use `sleep` or time checks, because such tests can pass or
fail by just luck, I control order with gates and counters, and I keep shared
test data in actors(no GCD or locks).
