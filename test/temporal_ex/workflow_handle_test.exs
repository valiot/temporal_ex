defmodule TemporalEx.WorkflowHandleTest do
  use ExUnit.Case, async: true

  alias TemporalEx.WorkflowHandle

  describe "struct" do
    test "creates a handle with required fields" do
      handle = %WorkflowHandle{
        client: self(),
        workflow_id: "wf-123"
      }

      assert handle.client == self()
      assert handle.workflow_id == "wf-123"
      assert handle.run_id == nil
      assert handle.namespace == nil
    end

    test "creates a handle with all fields" do
      handle = %WorkflowHandle{
        client: self(),
        workflow_id: "wf-123",
        run_id: "run-456",
        namespace: "my-ns",
        first_execution_run_id: "first-run"
      }

      assert handle.run_id == "run-456"
      assert handle.namespace == "my-ns"
      assert handle.first_execution_run_id == "first-run"
    end

    test "requires client field" do
      assert_raise ArgumentError, fn ->
        struct!(WorkflowHandle, workflow_id: "wf-123")
      end
    end

    test "requires workflow_id field" do
      assert_raise ArgumentError, fn ->
        struct!(WorkflowHandle, client: self())
      end
    end
  end
end
