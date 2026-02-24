defmodule TemporalEx.Error do
  @moduledoc """
  Structured error types for Temporal RPC failures.

  Parses gRPC error responses into specific error structs so callers
  can pattern-match on the failure type.
  """

  @type t ::
          %__MODULE__.WorkflowAlreadyStarted{}
          | %__MODULE__.WorkflowNotFound{}
          | %__MODULE__.NamespaceNotFound{}
          | %__MODULE__.QueryFailed{}
          | %__MODULE__.RPCError{}

  defmodule WorkflowAlreadyStarted do
    @moduledoc "Raised when starting a workflow whose ID is already running."
    defstruct [:workflow_id, :run_id, :message]
    @type t :: %__MODULE__{workflow_id: String.t() | nil, run_id: String.t() | nil, message: String.t()}
  end

  defmodule WorkflowNotFound do
    @moduledoc "Raised when the referenced workflow execution does not exist."
    defstruct [:workflow_id, :run_id, :message]
    @type t :: %__MODULE__{workflow_id: String.t() | nil, run_id: String.t() | nil, message: String.t()}
  end

  defmodule NamespaceNotFound do
    @moduledoc "Raised when the referenced namespace does not exist."
    defstruct [:namespace, :message]
    @type t :: %__MODULE__{namespace: String.t() | nil, message: String.t()}
  end

  defmodule QueryFailed do
    @moduledoc "Raised when a workflow query fails."
    defstruct [:message]
    @type t :: %__MODULE__{message: String.t()}
  end

  defmodule RPCError do
    @moduledoc "Catch-all for unrecognized gRPC errors."
    defstruct [:code, :message, :details]
    @type t :: %__MODULE__{code: atom() | integer(), message: String.t(), details: term()}
  end

  @doc """
  Converts a gRPC error into a typed `TemporalEx.Error` struct.

  Accepts `GRPC.RPCError` structs or `{:error, reason}` tuples.
  """
  @spec from_rpc_error(term()) :: t()
  def from_rpc_error(%{status: status, message: message}) do
    parse_by_status(status, message)
  end

  def from_rpc_error({:error, %{status: status, message: message}}) do
    parse_by_status(status, message)
  end

  def from_rpc_error({:error, reason}) when is_binary(reason) do
    %RPCError{code: :unknown, message: reason, details: nil}
  end

  def from_rpc_error({:error, reason}) do
    %RPCError{code: :unknown, message: inspect(reason), details: reason}
  end

  def from_rpc_error(other) do
    %RPCError{code: :unknown, message: inspect(other), details: other}
  end

  # gRPC status 6 = ALREADY_EXISTS
  defp parse_by_status(6, message) do
    %WorkflowAlreadyStarted{message: message}
  end

  # gRPC status 5 = NOT_FOUND
  defp parse_by_status(5, message) do
    cond do
      message =~ ~r/namespace/i ->
        %NamespaceNotFound{message: message}

      true ->
        %WorkflowNotFound{message: message}
    end
  end

  # gRPC status 9 = FAILED_PRECONDITION (used for query failures)
  defp parse_by_status(9, message) do
    if message =~ ~r/query/i do
      %QueryFailed{message: message}
    else
      %RPCError{code: :failed_precondition, message: message, details: nil}
    end
  end

  # gRPC status 3 = INVALID_ARGUMENT
  defp parse_by_status(3, message) do
    %RPCError{code: :invalid_argument, message: message, details: nil}
  end

  # gRPC status 7 = PERMISSION_DENIED
  defp parse_by_status(7, message) do
    %RPCError{code: :permission_denied, message: message, details: nil}
  end

  # gRPC status 14 = UNAVAILABLE
  defp parse_by_status(14, message) do
    %RPCError{code: :unavailable, message: message, details: nil}
  end

  # gRPC status 4 = DEADLINE_EXCEEDED
  defp parse_by_status(4, message) do
    %RPCError{code: :deadline_exceeded, message: message, details: nil}
  end

  # gRPC status 16 = UNAUTHENTICATED
  defp parse_by_status(16, message) do
    %RPCError{code: :unauthenticated, message: message, details: nil}
  end

  defp parse_by_status(code, message) do
    %RPCError{code: code, message: message, details: nil}
  end
end
