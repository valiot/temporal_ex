defmodule TemporalEx.ErrorTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Error

  describe "from_rpc_error/1" do
    test "maps ALREADY_EXISTS (6) to WorkflowAlreadyStarted" do
      error = Error.from_rpc_error(%{status: 6, message: "Workflow already started"})
      assert %Error.WorkflowAlreadyStarted{message: "Workflow already started"} = error
    end

    test "maps NOT_FOUND (5) with 'namespace' to NamespaceNotFound" do
      error = Error.from_rpc_error(%{status: 5, message: "Namespace not found: test-ns"})
      assert %Error.NamespaceNotFound{message: "Namespace not found: test-ns"} = error
    end

    test "maps NOT_FOUND (5) without 'namespace' to WorkflowNotFound" do
      error = Error.from_rpc_error(%{status: 5, message: "Workflow execution not found"})
      assert %Error.WorkflowNotFound{message: "Workflow execution not found"} = error
    end

    test "maps FAILED_PRECONDITION (9) with 'query' to QueryFailed" do
      error = Error.from_rpc_error(%{status: 9, message: "query failed: no handler"})
      assert %Error.QueryFailed{message: "query failed: no handler"} = error
    end

    test "maps FAILED_PRECONDITION (9) without 'query' to RPCError" do
      error = Error.from_rpc_error(%{status: 9, message: "precondition not met"})
      assert %Error.RPCError{code: :failed_precondition, message: "precondition not met"} = error
    end

    test "maps INVALID_ARGUMENT (3) to RPCError" do
      error = Error.from_rpc_error(%{status: 3, message: "invalid arg"})
      assert %Error.RPCError{code: :invalid_argument, message: "invalid arg"} = error
    end

    test "maps PERMISSION_DENIED (7) to RPCError" do
      error = Error.from_rpc_error(%{status: 7, message: "denied"})
      assert %Error.RPCError{code: :permission_denied, message: "denied"} = error
    end

    test "maps UNAVAILABLE (14) to RPCError" do
      error = Error.from_rpc_error(%{status: 14, message: "server unavailable"})
      assert %Error.RPCError{code: :unavailable, message: "server unavailable"} = error
    end

    test "maps DEADLINE_EXCEEDED (4) to RPCError" do
      error = Error.from_rpc_error(%{status: 4, message: "deadline exceeded"})
      assert %Error.RPCError{code: :deadline_exceeded, message: "deadline exceeded"} = error
    end

    test "maps UNAUTHENTICATED (16) to RPCError" do
      error = Error.from_rpc_error(%{status: 16, message: "unauthenticated"})
      assert %Error.RPCError{code: :unauthenticated, message: "unauthenticated"} = error
    end

    test "maps unknown status code to RPCError" do
      error = Error.from_rpc_error(%{status: 99, message: "something weird"})
      assert %Error.RPCError{code: 99, message: "something weird"} = error
    end

    test "handles {:error, %{status:, message:}} tuples" do
      error = Error.from_rpc_error({:error, %{status: 6, message: "already exists"}})
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
