defmodule TemporalEx.Converter.TaskQueue do
  @moduledoc """
  Helpers for building `DescribeTaskQueue` requests and decoding their
  responses into plain Elixir maps, so callers never touch protobuf structs.
  """

  alias TemporalEx.Converter.Common

  @type_enum %{
    workflow: :TASK_QUEUE_TYPE_WORKFLOW,
    activity: :TASK_QUEUE_TYPE_ACTIVITY,
    nexus: :TASK_QUEUE_TYPE_NEXUS
  }

  @doc """
  Builds a `Temporal.Api.Workflowservice.V1.DescribeTaskQueueRequest`.

  ## Options

    * `:type` — which poller set to describe: `:workflow` (default),
      `:activity`, or `:nexus`. A worker has separate pollers per type, so a
      queue is described per type.
    * `:report_stats` — include backlog/rate stats (default `true`).
  """
  @spec to_describe_request(String.t(), String.t(), keyword()) ::
          Temporal.Api.Workflowservice.V1.DescribeTaskQueueRequest.t()
  def to_describe_request(namespace, task_queue_name, opts \\ []) do
    type = Keyword.get(opts, :type, :workflow)

    task_queue_type =
      Map.get(@type_enum, type) ||
        raise ArgumentError,
              "invalid task queue type #{inspect(type)} — expected one of #{inspect(Map.keys(@type_enum))}"

    %Temporal.Api.Workflowservice.V1.DescribeTaskQueueRequest{
      namespace: namespace,
      task_queue: %Temporal.Api.Taskqueue.V1.TaskQueue{
        name: task_queue_name,
        kind: :TASK_QUEUE_KIND_NORMAL
      },
      task_queue_type: task_queue_type,
      report_stats: Keyword.get(opts, :report_stats, true)
    }
  end

  @doc """
  Decodes a `DescribeTaskQueueResponse` into a plain map:

      %{
        pollers: [
          %{identity: "host:guid:v1.2.3", last_access_time: ~U[...], rate_per_second: 99.9}
        ],
        stats: %{
          backlog_count: 0,
          backlog_age_ms: 0,
          tasks_add_rate: 0.0,
          tasks_dispatch_rate: 0.0
        }
      }

  `stats` is `nil` when the request did not ask for them (or the server does
  not report them); `backlog_age_ms` is `nil` when the server reports stats
  without an age, so an unknown age is distinguishable from a real 0ms one.
  Counts and ages are the server's approximations.
  """
  @spec from_describe_response(Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse.t()) ::
          map()
  def from_describe_response(%Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse{} = resp) do
    %{
      pollers: Enum.map(resp.pollers, &from_poller_info/1),
      stats: from_stats(resp.stats)
    }
  end

  defp from_poller_info(%Temporal.Api.Taskqueue.V1.PollerInfo{} = poller) do
    %{
      identity: poller.identity,
      last_access_time: Common.from_timestamp(poller.last_access_time),
      rate_per_second: poller.rate_per_second
    }
  end

  defp from_stats(nil), do: nil

  defp from_stats(%Temporal.Api.Taskqueue.V1.TaskQueueStats{} = stats) do
    backlog_age_ms =
      case Common.from_duration(stats.approximate_backlog_age) do
        # Unreported stays nil — a queue with an unknown age must not read
        # as one with a genuinely empty (0ms) backlog.
        nil -> nil
        seconds -> round(seconds * 1_000)
      end

    %{
      backlog_count: stats.approximate_backlog_count,
      backlog_age_ms: backlog_age_ms,
      tasks_add_rate: stats.tasks_add_rate,
      tasks_dispatch_rate: stats.tasks_dispatch_rate
    }
  end
end
