defmodule TemporalEx.ErrorTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Error

  # ── Helpers ─────────────────────────────────────────────────────────

  defp detail(type_name) do
    %Google.Protobuf.Any{
      type_url: "type.googleapis.com/" <> type_name,
      value: <<>>
    }
  end

  @workflow_already_started "temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure"
  @namespace_not_found "temporal.api.errordetails.v1.NamespaceNotFoundFailure"
  @query_failed "temporal.api.errordetails.v1.QueryFailedFailure"

  # ── Detail-driven classification (most authoritative) ───────────────

  describe "from_rpc_error/2 — error details" do
    test "WorkflowExecutionAlreadyStartedFailure → WorkflowAlreadyStarted" do
      error =
        Error.from_rpc_error(%{
          status: 6,
          message: "already started",
          details: [detail(@workflow_already_started)]
        })

      assert %Error.WorkflowAlreadyStarted{message: "already started"} = error
    end

    test "NamespaceNotFoundFailure → NamespaceNotFound" do
      error =
        Error.from_rpc_error(%{
          status: 5,
          message: "namespace missing",
          details: [detail(@namespace_not_found)]
        })

      assert %Error.NamespaceNotFound{message: "namespace missing"} = error
    end

    test "QueryFailedFailure → QueryFailed" do
      error =
        Error.from_rpc_error(%{
          status: 9,
          message: "query exploded",
          details: [detail(@query_failed)]
        })

      assert %Error.QueryFailed{message: "query exploded"} = error
    end

    test "detail overrides context — WorkflowExecutionAlreadyStartedFailure beats :schedule context" do
      error =
        Error.from_rpc_error(
          %{
            status: 6,
            message: "already started",
            details: [detail(@workflow_already_started)]
          },
          context: :schedule
        )

      assert %Error.WorkflowAlreadyStarted{} = error
    end
  end

  # ── Context-driven disambiguation ───────────────────────────────────

  describe "from_rpc_error/2 — :workflow context" do
    test "ALREADY_EXISTS → WorkflowAlreadyStarted" do
      error = Error.from_rpc_error(%{status: 6, message: "already started"}, context: :workflow)
      assert %Error.WorkflowAlreadyStarted{message: "already started"} = error
    end

    test "NOT_FOUND → WorkflowNotFound" do
      error = Error.from_rpc_error(%{status: 5, message: "not found"}, context: :workflow)
      assert %Error.WorkflowNotFound{message: "not found"} = error
    end

    test "does not misclassify as schedule when workflow id contains 'schedule'" do
      # Regression: previously `message =~ ~r/schedule/i` would misclassify
      # ordinary workflow errors whose ID included the word "schedule".
      error =
        Error.from_rpc_error(
          %{
            status: 6,
            message: "Workflow execution 'daily-schedule-sync' is already running"
          },
          context: :workflow
        )

      assert %Error.WorkflowAlreadyStarted{} = error
    end
  end

  describe "from_rpc_error/2 — :schedule context" do
    test "ALREADY_EXISTS → ScheduleAlreadyExists" do
      error = Error.from_rpc_error(%{status: 6, message: "already exists"}, context: :schedule)
      assert %Error.ScheduleAlreadyExists{message: "already exists"} = error
    end

    test "NOT_FOUND → ScheduleNotFound" do
      error = Error.from_rpc_error(%{status: 5, message: "not found"}, context: :schedule)
      assert %Error.ScheduleNotFound{message: "not found"} = error
    end
  end

  # ── No context, no details — generic fallbacks ──────────────────────

  describe "from_rpc_error/2 — no context, no details" do
    test "ALREADY_EXISTS → generic RPCError (no more guessing from message)" do
      error = Error.from_rpc_error(%{status: 6, message: "already exists"})
      assert %Error.RPCError{code: :already_exists, message: "already exists"} = error
    end

    test "NOT_FOUND → generic RPCError" do
      error = Error.from_rpc_error(%{status: 5, message: "not found"})
      assert %Error.RPCError{code: :not_found, message: "not found"} = error
    end

    test "FAILED_PRECONDITION without query detail → generic RPCError" do
      error = Error.from_rpc_error(%{status: 9, message: "precondition not met"})
      assert %Error.RPCError{code: :failed_precondition, message: "precondition not met"} = error
    end
  end

  # ── Other status codes are context-agnostic ─────────────────────────

  describe "from_rpc_error/2 — mapped status codes" do
    test "INVALID_ARGUMENT (3) → RPCError" do
      error = Error.from_rpc_error(%{status: 3, message: "invalid arg"})
      assert %Error.RPCError{code: :invalid_argument, message: "invalid arg"} = error
    end

    test "PERMISSION_DENIED (7) → RPCError" do
      error = Error.from_rpc_error(%{status: 7, message: "denied"})
      assert %Error.RPCError{code: :permission_denied, message: "denied"} = error
    end

    test "UNAVAILABLE (14) → RPCError" do
      error = Error.from_rpc_error(%{status: 14, message: "server unavailable"})
      assert %Error.RPCError{code: :unavailable, message: "server unavailable"} = error
    end

    test "DEADLINE_EXCEEDED (4) → RPCError" do
      error = Error.from_rpc_error(%{status: 4, message: "deadline exceeded"})
      assert %Error.RPCError{code: :deadline_exceeded, message: "deadline exceeded"} = error
    end

    test "UNAUTHENTICATED (16) → RPCError" do
      error = Error.from_rpc_error(%{status: 16, message: "unauthenticated"})
      assert %Error.RPCError{code: :unauthenticated, message: "unauthenticated"} = error
    end

    test "unknown status code → RPCError with raw code" do
      error = Error.from_rpc_error(%{status: 99, message: "something weird"})
      assert %Error.RPCError{code: 99, message: "something weird"} = error
    end
  end

  # ── Non-RPC-struct error shapes ─────────────────────────────────────

  describe "from_rpc_error/2 — alternative input shapes" do
    test "handles {:error, %{status:, message:}} tuples with context" do
      error =
        Error.from_rpc_error(
          {:error, %{status: 6, message: "already started"}},
          context: :workflow
        )

      assert %Error.WorkflowAlreadyStarted{} = error
    end

    test "handles {:error, binary} tuples" do
      error = Error.from_rpc_error({:error, "connection failed"})
      assert %Error.RPCError{code: :unknown, message: "connection failed"} = error
    end

    test "handles {:error, term} tuples" do
      error = Error.from_rpc_error({:error, :timeout})
      assert %Error.RPCError{code: :unknown, details: :timeout} = error
    end

    test "handles arbitrary terms" do
      error = Error.from_rpc_error(:something_unexpected)
      assert %Error.RPCError{code: :unknown} = error
    end
  end
end
