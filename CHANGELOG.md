# CHANGELOG

## 0.2.7 [2026-09-09]

- [Improvement] Refreshed dependencies. Direct: `temporalio` 1.62.7 → 1.62.13, `castore` 1.0.18 → 1.0.21, `jason` 1.4.4 → 1.4.5, plus the dev/test tools (`mox` 1.2.0 → 1.3.1, `ex_doc` 0.40.1 → 0.40.4, `credo` 1.7.17 → 1.7.19, `dialyxir` 1.4.7 → 1.4.8). Transitively this pulls the transport forward: `gun` 2.2.0 → 2.6.0, `cowlib` 2.16.0 → 2.20.0, `cowboy` 2.14.2 → 2.19.0 (clearing CVE-2026-43966, the HTTP request/response splitting issue fixed in cowboy 2.16.0), `mint` 1.7.1 → 1.10.0, `ranch` 2.2.0 → 2.3.0, `protobuf` 0.16.0 → 0.16.1, `telemetry` 1.4.1 → 1.4.2. No API or behavior change; the reconnect and GOAWAY-retry paths added in 0.2.2/0.2.4 still match on the same `gun` error strings under 2.6.0.
- [Note] `grpc` stays on 0.11.5 and still carries four open advisories (CVE-2026-48853 CRITICAL, CVE-2026-48599 / CVE-2026-53430 / CVE-2026-48854 HIGH). All four are fixed in `grpc` 1.0.0, which we cannot take yet: `temporalio` 1.62.13 itself requires `grpc ~> 0.11.0`. None of the four is reachable from this client — the RCE needs `GRPC.Codec.Erlpack` registered as a server codec, the authorization bypass needs HTTP transcoding, and the two exhaustion bugs are server request-body paths. This library is client-only and registers no custom codec, so the exposure is packaging, not runtime. Tracked separately for when `temporalio` unblocks the 1.0 line.

## 0.2.6 [2026-09-09]

- [New Feature] `TemporalEx.describe_task_queue/2,3` — calls `WorkflowService/DescribeTaskQueue` and decodes it to a plain map: `%{pollers: [%{identity, last_access_time, rate_per_second}], stats: %{backlog_count, backlog_age_ms, tasks_add_rate, tasks_dispatch_rate} | nil}`. A worker polls per task type, so the queue is described per type — `:workflow` (default), `:activity`, or `:nexus`; `report_stats` defaults on, and `backlog_age_ms` stays `nil` when unreported so an unknown age never reads as a real 0. An empty `pollers` list is the direct answer to "nothing is listening on this queue". `TemporalEx.Converter.TaskQueue` holds the request builder and response decoder.

## 0.2.5 [2026-09-07]

- [Fix] `TemporalEx.Client.Connection` temp PEM files now use a strongly-random name (`:crypto.strong_rand_bytes/1`) instead of `<os_pid>-<System.unique_integer/1>`. The 0.2.1 scheme is deterministic across BEAM *restarts* — a containerized BEAM keeps a stable OS pid and `unique_integer` resets from a low value on each boot — so a boot that wrote PEM files and crashed before cleanup (cleanup only runs on graceful shutdown) left names the next boot regenerated exactly. With a persisted `/tmp` (an emptyDir survives container restarts) every candidate then collides on `:eexist` and the client raises `could not allocate a unique temp PEM path after 8 attempts`, failing `TemporalEx.Client.init` and crash-looping the host application permanently. Random names are independent of pid, counter, and restart, so they never collide with leftover residue; the 8-attempt retry stays as defense-in-depth. Supersedes the 0.2.1 pid-suffix mitigation and covers both the multi-BEAM and the restart cases.

## 0.2.4 [2026-08-17]

- [Fix] `TemporalEx.Client` now reconnects and retries once when an RPC is refused by a connection the peer is draining — gun's `:stream_error: :closing` (the HTTP/2 GOAWAY a `keepAliveMaxConnectionAge` recycle sends) or a `{:goaway, …}` above `last_stream_id`. Both guarantee the server never processed the stream, so the retry can't double-execute; previously the recycle leaked to callers as `code: 13`. A server-sent RST (`:cancel`) or mid-flight `:closed` is left to surface, since the server may have processed the request first.

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