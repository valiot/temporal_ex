defmodule TemporalEx.WorkflowHandle do
  @moduledoc """
  A handle to a running or completed workflow execution.

  Carries the client reference, workflow ID, run ID, and namespace so
  that callers never need to pass the client or IDs again after
  obtaining a handle from `TemporalEx.start_workflow/4` or
  `TemporalEx.get_workflow_handle/3`.
  """

  alias TemporalEx.Client
  alias TemporalEx.Converter.{Common, Payload}
  alias TemporalEx.Error

  @enforce_keys [:client, :workflow_id]
  defstruct [:client, :workflow_id, :run_id, :namespace, :first_execution_run_id]

  @type t :: %__MODULE__{
          client: GenServer.server(),
          workflow_id: String.t(),
          run_id: String.t() | nil,
          namespace: String.t() | nil,
          first_execution_run_id: String.t() | nil
        }

  @doc """
  Describes the workflow execution.

  Returns info including status, start time, close time, type, task queue, etc.
  """
  @spec describe(t(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def describe(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.DescribeWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      execution: Common.workflow_execution(handle.workflow_id, handle.run_id)
    }

    case Client.rpc(handle.client, :describe_workflow_execution, request, rpc_opts(handle, opts)) do
      {:ok, response} -> {:ok, response}
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Sends a signal to the workflow execution.

  ## Options

    * `:identity` — Caller identity
    * `:request_id` — Idempotency key
  """
  @spec signal(t(), String.t(), list(), keyword()) :: :ok | {:error, Error.t()}
  def signal(%__MODULE__{} = handle, signal_name, args \\ [], opts \\ []) do
    converter = resolve_converter(handle)

    request = %Temporal.Api.Workflowservice.V1.SignalWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      workflow_execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      signal_name: signal_name,
      input: if(args == [], do: nil, else: Payload.encode(args, converter)),
      identity: Keyword.get(opts, :identity, ""),
      request_id: Keyword.get(opts, :request_id, "")
    }

    case Client.rpc(handle.client, :signal_workflow_execution, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Queries the workflow execution.

  ## Options

    * `:reject_condition` — When to reject the query (e.g., `:not_open`, `:not_completed_cleanly`)
  """
  @spec query(t(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def query(%__MODULE__{} = handle, query_type, args \\ [], opts \\ []) do
    converter = resolve_converter(handle)

    query_struct = %Temporal.Api.Query.V1.WorkflowQuery{
      query_type: query_type,
      query_args: if(args == [], do: nil, else: Payload.encode(args, converter))
    }

    reject_condition = query_reject_condition(Keyword.get(opts, :reject_condition))

    request = %Temporal.Api.Workflowservice.V1.QueryWorkflowRequest{
      namespace: resolve_namespace(handle),
      execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      query: query_struct,
      query_reject_condition: reject_condition
    }

    case Client.rpc(handle.client, :query_workflow, request, rpc_opts(handle, opts)) do
      {:ok, response} ->
        result =
          if response.query_result do
            Payload.decode(response.query_result, converter)
          else
            nil
          end

        {:ok, result}

      {:error, err} ->
        {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Requests cancellation of the workflow execution.

  ## Options

    * `:identity` — Caller identity
    * `:request_id` — Idempotency key
  """
  @spec cancel(t(), keyword()) :: :ok | {:error, Error.t()}
  def cancel(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.RequestCancelWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      workflow_execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      identity: Keyword.get(opts, :identity, ""),
      request_id: Keyword.get(opts, :request_id, ""),
      first_execution_run_id: handle.first_execution_run_id || ""
    }

    case Client.rpc(
           handle.client,
           :request_cancel_workflow_execution,
           request,
           rpc_opts(handle, opts)
         ) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Terminates the workflow execution.

  ## Options

    * `:reason` — Human-readable termination reason
    * `:details` — Additional data to record with the termination
    * `:identity` — Caller identity
  """
  @spec terminate(t(), keyword()) :: :ok | {:error, Error.t()}
  def terminate(%__MODULE__{} = handle, opts \\ []) do
    converter = resolve_converter(handle)
    reason = Keyword.get(opts, :reason, "")
    details = Keyword.get(opts, :details)

    details_payloads =
      if details do
        Payload.encode(List.wrap(details), converter)
      else
        nil
      end

    request = %Temporal.Api.Workflowservice.V1.TerminateWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      workflow_execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      reason: reason,
      details: details_payloads,
      identity: Keyword.get(opts, :identity, ""),
      first_execution_run_id: handle.first_execution_run_id || ""
    }

    case Client.rpc(handle.client, :terminate_workflow_execution, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Deletes the workflow execution from visibility.
  """
  @spec delete(t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.DeleteWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      workflow_execution: Common.workflow_execution(handle.workflow_id, handle.run_id)
    }

    case Client.rpc(handle.client, :delete_workflow_execution, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Fetches the workflow execution history.

  ## Options

    * `:reverse` — If `true`, returns events in reverse chronological order (default: `false`)
    * `:page_size` — Maximum number of events per page (default: 1000)
    * `:next_page_token` — Token for pagination
    * `:wait_new_event` — If `true`, long-polls for new events (default: `false`)
    * `:filter_type` — Event filter type atom
  """
  @spec get_history(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_history(%__MODULE__{} = handle, opts \\ []) do
    reverse = Keyword.get(opts, :reverse, false)

    rpc_name =
      if reverse,
        do: :get_workflow_execution_history_reverse,
        else: :get_workflow_execution_history

    request = %Temporal.Api.Workflowservice.V1.GetWorkflowExecutionHistoryRequest{
      namespace: resolve_namespace(handle),
      execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      maximum_page_size: Keyword.get(opts, :page_size, 1000),
      next_page_token: Keyword.get(opts, :next_page_token, ""),
      wait_new_event: Keyword.get(opts, :wait_new_event, false),
      history_event_filter_type:
        Keyword.get(opts, :filter_type, :HISTORY_EVENT_FILTER_TYPE_UNSPECIFIED),
      skip_archival: Keyword.get(opts, :skip_archival, false)
    }

    case Client.rpc(handle.client, rpc_name, request, rpc_opts(handle, opts)) do
      {:ok, response} ->
        {:ok,
         %{
           history: response.history,
           next_page_token: response.next_page_token,
           archived: Map.get(response, :archived, false)
         }}

      {:error, err} ->
        {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Long-polls for the workflow result by watching for close events in history.

  ## Options

    * `:timeout` — Maximum time to wait in milliseconds
    * `:follow_runs` — If `true`, follows continue-as-new chains (default: `true`)
  """
  @spec result(t(), keyword()) :: {:ok, term()} | {:error, Error.t() | term()}
  def result(%__MODULE__{} = handle, opts \\ []) do
    converter = resolve_converter(handle)
    timeout = Keyword.get(opts, :timeout, 30_000)

    request = %Temporal.Api.Workflowservice.V1.GetWorkflowExecutionHistoryRequest{
      namespace: resolve_namespace(handle),
      execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      maximum_page_size: 1,
      wait_new_event: true,
      history_event_filter_type: :HISTORY_EVENT_FILTER_TYPE_CLOSE_EVENT,
      skip_archival: true
    }

    case Client.rpc(
           handle.client,
           :get_workflow_execution_history,
           request,
           rpc_opts(handle, Keyword.put(opts, :timeout, timeout))
         ) do
      {:ok, response} ->
        extract_result_from_close_event(response, converter)

      {:error, err} ->
        {:error, Error.from_rpc_error(err)}
    end
  end

  @doc """
  Resets the workflow execution to a specific point.

  ## Options

    * `:workflow_task_finish_event_id` — Event ID to reset to (required)
    * `:reason` — Reset reason
    * `:request_id` — Idempotency key
    * `:reset_reapply_type` — How to reapply signals (default: `:RESET_REAPPLY_TYPE_SIGNAL`)
  """
  @spec reset(t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def reset(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.ResetWorkflowExecutionRequest{
      namespace: resolve_namespace(handle),
      workflow_execution: Common.workflow_execution(handle.workflow_id, handle.run_id),
      reason: Keyword.get(opts, :reason, ""),
      workflow_task_finish_event_id: Keyword.fetch!(opts, :workflow_task_finish_event_id),
      request_id: Keyword.get(opts, :request_id, ""),
      reset_reapply_type: Keyword.get(opts, :reset_reapply_type, :RESET_REAPPLY_TYPE_SIGNAL)
    }

    case Client.rpc(handle.client, :reset_workflow_execution, request, rpc_opts(handle, opts)) do
      {:ok, response} -> {:ok, response.run_id}
      {:error, err} -> {:error, Error.from_rpc_error(err)}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp resolve_namespace(handle) do
    handle.namespace || Client.namespace(handle.client)
  end

  defp resolve_converter(handle) do
    Client.data_converter(handle.client)
  end

  defp rpc_opts(handle, opts) do
    namespace = resolve_namespace(handle)
    base = [namespace: namespace]

    if timeout = Keyword.get(opts, :timeout) do
      Keyword.put(base, :timeout, timeout)
    else
      base
    end
  end

  defp query_reject_condition(nil), do: :QUERY_REJECT_CONDITION_UNSPECIFIED
  defp query_reject_condition(:not_open), do: :QUERY_REJECT_CONDITION_NOT_OPEN

  defp query_reject_condition(:not_completed_cleanly),
    do: :QUERY_REJECT_CONDITION_NOT_COMPLETED_CLEANLY

  defp query_reject_condition(value) when is_atom(value), do: value

  defp extract_result_from_close_event(response, converter) do
    case response.history do
      %{events: [event | _]} ->
        extract_from_event_attributes(event, converter)

      _ ->
        {:error, :no_close_event}
    end
  end

  defp extract_from_event_attributes(event, converter) do
    case event.attributes do
      {:workflow_execution_completed_event_attributes, attrs} ->
        result =
          if attrs.result do
            Payload.decode(attrs.result, converter)
          else
            []
          end

        {:ok, result}

      {:workflow_execution_failed_event_attributes, attrs} ->
        {:error, {:workflow_failed, attrs.failure}}

      {:workflow_execution_canceled_event_attributes, _attrs} ->
        {:error, :workflow_canceled}

      {:workflow_execution_terminated_event_attributes, _attrs} ->
        {:error, :workflow_terminated}

      {:workflow_execution_timed_out_event_attributes, _attrs} ->
        {:error, :workflow_timed_out}

      {:workflow_execution_continued_as_new_event_attributes, attrs} ->
        {:error, {:continued_as_new, attrs.new_execution_run_id}}

      _ ->
        {:error, :unknown_close_event}
    end
  end
end
