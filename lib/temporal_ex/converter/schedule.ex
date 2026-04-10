defmodule TemporalEx.Converter.Schedule do
  @moduledoc """
  Helpers for building Temporal Schedule protobuf types from plain Elixir values.
  """

  alias TemporalEx.Converter.{Common, Payload}

  @doc """
  Builds a `Temporal.Api.Schedule.V1.Schedule` from keyword options.

  ## Options

    * `:spec` — Schedule spec (keyword list, see `to_schedule_spec/1`)
    * `:action` — Schedule action (keyword list, see `to_schedule_action/2`)
    * `:policies` — Schedule policies (keyword list, see `to_schedule_policies/1`)
    * `:state` — Schedule state (keyword list, see `to_schedule_state/1`)
  """
  def to_schedule(opts, converter) when is_list(opts) do
    %Temporal.Api.Schedule.V1.Schedule{
      spec: to_schedule_spec(Keyword.get(opts, :spec)),
      action: to_schedule_action(Keyword.get(opts, :action), converter),
      policies: to_schedule_policies(Keyword.get(opts, :policies)),
      state: to_schedule_state(Keyword.get(opts, :state))
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.ScheduleSpec` from keyword options.

  ## Options

    * `:intervals` — List of interval specs `[every: seconds]` or `[every: seconds, offset: seconds]`
    * `:calendars` — List of calendar spec keyword lists
    * `:cron_expressions` — List of cron expression strings
    * `:start_time` — `DateTime` when the schedule becomes active
    * `:end_time` — `DateTime` when the schedule stops
    * `:jitter` — Max random jitter in seconds
    * `:timezone` — Timezone name string (e.g., `"America/Chicago"`)
  """
  def to_schedule_spec(nil), do: nil

  def to_schedule_spec(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.ScheduleSpec{
      interval: Keyword.get(opts, :intervals, []) |> Enum.map(&to_interval_spec/1),
      calendar: Keyword.get(opts, :calendars, []) |> Enum.map(&to_calendar_spec/1),
      cron_string: Keyword.get(opts, :cron_expressions, []),
      start_time: Common.to_timestamp(Keyword.get(opts, :start_time)),
      end_time: Common.to_timestamp(Keyword.get(opts, :end_time)),
      jitter: Common.to_duration(Keyword.get(opts, :jitter)),
      timezone_name: Keyword.get(opts, :timezone, "")
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.IntervalSpec`.

  Accepts a keyword list with `:every` (required, seconds) and `:offset` (optional, seconds).
  """
  def to_interval_spec(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.IntervalSpec{
      interval: Common.to_duration(Keyword.fetch!(opts, :every)),
      phase: Common.to_duration(Keyword.get(opts, :offset))
    }
  end

  def to_interval_spec(seconds) when is_number(seconds) do
    %Temporal.Api.Schedule.V1.IntervalSpec{
      interval: Common.to_duration(seconds),
      phase: nil
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.CalendarSpec` from keyword options.

  ## Options

  All fields are cron-like strings (e.g., `"0"`, `"*/5"`, `"1,15"`):

    * `:second`, `:minute`, `:hour`
    * `:day_of_month`, `:month`, `:year`
    * `:day_of_week`
    * `:comment`
  """
  def to_calendar_spec(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.CalendarSpec{
      second: Keyword.get(opts, :second, ""),
      minute: Keyword.get(opts, :minute, ""),
      hour: Keyword.get(opts, :hour, ""),
      day_of_month: Keyword.get(opts, :day_of_month, ""),
      month: Keyword.get(opts, :month, ""),
      year: Keyword.get(opts, :year, ""),
      day_of_week: Keyword.get(opts, :day_of_week, ""),
      comment: Keyword.get(opts, :comment, "")
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.ScheduleAction` with a start_workflow action.

  ## Options

    * `:workflow_type` — Workflow type name (required)
    * `:task_queue` — Task queue name (required)
    * `:workflow_id` — Workflow ID (required)
    * `:args` — List of workflow arguments
    * `:execution_timeout` — Max total time in seconds
    * `:run_timeout` — Max single run time in seconds
    * `:task_timeout` — Max task processing time in seconds
    * `:retry_policy` — Retry policy keyword list
    * `:memo` — Memo map
    * `:search_attributes` — Search attributes map
  """
  def to_schedule_action(nil, _converter), do: nil

  def to_schedule_action(opts, converter) when is_list(opts) do
    args = Keyword.get(opts, :args, [])

    workflow_info = %Temporal.Api.Workflow.V1.NewWorkflowExecutionInfo{
      workflow_id: Keyword.fetch!(opts, :workflow_id),
      workflow_type: Common.workflow_type(Keyword.fetch!(opts, :workflow_type)),
      task_queue: Common.task_queue(Keyword.fetch!(opts, :task_queue)),
      input: if(args == [], do: nil, else: Payload.encode(args, converter)),
      workflow_execution_timeout: Common.to_duration(Keyword.get(opts, :execution_timeout)),
      workflow_run_timeout: Common.to_duration(Keyword.get(opts, :run_timeout)),
      workflow_task_timeout: Common.to_duration(Keyword.get(opts, :task_timeout)),
      retry_policy: Common.to_retry_policy(Keyword.get(opts, :retry_policy)),
      memo: Common.to_memo(Keyword.get(opts, :memo), converter),
      search_attributes:
        Common.to_search_attributes(Keyword.get(opts, :search_attributes), converter)
    }

    %Temporal.Api.Schedule.V1.ScheduleAction{
      action: {:start_workflow, workflow_info}
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.SchedulePolicies` from keyword options.

  ## Options

    * `:overlap_policy` — Overlap policy atom (e.g., `:skip`, `:buffer_one`, `:cancel_other`, `:terminate_other`, `:allow_all`)
    * `:catchup_window` — Catchup window in seconds
    * `:pause_on_failure` — Boolean
  """
  def to_schedule_policies(nil), do: nil

  def to_schedule_policies(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.SchedulePolicies{
      overlap_policy: to_overlap_policy(Keyword.get(opts, :overlap_policy)),
      catchup_window: Common.to_duration(Keyword.get(opts, :catchup_window)),
      pause_on_failure: Keyword.get(opts, :pause_on_failure, false)
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.ScheduleState` from keyword options.

  ## Options

    * `:paused` — Boolean
    * `:notes` — String
    * `:limited_actions` — Boolean
    * `:remaining_actions` — Integer
  """
  def to_schedule_state(nil), do: nil

  def to_schedule_state(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.ScheduleState{
      paused: Keyword.get(opts, :paused, false),
      notes: Keyword.get(opts, :notes, ""),
      limited_actions: Keyword.get(opts, :limited_actions, false),
      remaining_actions: Keyword.get(opts, :remaining_actions, 0)
    }
  end

  @doc """
  Builds a `Temporal.Api.Schedule.V1.SchedulePatch` from keyword options.

  ## Options

    * `:pause` — String note for pausing
    * `:unpause` — String note for unpausing
    * `:trigger_immediately` — Boolean or keyword list with `:overlap_policy`
    * `:backfill` — List of backfill request keyword lists
  """
  def to_schedule_patch(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.SchedulePatch{
      pause: Keyword.get(opts, :pause, ""),
      unpause: Keyword.get(opts, :unpause, ""),
      trigger_immediately: to_trigger_immediately(Keyword.get(opts, :trigger_immediately)),
      backfill_request: Keyword.get(opts, :backfill, []) |> Enum.map(&to_backfill_request/1)
    }
  end

  defp to_trigger_immediately(nil), do: nil
  defp to_trigger_immediately(true), do: %Temporal.Api.Schedule.V1.TriggerImmediatelyRequest{}

  defp to_trigger_immediately(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.TriggerImmediatelyRequest{
      overlap_policy: to_overlap_policy(Keyword.get(opts, :overlap_policy))
    }
  end

  defp to_backfill_request(opts) when is_list(opts) do
    %Temporal.Api.Schedule.V1.BackfillRequest{
      start_time: Common.to_timestamp(Keyword.fetch!(opts, :start_time)),
      end_time: Common.to_timestamp(Keyword.fetch!(opts, :end_time)),
      overlap_policy: to_overlap_policy(Keyword.get(opts, :overlap_policy))
    }
  end

  @doc """
  Converts a friendly overlap policy atom to the protobuf enum value.
  """
  def to_overlap_policy(nil), do: :SCHEDULE_OVERLAP_POLICY_UNSPECIFIED
  def to_overlap_policy(:skip), do: :SCHEDULE_OVERLAP_POLICY_SKIP
  def to_overlap_policy(:buffer_one), do: :SCHEDULE_OVERLAP_POLICY_BUFFER_ONE
  def to_overlap_policy(:buffer_all), do: :SCHEDULE_OVERLAP_POLICY_BUFFER_ALL
  def to_overlap_policy(:cancel_other), do: :SCHEDULE_OVERLAP_POLICY_CANCEL_OTHER
  def to_overlap_policy(:terminate_other), do: :SCHEDULE_OVERLAP_POLICY_TERMINATE_OTHER
  def to_overlap_policy(:allow_all), do: :SCHEDULE_OVERLAP_POLICY_ALLOW_ALL
  def to_overlap_policy(value) when is_atom(value), do: value
end
