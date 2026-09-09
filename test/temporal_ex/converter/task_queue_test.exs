defmodule TemporalEx.Converter.TaskQueueTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Converter.TaskQueue

  describe "to_describe_request/3" do
    test "defaults: workflow type, stats on, NORMAL kind" do
      request = TaskQueue.to_describe_request("my-ns", "my-queue")

      assert %Temporal.Api.Workflowservice.V1.DescribeTaskQueueRequest{} = request
      assert request.namespace == "my-ns"
      assert request.task_queue.name == "my-queue"
      assert request.task_queue.kind == :TASK_QUEUE_KIND_NORMAL
      assert request.task_queue_type == :TASK_QUEUE_TYPE_WORKFLOW
      assert request.report_stats == true
    end

    test "activity type targets the CPU/activity poller set" do
      request = TaskQueue.to_describe_request("ns", "q", type: :activity)
      assert request.task_queue_type == :TASK_QUEUE_TYPE_ACTIVITY
    end

    test "stats can be turned off" do
      request = TaskQueue.to_describe_request("ns", "q", report_stats: false)
      assert request.report_stats == false
    end

    test "an unknown type raises instead of silently describing the wrong pollers" do
      assert_raise ArgumentError, ~r/invalid task queue type :cpu/, fn ->
        TaskQueue.to_describe_request("ns", "q", type: :cpu)
      end
    end
  end

  describe "from_describe_response/1" do
    test "decodes pollers with DateTime last access and stats with ms backlog age" do
      response = %Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse{
        pollers: [
          %Temporal.Api.Taskqueue.V1.PollerInfo{
            identity: "laptop:abc123:v2.6.0",
            last_access_time: %Google.Protobuf.Timestamp{seconds: 1_788_902_857, nanos: 0},
            rate_per_second: 100_000.0
          }
        ],
        stats: %Temporal.Api.Taskqueue.V1.TaskQueueStats{
          approximate_backlog_count: 42,
          approximate_backlog_age: %Google.Protobuf.Duration{seconds: 3, nanos: 500_000_000},
          tasks_add_rate: 1.5,
          tasks_dispatch_rate: 1.25
        }
      }

      assert %{pollers: [poller], stats: stats} = TaskQueue.from_describe_response(response)

      assert poller.identity == "laptop:abc123:v2.6.0"
      assert poller.last_access_time == ~U[2026-09-08 21:27:37Z]
      assert poller.rate_per_second == 100_000.0

      assert stats.backlog_count == 42
      assert stats.backlog_age_ms == 3_500
      assert stats.tasks_add_rate == 1.5
      assert stats.tasks_dispatch_rate == 1.25
    end

    test "no pollers and no stats — the 'nothing is listening' answer" do
      response = %Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse{
        pollers: [],
        stats: nil
      }

      assert %{pollers: [], stats: nil} = TaskQueue.from_describe_response(response)
    end

    test "stats with an unreported backlog age keep it nil, not 0" do
      response = %Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse{
        pollers: [],
        stats: %Temporal.Api.Taskqueue.V1.TaskQueueStats{
          approximate_backlog_count: 0,
          approximate_backlog_age: nil,
          tasks_add_rate: 0.0,
          tasks_dispatch_rate: 0.0
        }
      }

      assert %{stats: %{backlog_age_ms: nil, backlog_count: 0}} =
               TaskQueue.from_describe_response(response)
    end

    test "a poller without last_access_time decodes to nil, not a crash" do
      response = %Temporal.Api.Workflowservice.V1.DescribeTaskQueueResponse{
        pollers: [
          %Temporal.Api.Taskqueue.V1.PollerInfo{
            identity: "pod-1",
            last_access_time: nil,
            rate_per_second: 0.0
          }
        ]
      }

      assert %{pollers: [%{last_access_time: nil}]} = TaskQueue.from_describe_response(response)
    end
  end
end
