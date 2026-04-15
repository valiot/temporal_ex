defmodule TemporalEx.ScheduleHandle do
  @moduledoc """
  A handle to a Temporal Schedule.

  Carries the client reference, schedule ID, and namespace so that
  callers never need to pass the client or IDs again after obtaining
  a handle from `TemporalEx.create_schedule/3` or
  `TemporalEx.get_schedule_handle/2`.
  """

  alias TemporalEx.Client
  alias TemporalEx.Converter.Common
  alias TemporalEx.Converter.Schedule, as: ScheduleConverter
  alias TemporalEx.Error

  @enforce_keys [:client, :schedule_id]
  defstruct [:client, :schedule_id, :namespace]

  @type t :: %__MODULE__{
          client: GenServer.server(),
          schedule_id: String.t(),
          namespace: String.t() | nil
        }

  @doc """
  Describes the schedule, returning its spec, action, policies, state, and info.

  ## Examples

      {:ok, description} = TemporalEx.ScheduleHandle.describe(handle)
  """
  @spec describe(t(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def describe(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.DescribeScheduleRequest{
      namespace: resolve_namespace(handle),
      schedule_id: handle.schedule_id
    }

    case Client.rpc(handle.client, :describe_schedule, request, rpc_opts(handle, opts)) do
      {:ok, response} -> {:ok, response}
      {:error, err} -> {:error, Error.from_rpc_error(err, context: :schedule)}
    end
  end

  @doc """
  Updates the schedule with a new definition.

  ## Options

    * `:schedule` — Schedule definition keyword list (same format as `TemporalEx.create_schedule/3`)
    * `:conflict_token` — Conflict token from a previous describe (for optimistic locking)
    * `:identity` — Caller identity
    * `:request_id` — Idempotency key
    * `:search_attributes` — Map of search attribute fields
    * `:memo` — Map of memo fields
  """
  @spec update(t(), keyword()) :: :ok | {:error, Error.t()}
  def update(%__MODULE__{} = handle, opts \\ []) do
    converter = resolve_converter(handle)

    request = %Temporal.Api.Workflowservice.V1.UpdateScheduleRequest{
      namespace: resolve_namespace(handle),
      schedule_id: handle.schedule_id,
      schedule: ScheduleConverter.to_schedule(Keyword.fetch!(opts, :schedule), converter),
      conflict_token: Keyword.get(opts, :conflict_token, ""),
      identity: Keyword.get(opts, :identity, ""),
      request_id: Keyword.get_lazy(opts, :request_id, &Common.request_id/0),
      search_attributes:
        Common.to_search_attributes(Keyword.get(opts, :search_attributes), converter),
      memo: Common.to_memo(Keyword.get(opts, :memo), converter)
    }

    case Client.rpc(handle.client, :update_schedule, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err, context: :schedule)}
    end
  end

  @doc """
  Patches the schedule to pause, unpause, trigger immediately, or backfill.

  ## Options

    * `:pause` — String note to pause with
    * `:unpause` — String note to unpause with
    * `:trigger_immediately` — `true` or keyword list with `:overlap_policy`
    * `:backfill` — List of `[start_time: DateTime, end_time: DateTime, overlap_policy: atom]`
    * `:identity` — Caller identity
    * `:request_id` — Idempotency key
  """
  @spec patch(t(), keyword()) :: :ok | {:error, Error.t()}
  def patch(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.PatchScheduleRequest{
      namespace: resolve_namespace(handle),
      schedule_id: handle.schedule_id,
      patch: ScheduleConverter.to_schedule_patch(opts),
      identity: Keyword.get(opts, :identity, ""),
      request_id: Keyword.get_lazy(opts, :request_id, &Common.request_id/0)
    }

    case Client.rpc(handle.client, :patch_schedule, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err, context: :schedule)}
    end
  end

  @doc """
  Pauses the schedule.

  ## Examples

      :ok = TemporalEx.ScheduleHandle.pause(handle, "Pausing for maintenance")
  """
  @spec pause(t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def pause(%__MODULE__{} = handle, note \\ "paused", opts \\ []) do
    patch(handle, Keyword.merge(opts, pause: note))
  end

  @doc """
  Unpauses the schedule.

  ## Examples

      :ok = TemporalEx.ScheduleHandle.unpause(handle, "Resuming after maintenance")
  """
  @spec unpause(t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def unpause(%__MODULE__{} = handle, note \\ "unpaused", opts \\ []) do
    patch(handle, Keyword.merge(opts, unpause: note))
  end

  @doc """
  Triggers the schedule to run immediately.

  ## Options

    * `:overlap_policy` — Override overlap policy for this trigger
  """
  @spec trigger(t(), keyword()) :: :ok | {:error, Error.t()}
  def trigger(%__MODULE__{} = handle, opts \\ []) do
    trigger_opts =
      case Keyword.get(opts, :overlap_policy) do
        nil -> true
        policy -> [overlap_policy: policy]
      end

    patch(handle, Keyword.merge(opts, trigger_immediately: trigger_opts))
  end

  @doc """
  Deletes the schedule.

  ## Options

    * `:identity` — Caller identity
  """
  @spec delete(t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{} = handle, opts \\ []) do
    request = %Temporal.Api.Workflowservice.V1.DeleteScheduleRequest{
      namespace: resolve_namespace(handle),
      schedule_id: handle.schedule_id,
      identity: Keyword.get(opts, :identity, "")
    }

    case Client.rpc(handle.client, :delete_schedule, request, rpc_opts(handle, opts)) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, Error.from_rpc_error(err, context: :schedule)}
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
end
