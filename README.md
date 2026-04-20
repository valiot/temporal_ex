# TemporalEx

Ergonomic [Temporal](https://temporal.io) client SDK for Elixir.

Provides a high-level, protobuf-free API for interacting with Temporal workflow services. Work with plain Elixir terms — maps, keyword lists, strings — without constructing protobuf structs.

## Installation

Add `temporal_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:temporal_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Start a client (as part of your supervision tree)
{:ok, client} = TemporalEx.connect(
  target: "localhost:7233",
  namespace: "default"
)

# Start a workflow
{:ok, handle} = TemporalEx.start_workflow(client, "MyWorkflow", [%{key: "value"}],
  id: "my-workflow-123",
  task_queue: "my-task-queue"
)

# Interact with the workflow
:ok = TemporalEx.WorkflowHandle.signal(handle, "my-signal", [%{data: 1}])
{:ok, description} = TemporalEx.WorkflowHandle.describe(handle)
{:ok, result} = TemporalEx.WorkflowHandle.result(handle)
```

## Supervision Tree

For production use, start `TemporalEx.Client` under your application supervisor:

```elixir
children = [
  {TemporalEx.Client,
    name: :temporal_client,
    target: "localhost:7233",
    namespace: "default"
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Then reference the client by name:

```elixir
handle = TemporalEx.get_workflow_handle(:temporal_client, "my-workflow-123")
{:ok, desc} = TemporalEx.WorkflowHandle.describe(handle)
```

## Connection Options

| Option | Default | Description |
|--------|---------|-------------|
| `:target` | `"localhost:7233"` | Temporal server address |
| `:namespace` | `"default"` | Default namespace |
| `:api_key` | `nil` | API key or Bearer token |
| `:tls` | `%{}` | TLS/mTLS config (see below) |
| `:name` | `nil` | GenServer registration name |
| `:call_timeout` | `5000` | Default RPC timeout (ms) |
| `:connect_retry` | `0` | gRPC connection retries |
| `:data_converter` | `TemporalEx.DataConverter.Json` | Custom data converter module |
| `:identity` | auto | Client identity string |

### TLS / mTLS

For Temporal Cloud or self-hosted TLS:

```elixir
{TemporalEx.Client,
  target: "my-ns.tmprl.cloud:7233",
  namespace: "my-ns",
  api_key: "my-api-key",
  tls: %{
    client_cert_pem_b64: System.get_env("TEMPORAL_CLIENT_CERT"),
    client_key_pem_b64: System.get_env("TEMPORAL_CLIENT_KEY"),
    ca_cert_file: "/path/to/ca.pem"  # optional
  }
}
```

Temporal Cloud domains (`.tmprl.cloud`, `.api.temporal.io`) automatically use HTTPS.

## API

### Workflow Operations

```elixir
# Start a workflow
{:ok, handle} = TemporalEx.start_workflow(client, "WorkflowType", args, opts)

# Start with an initial signal (atomic)
{:ok, handle} = TemporalEx.signal_with_start(client, "WorkflowType", args, "signal", signal_args, opts)

# Get a handle to an existing workflow
handle = TemporalEx.get_workflow_handle(client, "workflow-id")
handle = TemporalEx.get_workflow_handle(client, "workflow-id", "run-id")
```

### WorkflowHandle Operations

```elixir
{:ok, description} = TemporalEx.WorkflowHandle.describe(handle)
:ok              = TemporalEx.WorkflowHandle.signal(handle, "signal-name", [args])
{:ok, result}    = TemporalEx.WorkflowHandle.query(handle, "query-type", [args])
:ok              = TemporalEx.WorkflowHandle.cancel(handle)
:ok              = TemporalEx.WorkflowHandle.terminate(handle, reason: "reason")
:ok              = TemporalEx.WorkflowHandle.delete(handle)
{:ok, history}   = TemporalEx.WorkflowHandle.get_history(handle)
{:ok, result}    = TemporalEx.WorkflowHandle.result(handle)
{:ok, reset}     = TemporalEx.WorkflowHandle.reset(handle, opts)
```

### Schedule Operations

Temporal Schedules are server-side crons — Temporal starts workflow executions on the configured interval. The worker doesn't need to be running when the schedule is created; it just needs to be available to pick up workflow tasks from the queue.

```elixir
# Create a schedule that runs every 60 seconds
{:ok, handle} = TemporalEx.create_schedule(client, "my-schedule",
  spec: [intervals: [[every: 60]]],
  action: [
    workflow_type: "MyWorkflow",
    workflow_id: "my-workflow",
    task_queue: "my-queue",
    args: [%{key: "value"}]
  ],
  policies: [overlap_policy: :skip]
)

# Get a handle to an existing schedule
handle = TemporalEx.get_schedule_handle(client, "my-schedule")

# List all schedules
{:ok, schedules, next_token} = TemporalEx.list_schedules(client)
```

### ScheduleHandle Operations

```elixir
{:ok, description} = TemporalEx.ScheduleHandle.describe(handle)
:ok              = TemporalEx.ScheduleHandle.pause(handle, note: "maintenance")
:ok              = TemporalEx.ScheduleHandle.unpause(handle, note: "back online")
:ok              = TemporalEx.ScheduleHandle.trigger(handle)
:ok              = TemporalEx.ScheduleHandle.update(handle, schedule: [...])
:ok              = TemporalEx.ScheduleHandle.delete(handle)
```

#### Schedule Spec Options

```elixir
# Interval-based (every N seconds, with optional offset)
spec: [intervals: [[every: 60], [every: 300, offset: 10]]]

# Calendar-based
spec: [calendars: [[hour: "8", minute: "30", day_of_week: "MON-FRI"]]]

# Cron expressions
spec: [cron_expressions: ["0 */5 * * *"]]

# With timezone and jitter
spec: [intervals: [[every: 60]], timezone: "America/Chicago", jitter: 5]
```

#### Overlap Policies

| Policy | Description |
|--------|-------------|
| `:skip` | Skip if previous is still running |
| `:buffer_one` | Buffer one execution |
| `:buffer_all` | Buffer all executions |
| `:cancel_other` | Cancel the running execution |
| `:terminate_other` | Terminate the running execution |
| `:allow_all` | Allow concurrent executions |

### Visibility

```elixir
{:ok, workflows, next_token} = TemporalEx.list_workflows(client, "WorkflowType = 'MyWorkflow'")
{:ok, count} = TemporalEx.count_workflows(client, "WorkflowType = 'MyWorkflow'")
```

### System

```elixir
{:ok, info} = TemporalEx.get_system_info(client)
```

## Error Handling

All errors are returned as typed structs:

- `TemporalEx.Error.WorkflowAlreadyStarted`
- `TemporalEx.Error.WorkflowNotFound`
- `TemporalEx.Error.ScheduleAlreadyExists`
- `TemporalEx.Error.ScheduleNotFound`
- `TemporalEx.Error.NamespaceNotFound`
- `TemporalEx.Error.QueryFailed`
- `TemporalEx.Error.RPCError` (catch-all)

```elixir
case TemporalEx.start_workflow(client, "MyWorkflow", [], id: "wf-1", task_queue: "q") do
  {:ok, handle} -> handle
  {:error, %TemporalEx.Error.WorkflowAlreadyStarted{}} -> # handle duplicate
  {:error, %TemporalEx.Error.RPCError{message: msg}} -> # handle other errors
end
```

## Custom Data Converter

Implement the `TemporalEx.DataConverter` behaviour to use a custom serialization format:

```elixir
defmodule MyConverter do
  @behaviour TemporalEx.DataConverter

  @impl true
  def encoding, do: "my-encoding"

  @impl true
  def encode(term), do: {:ok, {serialize(term), %{}}}

  @impl true
  def decode(binary, _metadata), do: {:ok, deserialize(binary)}
end

{TemporalEx.Client, data_converter: MyConverter, ...}
```

## License

MIT - see [LICENSE](LICENSE).
