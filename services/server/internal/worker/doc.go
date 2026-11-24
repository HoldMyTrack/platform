// Package worker is cmd/holdmytrack work: dequeues jobs with FOR UPDATE SKIP LOCKED
// (IMPLEMENTATION.md §3.8, §4.1) and runs each kind runJob names: ingest, render_fog,
// edit_route, reprivacy, trip_copy and export.
// No broker, per ARCHITECTURE.md §1.1: this poll loop against idx_jobs_runnable is the whole queue.
//
// # Claiming
//
// A claim stamps locked_at in one short transaction and runs the job outside it, so a fresh
// locked_at keeps other loops off and a stale one (past claimLease) means its worker died; long
// jobs refresh it (keepClaimed).
//
// # Retries
//
// A job failing on something passing runs again after retryDelays, counted in jobs.retries; an
// ingest without limit (retryDelay). A claim a shutdown hands back counts in jobs.releases.
// attempts counts claims and only rises, so attempts - retries - releases is the runs its worker
// died in, which maxCrashes bounds.
//
// That count is inferred from outcomes recorded, and an outage that fails a job fails the write
// recording it too, so recordOutcome tries the write again until it gets through, or for a few
// seconds once the worker is stopping. A claim's attempts is its token: its outcome writes and
// heartbeat (keepClaimed) name it, so a run that outlived its lease can't touch the job once
// another loop claims it.
//
// # Lanes
//
// Three lanes, so a minutes-long render or export never holds up an upload: render (render_fog,
// WORKER_RENDER_CONCURRENCY loops), long (export, one loop) and main (every other kind,
// WORKER_CONCURRENCY). The pool is sized to the loops (db.Open).
//
// Each lane is fair (claimQuery): one job per account is considered, none from an account that
// has one of that lane claimed, and accounts go in order of when that lane last served them,
// never-served first.
package worker
