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
    * `:search_attributes` — Map of search attribute fields. Omit (or pass `nil`)
      to leave existing attributes untouched. Pass `%{}` to clear all attributes.
    * `:memo` — Map of memo fields. Omit (or pass `nil`) to leave existing memo
      untouched. Pass `%{}` to clear all memo fields.
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
      search_attributes: update_search_attributes(opts, converter),
      memo: update_memo(opts, converter)
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

  The second argument may be either a note string or a keyword list of
  request options. This lets callers supply options while keeping the
  default note.

  ## Examples

      :ok = TemporalEx.ScheduleHandle.pause(handle)
      :ok = TemporalEx.ScheduleHandle.pause(handle, "Pausing for maintenance")
      :ok = TemporalEx.ScheduleHandle.pause(handle, identity: "ops")
      :ok = TemporalEx.ScheduleHandle.pause(handle, "Pausing", identity: "ops")
  """
  @spec pause(t(), String.t() | keyword(), keyword()) :: :ok | {:error, Error.t()}
  def pause(handle, note_or_opts \\ "paused", opts \\ [])

  def pause(%__MODULE__{} = handle, note_or_opts, opts) do
    patch(handle, pause_opts(note_or_opts, opts))
  end

  @doc """
  Unpauses the schedule.

  The second argument may be either a note string or a keyword list of
  request options (see `pause/3`).

  ## Examples

      :ok = TemporalEx.ScheduleHandle.unpause(handle)
      :ok = TemporalEx.ScheduleHandle.unpause(handle, "Resuming after maintenance")
      :ok = TemporalEx.ScheduleHandle.unpause(handle, identity: "ops")
  """
  @spec unpause(t(), String.t() | keyword(), keyword()) :: :ok | {:error, Error.t()}
  def unpause(handle, note_or_opts \\ "unpaused", opts \\ [])

  def unpause(%__MODULE__{} = handle, note_or_opts, opts) do
    patch(handle, unpause_opts(note_or_opts, opts))
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

  # Presence-aware encoding for UpdateScheduleRequest. Temporal distinguishes
  # "field not set" (keep existing value) from "field set to empty message"
  # (clear existing value), so we cannot collapse `%{}` to `nil` the way the
  # shared `Common.to_*` helpers do.

  @doc false
  def update_search_attributes(opts, converter) do
    case Keyword.fetch(opts, :search_attributes) do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, map} when map == %{} -> %Temporal.Api.Common.V1.SearchAttributes{indexed_fields: %{}}
      {:ok, map} -> Common.to_search_attributes(map, converter)
    end
  end

  @doc false
  def update_memo(opts, converter) do
    case Keyword.fetch(opts, :memo) do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, map} when map == %{} -> %Temporal.Api.Common.V1.Memo{fields: %{}}
      {:ok, map} -> Common.to_memo(map, converter)
    end
  end

  # Builds the patch keyword list for pause/unpause when the second
  # positional argument may be either a note string or a keyword list
  # of request options. A bare keyword list is treated as options with
  # the default note, so `pause(handle, timeout: 5_000)` behaves as
  # intuition expects instead of smuggling the keyword list into the
  # protobuf `pause` string field.

  @doc false
  def pause_opts(note_or_opts, opts)

  def pause_opts(opts_keyword, extra_opts) when is_list(opts_keyword) do
    Keyword.merge(extra_opts, Keyword.put(opts_keyword, :pause, "paused"))
  end

  def pause_opts(note, opts) when is_binary(note) do
    Keyword.put(opts, :pause, note)
  end

  @doc false
  def unpause_opts(note_or_opts, opts)

  def unpause_opts(opts_keyword, extra_opts) when is_list(opts_keyword) do
    Keyword.merge(extra_opts, Keyword.put(opts_keyword, :unpause, "unpaused"))
  end

  def unpause_opts(note, opts) when is_binary(note) do
    Keyword.put(opts, :unpause, note)
  end
end
