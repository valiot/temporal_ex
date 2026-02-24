defmodule TemporalEx.Converter.CommonTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Converter.Common

  describe "workflow_type/1" do
    test "builds a WorkflowType struct" do
      result = Common.workflow_type("MyWorkflow")
      assert %Temporal.Api.Common.V1.WorkflowType{name: "MyWorkflow"} = result
    end
  end

  describe "task_queue/1" do
    test "builds a TaskQueue struct" do
      result = Common.task_queue("my-queue")
      assert %Temporal.Api.Taskqueue.V1.TaskQueue{name: "my-queue"} = result
    end
  end

  describe "workflow_execution/2" do
    test "builds with workflow_id and run_id" do
      result = Common.workflow_execution("wf-123", "run-456")

      assert %Temporal.Api.Common.V1.WorkflowExecution{
               workflow_id: "wf-123",
               run_id: "run-456"
             } = result
    end

    test "defaults run_id to empty string" do
      result = Common.workflow_execution("wf-123")
      assert result.run_id == ""
    end

    test "converts nil run_id to empty string" do
      result = Common.workflow_execution("wf-123", nil)
      assert result.run_id == ""
    end
  end

  describe "to_duration/1" do
    test "returns nil for nil" do
      assert Common.to_duration(nil) == nil
    end

    test "converts integer seconds" do
      result = Common.to_duration(60)
      assert %Google.Protobuf.Duration{seconds: 60, nanos: 0} = result
    end

    test "converts float seconds" do
      result = Common.to_duration(1.5)
      assert %Google.Protobuf.Duration{seconds: 1, nanos: 500_000_000} = result
    end
  end

  describe "from_duration/1" do
    test "returns nil for nil" do
      assert Common.from_duration(nil) == nil
    end

    test "converts duration with no nanos" do
      duration = %Google.Protobuf.Duration{seconds: 60, nanos: 0}
      assert Common.from_duration(duration) == 60.0
    end

    test "converts duration with nanos" do
      duration = %Google.Protobuf.Duration{seconds: 1, nanos: 500_000_000}
      assert Common.from_duration(duration) == 1.5
    end
  end

  describe "from_timestamp/1" do
    test "returns nil for nil" do
      assert Common.from_timestamp(nil) == nil
    end

    test "converts a timestamp to DateTime" do
      # 2024-01-01 00:00:00 UTC
      ts = %Google.Protobuf.Timestamp{seconds: 1_704_067_200, nanos: 0}
      result = Common.from_timestamp(ts)
      assert %DateTime{year: 2024, month: 1, day: 1} = result
    end

    test "preserves nanosecond precision as microseconds" do
      ts = %Google.Protobuf.Timestamp{seconds: 1_704_067_200, nanos: 123_456_000}
      result = Common.from_timestamp(ts)
      assert {123_456, 6} = result.microsecond
    end
  end

  describe "to_timestamp/1" do
    test "returns nil for nil" do
      assert Common.to_timestamp(nil) == nil
    end

    test "converts a DateTime to Timestamp" do
      {:ok, dt} = DateTime.from_unix(1_704_067_200, :second)
      result = Common.to_timestamp(dt)
      assert %Google.Protobuf.Timestamp{seconds: 1_704_067_200, nanos: 0} = result
    end
  end

  describe "to_retry_policy/1" do
    test "returns nil for nil" do
      assert Common.to_retry_policy(nil) == nil
    end

    test "converts keyword list to RetryPolicy" do
      result =
        Common.to_retry_policy(
          initial_interval: 1,
          backoff_coefficient: 2.0,
          maximum_interval: 100,
          maximum_attempts: 3,
          non_retryable_error_types: ["FatalError"]
        )

      assert %Temporal.Api.Common.V1.RetryPolicy{} = result
      assert result.maximum_attempts == 3
      assert result.backoff_coefficient == 2.0
      assert result.non_retryable_error_types == ["FatalError"]
      assert %Google.Protobuf.Duration{seconds: 1} = result.initial_interval
      assert %Google.Protobuf.Duration{seconds: 100} = result.maximum_interval
    end

    test "converts map to RetryPolicy" do
      result = Common.to_retry_policy(%{maximum_attempts: 5})
      assert result.maximum_attempts == 5
    end
  end
end
