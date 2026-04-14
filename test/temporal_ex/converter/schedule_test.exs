defmodule TemporalEx.Converter.ScheduleTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Converter.Schedule
  alias TemporalEx.DataConverter.Json, as: JsonConverter

  @converter JsonConverter

  # ── to_schedule/2 ──────────────────────────────────────────────────

  describe "to_schedule/2" do
    test "builds a Schedule with all sub-structs" do
      result =
        Schedule.to_schedule(
          [
            spec: [intervals: [[every: 60]]],
            action: [
              workflow_type: "MyWorkflow",
              workflow_id: "wf-1",
              task_queue: "my-queue"
            ],
            policies: [overlap_policy: :skip],
            state: [paused: true, notes: "initial"]
          ],
          @converter
        )

      assert %Temporal.Api.Schedule.V1.Schedule{} = result
      assert result.spec != nil
      assert result.action != nil
      assert result.policies != nil
      assert result.state != nil
    end

    test "nil sub-options produce nil fields" do
      result =
        Schedule.to_schedule([spec: nil, action: nil, policies: nil, state: nil], @converter)

      assert result.spec == nil
      assert result.action == nil
      assert result.policies == nil
      assert result.state == nil
    end
  end

  # ── to_schedule_spec/1 ─────────────────────────────────────────────

  describe "to_schedule_spec/1" do
    test "returns nil for nil" do
      assert Schedule.to_schedule_spec(nil) == nil
    end

    test "builds intervals" do
      result = Schedule.to_schedule_spec(intervals: [[every: 60], [every: 120, offset: 10]])
      assert length(result.interval) == 2
    end

    test "builds calendars" do
      result = Schedule.to_schedule_spec(calendars: [[hour: "8", minute: "30"]])
      assert [%Temporal.Api.Schedule.V1.CalendarSpec{hour: "8", minute: "30"}] = result.calendar
    end

    test "passes cron expressions" do
      result = Schedule.to_schedule_spec(cron_expressions: ["0 */5 * * *"])
      assert result.cron_string == ["0 */5 * * *"]
    end

    test "sets timezone" do
      result = Schedule.to_schedule_spec(timezone: "America/Chicago")
      assert result.timezone_name == "America/Chicago"
    end

    test "sets jitter as duration" do
      result = Schedule.to_schedule_spec(jitter: 30)
      assert %Google.Protobuf.Duration{seconds: 30} = result.jitter
    end

    test "sets start_time and end_time as timestamps" do
      {:ok, start_time} = DateTime.from_unix(1_700_000_000)
      {:ok, end_time} = DateTime.from_unix(1_700_100_000)
      result = Schedule.to_schedule_spec(start_time: start_time, end_time: end_time)
      assert %Google.Protobuf.Timestamp{seconds: 1_700_000_000} = result.start_time
      assert %Google.Protobuf.Timestamp{seconds: 1_700_100_000} = result.end_time
    end

    test "defaults to empty lists and blank strings" do
      result = Schedule.to_schedule_spec([])
      assert result.interval == []
      assert result.calendar == []
      assert result.cron_string == []
      assert result.timezone_name == ""
    end
  end

  # ── to_interval_spec/1 ─────────────────────────────────────────────

  describe "to_interval_spec/1" do
    test "builds from keyword list with every" do
      result = Schedule.to_interval_spec(every: 60)
      assert %Google.Protobuf.Duration{seconds: 60} = result.interval
      assert result.phase == nil
    end

    test "builds from keyword list with every and offset" do
      result = Schedule.to_interval_spec(every: 60, offset: 10)
      assert %Google.Protobuf.Duration{seconds: 60} = result.interval
      assert %Google.Protobuf.Duration{seconds: 10} = result.phase
    end

    test "builds from bare number" do
      result = Schedule.to_interval_spec(300)
      assert %Google.Protobuf.Duration{seconds: 300} = result.interval
      assert result.phase == nil
    end
  end

  # ── to_calendar_spec/1 ─────────────────────────────────────────────

  describe "to_calendar_spec/1" do
    test "builds with provided fields" do
      result = Schedule.to_calendar_spec(hour: "8", minute: "0", day_of_week: "MON")
      assert result.hour == "8"
      assert result.minute == "0"
      assert result.day_of_week == "MON"
    end

    test "defaults all fields to empty strings" do
      result = Schedule.to_calendar_spec([])
      assert result.second == ""
      assert result.minute == ""
      assert result.hour == ""
      assert result.day_of_month == ""
      assert result.month == ""
      assert result.year == ""
      assert result.day_of_week == ""
      assert result.comment == ""
    end
  end

  # ── to_schedule_action/2 ───────────────────────────────────────────

  describe "to_schedule_action/2" do
    test "returns nil for nil" do
      assert Schedule.to_schedule_action(nil, @converter) == nil
    end

    test "builds a start_workflow action" do
      result =
        Schedule.to_schedule_action(
          [
            workflow_type: "MyWorkflow",
            workflow_id: "wf-1",
            task_queue: "my-queue",
            args: [%{key: "value"}]
          ],
          @converter
        )

      assert {:start_workflow, info} = result.action
      assert %Temporal.Api.Workflow.V1.NewWorkflowExecutionInfo{} = info
      assert info.workflow_id == "wf-1"
      assert info.workflow_type.name == "MyWorkflow"
      assert info.task_queue.name == "my-queue"
      assert info.input != nil
    end

    test "sets nil input when args is empty" do
      result =
        Schedule.to_schedule_action(
          [workflow_type: "W", workflow_id: "wf-1", task_queue: "q"],
          @converter
        )

      assert {:start_workflow, info} = result.action
      assert info.input == nil
    end

    test "sets timeout durations" do
      result =
        Schedule.to_schedule_action(
          [
            workflow_type: "W",
            workflow_id: "wf-1",
            task_queue: "q",
            execution_timeout: 300,
            run_timeout: 60,
            task_timeout: 10
          ],
          @converter
        )

      {:start_workflow, info} = result.action
      assert %Google.Protobuf.Duration{seconds: 300} = info.workflow_execution_timeout
      assert %Google.Protobuf.Duration{seconds: 60} = info.workflow_run_timeout
      assert %Google.Protobuf.Duration{seconds: 10} = info.workflow_task_timeout
    end
  end

  # ── to_schedule_policies/1 ─────────────────────────────────────────

  describe "to_schedule_policies/1" do
    test "returns nil for nil" do
      assert Schedule.to_schedule_policies(nil) == nil
    end

    test "builds with all fields" do
      result =
        Schedule.to_schedule_policies(
          overlap_policy: :buffer_one,
          catchup_window: 600,
          pause_on_failure: true
        )

      assert result.overlap_policy == :SCHEDULE_OVERLAP_POLICY_BUFFER_ONE
      assert %Google.Protobuf.Duration{seconds: 600} = result.catchup_window
      assert result.pause_on_failure == true
    end

    test "defaults pause_on_failure to false" do
      result = Schedule.to_schedule_policies([])
      assert result.pause_on_failure == false
    end
  end

  # ── to_schedule_state/1 ────────────────────────────────────────────

  describe "to_schedule_state/1" do
    test "returns nil for nil" do
      assert Schedule.to_schedule_state(nil) == nil
    end

    test "builds with all fields" do
      result =
        Schedule.to_schedule_state(
          paused: true,
          notes: "maintenance window",
          limited_actions: true,
          remaining_actions: 5
        )

      assert result.paused == true
      assert result.notes == "maintenance window"
      assert result.limited_actions == true
      assert result.remaining_actions == 5
    end

    test "defaults to unpaused with zero remaining actions" do
      result = Schedule.to_schedule_state([])
      assert result.paused == false
      assert result.notes == ""
      assert result.limited_actions == false
      assert result.remaining_actions == 0
    end
  end

  # ── to_schedule_patch/1 ────────────────────────────────────────────

  describe "to_schedule_patch/1" do
    test "builds a pause patch" do
      result = Schedule.to_schedule_patch(pause: "maintenance")
      assert result.pause == "maintenance"
      assert result.unpause == ""
    end

    test "builds an unpause patch" do
      result = Schedule.to_schedule_patch(unpause: "back online")
      assert result.unpause == "back online"
      assert result.pause == ""
    end

    test "builds a trigger_immediately patch (boolean)" do
      result = Schedule.to_schedule_patch(trigger_immediately: true)
      assert %Temporal.Api.Schedule.V1.TriggerImmediatelyRequest{} = result.trigger_immediately
    end

    test "builds a trigger_immediately patch with overlap_policy" do
      result = Schedule.to_schedule_patch(trigger_immediately: [overlap_policy: :allow_all])
      assert result.trigger_immediately.overlap_policy == :SCHEDULE_OVERLAP_POLICY_ALLOW_ALL
    end

    test "builds backfill requests" do
      {:ok, t1} = DateTime.from_unix(1_700_000_000)
      {:ok, t2} = DateTime.from_unix(1_700_100_000)

      result =
        Schedule.to_schedule_patch(
          backfill: [[start_time: t1, end_time: t2, overlap_policy: :skip]]
        )

      assert [backfill] = result.backfill_request
      assert %Google.Protobuf.Timestamp{seconds: 1_700_000_000} = backfill.start_time
      assert %Google.Protobuf.Timestamp{seconds: 1_700_100_000} = backfill.end_time
      assert backfill.overlap_policy == :SCHEDULE_OVERLAP_POLICY_SKIP
    end

    test "defaults to empty strings and empty lists" do
      result = Schedule.to_schedule_patch([])
      assert result.pause == ""
      assert result.unpause == ""
      assert result.trigger_immediately == nil
      assert result.backfill_request == []
    end
  end

  # ── to_overlap_policy/1 ────────────────────────────────────────────

  describe "to_overlap_policy/1" do
    test "maps nil to UNSPECIFIED" do
      assert Schedule.to_overlap_policy(nil) == :SCHEDULE_OVERLAP_POLICY_UNSPECIFIED
    end

    test "maps all friendly atoms" do
      assert Schedule.to_overlap_policy(:skip) == :SCHEDULE_OVERLAP_POLICY_SKIP
      assert Schedule.to_overlap_policy(:buffer_one) == :SCHEDULE_OVERLAP_POLICY_BUFFER_ONE
      assert Schedule.to_overlap_policy(:buffer_all) == :SCHEDULE_OVERLAP_POLICY_BUFFER_ALL
      assert Schedule.to_overlap_policy(:cancel_other) == :SCHEDULE_OVERLAP_POLICY_CANCEL_OTHER

      assert Schedule.to_overlap_policy(:terminate_other) ==
               :SCHEDULE_OVERLAP_POLICY_TERMINATE_OTHER

      assert Schedule.to_overlap_policy(:allow_all) == :SCHEDULE_OVERLAP_POLICY_ALLOW_ALL
    end

    test "passes through raw protobuf enum atoms" do
      assert Schedule.to_overlap_policy(:SCHEDULE_OVERLAP_POLICY_SKIP) ==
               :SCHEDULE_OVERLAP_POLICY_SKIP
    end
  end
end
