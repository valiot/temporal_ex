# CHANGELOG

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