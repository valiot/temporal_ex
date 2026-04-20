defmodule TemporalEx do
  @moduledoc """
  Ergonomic Temporal client SDK for Elixir.

  Provides a high-level, protobuf-free API for interacting with Temporal
  workflow services. Users work with plain Elixir terms — maps, keyword
  lists, strings — and never need to construct protobuf structs.

  ## Quick Start

      # Start a client connection
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
  """

  alias TemporalEx.{Client, WorkflowHandle, ScheduleHandle}
  alias TemporalEx.Converter.{Common, Payload, Schedule}
  alias TemporalEx.Error

  @doc """
  Starts a supervised client process connected to a Temporal server.

  ## Options

    * `:target` — Temporal server address (default: `"localhost:7233"`)
    * `:namespace` — Default namespace (default: `"default"`)
    * `:api_key` — API key or Bearer token
    * `:tls` — Map/keyword list with `:client_cert_pem_b64`, `:client_key_pem_b64`, `:ca_cert_file`
    * `:identity` — Client identity string
    * `:data_converter` — Module implementing `TemporalEx.DataConverter`
      (default: `TemporalEx.DataConverter.Json`)
    * `:name` — GenServer registration name
    * `:call_timeout` — Default RPC timeout in ms (default: 5000)

  ## Examples

      {:ok, client} = TemporalEx.connect(target: "localhost:7233", namespace: "default")

      {:ok, client} = TemporalEx.connect(
        target: "my-ns.tmprl.cloud:7233",
        namespace: "my-ns",
        api_key: "my-api-key"
      )
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts \\ []) do
    Client.start_link(opts)
  end

  @doc """
  Starts a new workflow execution.

  ## Arguments

    * `client` — Client pid or registered name
    * `workflow_type` — Workflow type name string
    * `args` — List of arguments to pass to the workflow
    * `opts` — Keyword list of options

  ## Options (required)

    * `:id` — Unique workflow ID
    * `:task_queue` — Task queue to schedule the workflow on

  ## Options (optional)

    * `:execution_timeout` — Max total workflow execution time in seconds
    * `:run_timeout` — Max single run time in seconds
    * `:task_timeout` — Max workflow task processing time in seconds
    * `:retry_policy` — Keyword list or map with retry config
    * `:memo` — Map of memo fields
    * `:search_attributes` — Map of search attribute fields
    * `:start_delay` — Delay before starting the workflow in seconds
    * `:request_id` — Idempotency key
    * `:identity` — Caller identity
    * `:id_reuse_policy` — Workflow ID reuse policy atom
    * `:id_conflict_policy` — Workflow ID conflict policy atom
    * `:cron_schedule` — Cron schedule string

  ## Examples

      {:ok, handle} = TemporalEx.start_workflow(client, "ProcessOrder", [%{order_id: 123}],
        id: "order-123",
        task_queue: "orders"
      )
  """
  @spec start_workflow(GenServer.server(), String.t(), list(), keyword()) ::
          {:ok, WorkflowHandle.t()} | {:error, Error.t()}
  def start_workflow(client, workflow_type, args, opts) when is_list(opts) do
    workflow_id = Keyword.fetch!(opts, :id)
    task_queue = Keyword.fetch!(opts, :task_queue)
    converter = Client.data_converter(client)
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    request = %Temporal.Api.Workflowservice.V1.StartWorkflowExecutionRequest{
      namespace: namespace,
      workflow_id: workflow_id,
      workflow_type: Common.workflow_type(workflow_type),
      task_queue: Common.task_queue(task_queue),
      input: if(args == [], do: nil, else: Payload.encode(args, converter)),
      workflow_execution_timeout: Common.to_duration(Keyword.get(opts, :execution_timeout)),
      workflow_run_timeout: Common.to_duration(Keyword.get(opts, :run_timeout)),
      workflow_task_timeout: Common.to_duration(Keyword.get(opts, :task_timeout)),
      retry_policy: Common.to_retry_policy(Keyword.get(opts, :retry_policy)),
      memo: Common.to_memo(Keyword.get(opts, :memo), converter),
      search_attributes:
        Common.to_search_attributes(Keyword.get(opts, :search_attributes), converter),
      workflow_start_delay: Common.to_duration(Keyword.get(opts, :start_delay)),
      request_id: Keyword.get(opts, :request_id, ""),
      identity: Keyword.get(opts, :identity, ""),
      workflow_id_reuse_policy:
        Keyword.get(opts, :id_reuse_policy, :WORKFLOW_ID_REUSE_POLICY_UNSPECIFIED),
      workflow_id_conflict_policy:
        Keyword.get(opts, :id_conflict_policy, :WORKFLOW_ID_CONFLICT_POLICY_UNSPECIFIED),
      cron_schedule: Keyword.get(opts, :cron_schedule, "")
    }

    case Client.rpc(client, :start_workflow_execution, request, namespace: namespace) do
      {:ok, response} ->
        handle = %WorkflowHandle{
          client: client,
          workflow_id: workflow_id,
          run_id: response.run_id,
          namespace: namespace
        }

        {:ok, handle}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :workflow)}
    end
  end

  @doc """
  Returns a `WorkflowHandle` for an existing workflow execution.

  This does not make any RPC calls — it simply creates the handle struct.

  ## Examples

      handle = TemporalEx.get_workflow_handle(client, "my-workflow-123")
      {:ok, desc} = TemporalEx.WorkflowHandle.describe(handle)
  """
  @spec get_workflow_handle(GenServer.server(), String.t(), String.t() | nil) ::
          WorkflowHandle.t()
  def get_workflow_handle(client, workflow_id, run_id \\ nil) do
    %WorkflowHandle{
      client: client,
      workflow_id: workflow_id,
      run_id: run_id,
      namespace: Client.namespace(client)
    }
  end

  @doc """
  Starts a workflow with an initial signal atomically.

  If the workflow is already running, only the signal is delivered.

  ## Arguments

    * `client` — Client pid or registered name
    * `workflow_type` — Workflow type name string
    * `args` — List of workflow arguments
    * `signal_name` — Signal name to send
    * `signal_args` — List of signal arguments
    * `opts` — Same options as `start_workflow/4`
  """
  @spec signal_with_start(GenServer.server(), String.t(), list(), String.t(), list(), keyword()) ::
          {:ok, WorkflowHandle.t()} | {:error, Error.t()}
  def signal_with_start(client, workflow_type, args, signal_name, signal_args, opts)
      when is_list(opts) do
    workflow_id = Keyword.fetch!(opts, :id)
    task_queue = Keyword.fetch!(opts, :task_queue)
    converter = Client.data_converter(client)
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    request = %Temporal.Api.Workflowservice.V1.SignalWithStartWorkflowExecutionRequest{
      namespace: namespace,
      workflow_id: workflow_id,
      workflow_type: Common.workflow_type(workflow_type),
      task_queue: Common.task_queue(task_queue),
      input: if(args == [], do: nil, else: Payload.encode(args, converter)),
      signal_name: signal_name,
      signal_input: if(signal_args == [], do: nil, else: Payload.encode(signal_args, converter)),
      workflow_execution_timeout: Common.to_duration(Keyword.get(opts, :execution_timeout)),
      workflow_run_timeout: Common.to_duration(Keyword.get(opts, :run_timeout)),
      workflow_task_timeout: Common.to_duration(Keyword.get(opts, :task_timeout)),
      retry_policy: Common.to_retry_policy(Keyword.get(opts, :retry_policy)),
      memo: Common.to_memo(Keyword.get(opts, :memo), converter),
      search_attributes:
        Common.to_search_attributes(Keyword.get(opts, :search_attributes), converter),
      request_id: Keyword.get(opts, :request_id, ""),
      identity: Keyword.get(opts, :identity, ""),
      cron_schedule: Keyword.get(opts, :cron_schedule, "")
    }

    case Client.rpc(client, :signal_with_start_workflow_execution, request, namespace: namespace) do
      {:ok, response} ->
        handle = %WorkflowHandle{
          client: client,
          workflow_id: workflow_id,
          run_id: response.run_id,
          namespace: namespace
        }

        {:ok, handle}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :workflow)}
    end
  end

  @doc """
  Lists workflow executions matching a visibility query.

  ## Options

    * `:page_size` — Maximum number of results per page (default: 100)
    * `:next_page_token` — Token for pagination

  ## Examples

      {:ok, workflows, token} = TemporalEx.list_workflows(client, "WorkflowType = 'MyWorkflow'")
  """
  @spec list_workflows(GenServer.server(), String.t(), keyword()) ::
          {:ok, list(), binary()} | {:error, Error.t()}
  def list_workflows(client, query, opts \\ []) do
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    request = %Temporal.Api.Workflowservice.V1.ListWorkflowExecutionsRequest{
      namespace: namespace,
      page_size: Keyword.get(opts, :page_size, 100),
      next_page_token: Keyword.get(opts, :next_page_token, ""),
      query: query
    }

    case Client.rpc(client, :list_workflow_executions, request, namespace: namespace) do
      {:ok, response} ->
        {:ok, response.executions, response.next_page_token}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :workflow)}
    end
  end

  @doc """
  Counts workflow executions matching a visibility query.

  ## Examples

      {:ok, count} = TemporalEx.count_workflows(client, "WorkflowType = 'MyWorkflow'")
  """
  @spec count_workflows(GenServer.server(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, Error.t()}
  def count_workflows(client, query, opts \\ []) do
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    request = %Temporal.Api.Workflowservice.V1.CountWorkflowExecutionsRequest{
      namespace: namespace,
      query: query
    }

    case Client.rpc(client, :count_workflow_executions, request, namespace: namespace) do
      {:ok, response} ->
        {:ok, response.count}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :workflow)}
    end
  end

  @doc """
  Returns system information from the Temporal server.

  ## Examples

      {:ok, info} = TemporalEx.get_system_info(client)
  """
  @spec get_system_info(GenServer.server()) :: {:ok, struct()} | {:error, Error.t()}
  def get_system_info(client) do
    request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

    case Client.rpc(client, :get_system_info, request) do
      {:ok, response} -> {:ok, response}
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  # ── Schedules ──────────────────────────────────────────────────────

  @doc """
  Creates a new Temporal Schedule.

  ## Arguments

    * `client` — Client pid or registered name
    * `schedule_id` — Unique schedule identifier
    * `opts` — Schedule configuration

  ## Options (required)

    * `:spec` — When the schedule triggers (keyword list):
      * `:intervals` — List of interval specs: `[[every: 60]]` (seconds) or `[[every: 60, offset: 10]]`
      * `:calendars` — List of calendar specs: `[[hour: "8", minute: "30"]]`
      * `:cron_expressions` — List of cron strings: `["0 */5 * * *"]`
      * `:timezone` — Timezone name: `"America/Chicago"`
      * `:jitter` — Max random jitter in seconds
      * `:start_time` / `:end_time` — `DateTime` bounds

    * `:action` — What to run (keyword list):
      * `:workflow_type` — Workflow type name (required)
      * `:workflow_id` — Workflow ID (required)
      * `:task_queue` — Task queue name (required)
      * `:args` — List of workflow arguments

  ## Options (optional)

    * `:policies` — Scheduling policies (keyword list):
      * `:overlap_policy` — `:skip`, `:buffer_one`, `:buffer_all`, `:cancel_other`, `:terminate_other`, `:allow_all`
      * `:catchup_window` — Seconds
      * `:pause_on_failure` — Boolean

    * `:state` — Initial state:
      * `:paused` — Boolean
      * `:notes` — String

    * `:memo` — Map of memo fields
    * `:search_attributes` — Map of search attributes
    * `:identity` — Caller identity
    * `:request_id` — Idempotency key

  ## Examples

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
  """
  @spec create_schedule(GenServer.server(), String.t(), keyword()) ::
          {:ok, ScheduleHandle.t()} | {:error, Error.t()}
  def create_schedule(client, schedule_id, opts) when is_list(opts) do
    converter = Client.data_converter(client)
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    schedule_opts =
      [
        spec: Keyword.get(opts, :spec),
        action: Keyword.get(opts, :action),
        policies: Keyword.get(opts, :policies),
        state: Keyword.get(opts, :state)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    request = %Temporal.Api.Workflowservice.V1.CreateScheduleRequest{
      namespace: namespace,
      schedule_id: schedule_id,
      schedule: Schedule.to_schedule(schedule_opts, converter),
      memo: Common.to_memo(Keyword.get(opts, :memo), converter),
      search_attributes:
        Common.to_search_attributes(Keyword.get(opts, :search_attributes), converter),
      identity: Keyword.get(opts, :identity, ""),
      request_id: Keyword.get_lazy(opts, :request_id, &Common.request_id/0)
    }

    case Client.rpc(client, :create_schedule, request, namespace: namespace) do
      {:ok, _response} ->
        handle = %ScheduleHandle{
          client: client,
          schedule_id: schedule_id,
          namespace: namespace
        }

        {:ok, handle}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :schedule)}
    end
  end

  @doc """
  Returns a `ScheduleHandle` for an existing schedule.

  This does not make any RPC calls — it simply creates the handle struct.

  ## Examples

      handle = TemporalEx.get_schedule_handle(client, "my-schedule")
      {:ok, desc} = TemporalEx.ScheduleHandle.describe(handle)
  """
  @spec get_schedule_handle(GenServer.server(), String.t()) :: ScheduleHandle.t()
  def get_schedule_handle(client, schedule_id) do
    %ScheduleHandle{
      client: client,
      schedule_id: schedule_id,
      namespace: Client.namespace(client)
    }
  end

  @doc """
  Lists schedules matching an optional query.

  ## Options

    * `:page_size` — Maximum results per page (default: 100)
    * `:next_page_token` — Pagination token

  ## Examples

      {:ok, schedules, token} = TemporalEx.list_schedules(client)
  """
  @spec list_schedules(GenServer.server(), keyword()) ::
          {:ok, list(), binary()} | {:error, Error.t()}
  def list_schedules(client, opts \\ []) do
    namespace = Keyword.get(opts, :namespace) || Client.namespace(client)

    request = %Temporal.Api.Workflowservice.V1.ListSchedulesRequest{
      namespace: namespace,
      maximum_page_size: Keyword.get(opts, :page_size, 100),
      next_page_token: Keyword.get(opts, :next_page_token, ""),
      query: Keyword.get(opts, :query, "")
    }

    case Client.rpc(client, :list_schedules, request, namespace: namespace) do
      {:ok, response} ->
        {:ok, response.schedules, response.next_page_token}

      {:error, err} ->
        {:error, Error.from_rpc_error(err, context: :schedule)}
    end
  end
end
