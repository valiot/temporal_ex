defmodule TemporalEx.Converter.Common do
  @moduledoc """
  Helpers for building common Temporal protobuf types from plain Elixir values.
  """

  @doc """
  Builds a `Temporal.Api.Common.V1.WorkflowType` struct.
  """
  def workflow_type(name) when is_binary(name) do
    %Temporal.Api.Common.V1.WorkflowType{name: name}
  end

  @doc """
  Builds a `Temporal.Api.Taskqueue.V1.TaskQueue` struct.
  """
  def task_queue(name) when is_binary(name) do
    %Temporal.Api.Taskqueue.V1.TaskQueue{name: name}
  end

  @doc """
  Builds a `Temporal.Api.Common.V1.WorkflowExecution` struct.
  """
  def workflow_execution(workflow_id, run_id \\ nil) do
    %Temporal.Api.Common.V1.WorkflowExecution{
      workflow_id: workflow_id,
      run_id: run_id || ""
    }
  end

  @doc """
  Converts a duration in seconds (integer or float) to a `Google.Protobuf.Duration`.
  Accepts nil, returning nil.
  """
  def to_duration(nil), do: nil

  def to_duration(seconds) when is_integer(seconds) do
    %Google.Protobuf.Duration{seconds: seconds, nanos: 0}
  end

  def to_duration(seconds) when is_float(seconds) do
    whole = trunc(seconds)
    nanos = round((seconds - whole) * 1_000_000_000)
    %Google.Protobuf.Duration{seconds: whole, nanos: nanos}
  end

  @doc """
  Converts a `Google.Protobuf.Duration` to seconds as a float.
  Returns nil for nil input.
  """
  def from_duration(nil), do: nil

  def from_duration(%Google.Protobuf.Duration{seconds: seconds, nanos: nanos}) do
    seconds + nanos / 1_000_000_000
  end

  @doc """
  Converts a `Google.Protobuf.Timestamp` to a DateTime.
  Returns nil for nil input.
  """
  def from_timestamp(nil), do: nil

  def from_timestamp(%Google.Protobuf.Timestamp{seconds: seconds, nanos: nanos}) do
    {:ok, dt} = DateTime.from_unix(seconds, :second)

    if nanos > 0 do
      microseconds = div(nanos, 1_000)
      %{dt | microsecond: {microseconds, 6}}
    else
      dt
    end
  end

  @doc """
  Converts a DateTime to a `Google.Protobuf.Timestamp`.
  Returns nil for nil input.
  """
  def to_timestamp(nil), do: nil

  def to_timestamp(%DateTime{} = dt) do
    seconds = DateTime.to_unix(dt, :second)
    {micros, _precision} = dt.microsecond
    nanos = micros * 1_000

    %Google.Protobuf.Timestamp{seconds: seconds, nanos: nanos}
  end

  @doc """
  Builds a `Temporal.Api.Common.V1.RetryPolicy` from a keyword list or map.

  Supported keys: `:initial_interval`, `:backoff_coefficient`,
  `:maximum_interval`, `:maximum_attempts`, `:non_retryable_error_types`.
  """
  def to_retry_policy(nil), do: nil

  def to_retry_policy(opts) when is_list(opts) do
    to_retry_policy(Map.new(opts))
  end

  def to_retry_policy(opts) when is_map(opts) do
    %Temporal.Api.Common.V1.RetryPolicy{
      initial_interval: to_duration(Map.get(opts, :initial_interval)),
      backoff_coefficient: Map.get(opts, :backoff_coefficient, 0.0),
      maximum_interval: to_duration(Map.get(opts, :maximum_interval)),
      maximum_attempts: Map.get(opts, :maximum_attempts, 0),
      non_retryable_error_types: Map.get(opts, :non_retryable_error_types, [])
    }
  end

  @doc """
  Builds a `Temporal.Api.Common.V1.Memo` from a map, encoding values
  using the given data converter.
  """
  def to_memo(nil, _converter), do: nil
  def to_memo(map, _converter) when map == %{}, do: nil

  def to_memo(map, converter) when is_map(map) do
    fields =
      Map.new(map, fn {key, value} ->
        {to_string(key), TemporalEx.Converter.Payload.encode_single(value, converter)}
      end)

    %Temporal.Api.Common.V1.Memo{fields: fields}
  end

  @doc """
  Builds a `Temporal.Api.Common.V1.SearchAttributes` from a map,
  encoding values using the given data converter.
  """
  def to_search_attributes(nil, _converter), do: nil
  def to_search_attributes(map, _converter) when map == %{}, do: nil

  def to_search_attributes(map, converter) when is_map(map) do
    indexed_fields =
      Map.new(map, fn {key, value} ->
        {to_string(key), TemporalEx.Converter.Payload.encode_single(value, converter)}
      end)

    %Temporal.Api.Common.V1.SearchAttributes{indexed_fields: indexed_fields}
  end
end
