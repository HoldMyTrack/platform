// Package worker is cmd/holdmytrack work: dequeues jobs with FOR UPDATE SKIP LOCKED
// (IMPLEMENTATION.md §3.8, §4.1) and runs internal/ingest for `ingest` and `edit_track` jobs.
// No broker, per ARCHITECTURE.md §1.1: this poll loop against idx_jobs_runnable is the whole queue.
//
// # Claiming
//
// A claim stamps locked_at in one short transaction and runs the job outside it, so a fresh
// locked_at keeps other loops off and a stale one (past claimLease) means its worker died; long
// jobs refresh it (keepClaimed).
//
// # Lanes
//
// Three lanes, so a minutes-long render or export never holds up an upload: render (render_fog,
// WORKER_RENDER_CONCURRENCY loops), long (export, one loop) and main (every other kind,
// WORKER_CONCURRENCY). The pool is sized to the loops (db.OpenSized).
//
// Each lane is fair (claimQuery): one job per account is considered, none from an account that
// has one of that lane claimed, and accounts go in order of when that lane last served them,
// never-served first.
package worker
