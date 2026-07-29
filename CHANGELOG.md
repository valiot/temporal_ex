# CHANGELOG

## 0.2.3 [2026-07-29]

- [Improvement] `namespace/1` and `data_converter/1` are served from `:persistent_term` instead of a `GenServer.call`. These immutable reads are now lock-free and no longer share the client mailbox, so a concurrent caller blocked mid-`connect` can't make them time out. Removes the `{:timeout, {GenServer, :call, [_, :get_namespace, 5000]}}` bursts seen on every facade op (describe/start/signal) during a Temporal blip.

## 0.2.2 [2026-07-28]

- [Fix] `TemporalEx.Client` no longer sticks on a dead gRPC channel after mid-RPC gun death (`:down: :normal` / `:down: :noproc` / connection errors): the channel is dropped and the **same** `rpc/4` reconnects and retries once, so a single transport blip is usually invisible to callers.
- [Improvement] RPC network I/O runs in the caller process, not inside the GenServer. Concurrent RPCs multiplex over one HTTP/2 connection; cheap `namespace/1` / `data_converter/1` reads no longer queue behind a long Temporal call.

## 0.2.1 [2026-05-21]

- [Fix] `TemporalEx.Client.Connection.write_temp_pem_file!/2` no longer crashes with `MatchError {:error, :eexist}` when two BEAMs on the same host both initialize a Temporal client. The temp filename now includes `:os.getpid()` so independent BEAMs don't share the `System.unique_integer/1` suffix space, and the allocator retries on collision up to 8 attempts before raising. Non-`:eexist` errors now surface a real message instead of a `MatchError`. Surfaced while iterating on pipex's cluster harness, which boots three sibling BEAMs alongside the test process.

## 0.2.0 [2026-04-13]

- [New Feature] Added `TemporalEx.create_schedule/3` for creating Temporal Schedules, returning a `TemporalEx.ScheduleHandle`. Supports interval, calendar, and cron specs; overlap / catchup / pause-on-failure policies; initial paused state; memos and search attributes.
- [New Feature] Added `TemporalEx.ScheduleHandle` struct for referencing an existing schedule.
- [New Feature] Added `TemporalEx.Converter.Schedule` to encode schedule options into the Temporal RPC request.
- [New Feature] Added schedule-related error variants to `TemporalEx.Error`.
- [Improvement] `TemporalEx.Error.from_rpc_error/2` now classifies `ALREADY_EXISTS` / `NOT_FOUND` status codes using structured gRPC error details (`WorkflowExecutionAlreadyStartedFailure`, `NamespaceNotFoundFailure`, `QueryFailedFailure`) plus a caller-supplied `:context` option (`:workflow` / `:schedule`) rather than substring-matching the error message. Previously a workflow whose id contained the word "schedule" (e.g. `daily-schedule-sync`) could be misclassified as a schedule error, breaking caller pattern matches.
- [Improvement] Refreshed dependencies.
- [Improvement] Expanded README with schedule usage examples.

## 0.1.0 [2026-03-02]

- [New Feature] Initial release of the Temporal client SDK for Elixir.
- [New Feature] `TemporalEx.Client` GenServer managing the gRPC connection and data converter.
- [New Feature] Workflow lifecycle API: `start_workflow/4`, `TemporalEx.WorkflowHandle.signal/4`, `TemporalEx.WorkflowHandle.terminate/2`, `TemporalEx.WorkflowHandle.result/1`.
- [New Feature] Workflow history retrieval via `TemporalEx.get_workflow_execution_history/3`.
- [New Feature] Payload / data converter layer (`TemporalEx.Converter.Payload`, `TemporalEx.Converter.Common`) with protobuf construction hidden from callers.
- [Fix] Ensured the workflow service stub module is loaded before checking exports.