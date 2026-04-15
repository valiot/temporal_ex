defmodule TemporalEx.Error do
  @moduledoc """
  Structured error types for Temporal RPC failures.

  Parses gRPC error responses into specific error structs so callers
  can pattern-match on the failure type.

  Classification strategy (in order):

  1. **Typed error details** — Temporal emits structured failure messages
     (e.g. `WorkflowExecutionAlreadyStartedFailure`, `NamespaceNotFoundFailure`)
     in the gRPC error's `details` list. When present, they give an
     unambiguous answer.

  2. **Caller-supplied `:context`** — each TemporalEx call site knows whether
     it just invoked a workflow or schedule RPC, so it passes
     `context: :workflow` or `context: :schedule`. This disambiguates status
     codes (`ALREADY_EXISTS`, `NOT_FOUND`) that aren't covered by a typed
     detail.

  3. **Generic `RPCError`** — when neither signal is available, the error
     is returned as a generic `RPCError` rather than guessing based on the
     free-form message text (which can embed user-controlled values).
  """

  @type context :: :workflow | :schedule | nil

  @type t ::
          %__MODULE__.WorkflowAlreadyStarted{}
          | %__MODULE__.WorkflowNotFound{}
          | %__MODULE__.ScheduleAlreadyExists{}
          | %__MODULE__.ScheduleNotFound{}
          | %__MODULE__.NamespaceNotFound{}
          | %__MODULE__.QueryFailed{}
          | %__MODULE__.RPCError{}

  defmodule WorkflowAlreadyStarted do
    @moduledoc "Raised when starting a workflow whose ID is already running."
    defstruct [:workflow_id, :run_id, :message]

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            run_id: String.t() | nil,
            message: String.t()
          }
  end

  defmodule WorkflowNotFound do
    @moduledoc "Raised when the referenced workflow execution does not exist."
    defstruct [:workflow_id, :run_id, :message]

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            run_id: String.t() | nil,
            message: String.t()
          }
  end

  defmodule ScheduleAlreadyExists do
    @moduledoc "Raised when creating a schedule whose ID already exists."
    defstruct [:schedule_id, :message]
    @type t :: %__MODULE__{schedule_id: String.t() | nil, message: String.t()}
  end

  defmodule ScheduleNotFound do
    @moduledoc "Raised when the referenced schedule does not exist."
    defstruct [:schedule_id, :message]
    @type t :: %__MODULE__{schedule_id: String.t() | nil, message: String.t()}
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

  # Temporal error detail type names, matched against `type_url` suffixes.
  @workflow_already_started "temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure"
  @namespace_not_found "temporal.api.errordetails.v1.NamespaceNotFoundFailure"
  @query_failed "temporal.api.errordetails.v1.QueryFailedFailure"

  @doc """
  Converts a gRPC error into a typed `TemporalEx.Error` struct.

  Accepts `GRPC.RPCError` structs or `{:error, reason}` tuples.

  ## Options

    * `:context` — caller operation kind, one of `:workflow`, `:schedule`, or
      `nil` (default). Used to disambiguate `ALREADY_EXISTS` / `NOT_FOUND`
      status codes when the gRPC error carries no typed detail.
  """
  @spec from_rpc_error(term(), keyword()) :: t()
  def from_rpc_error(error, opts \\ [])

  def from_rpc_error(%{status: status, message: message} = err, opts) do
    details = Map.get(err, :details, [])
    context = Keyword.get(opts, :context)
    parse_by_status(status, message, details, context)
  end

  def from_rpc_error({:error, %{} = err}, opts) do
    from_rpc_error(err, opts)
  end

  def from_rpc_error({:error, reason}, _opts) when is_binary(reason) do
    %RPCError{code: :unknown, message: reason, details: nil}
  end

  def from_rpc_error({:error, reason}, _opts) do
    %RPCError{code: :unknown, message: inspect(reason), details: reason}
  end

  def from_rpc_error(other, _opts) do
    %RPCError{code: :unknown, message: inspect(other), details: other}
  end

  # gRPC status 6 = ALREADY_EXISTS
  defp parse_by_status(6, message, details, context) do
    cond do
      has_detail?(details, @workflow_already_started) ->
        %WorkflowAlreadyStarted{message: message}

      context == :workflow ->
        %WorkflowAlreadyStarted{message: message}

      context == :schedule ->
        %ScheduleAlreadyExists{message: message}

      true ->
        %RPCError{code: :already_exists, message: message, details: details_or_nil(details)}
    end
  end

  # gRPC status 5 = NOT_FOUND
  defp parse_by_status(5, message, details, context) do
    cond do
      has_detail?(details, @namespace_not_found) ->
        %NamespaceNotFound{message: message}

      # Guarded fallback for cases where the `grpc-status-details-bin` trailer
      # is absent on the client — typically caused by gRPC intermediaries
      # (Envoy/nginx terminations that re-serialize without preserving
      # trailers, gRPC-Web bridges, gRPC-to-JSON gateways, mesh sidecars with
      # custom filters) or by a decode failure higher up the stack. Every
      # workflow/schedule RPC carries a namespace, so a missing namespace
      # surfaces as NOT_FOUND on any call; when the message explicitly
      # mentions it, prefer NamespaceNotFound over the caller's operation
      # context. Word-boundary-matched to avoid collisions with arbitrary
      # substrings.
      message =~ ~r/\bnamespace\b/i ->
        %NamespaceNotFound{message: message}

      context == :workflow ->
        %WorkflowNotFound{message: message}

      context == :schedule ->
        %ScheduleNotFound{message: message}

      true ->
        %RPCError{code: :not_found, message: message, details: details_or_nil(details)}
    end
  end

  # gRPC status 9 = FAILED_PRECONDITION (used for query failures)
  defp parse_by_status(9, message, details, _context) do
    if has_detail?(details, @query_failed) do
      %QueryFailed{message: message}
    else
      %RPCError{code: :failed_precondition, message: message, details: details_or_nil(details)}
    end
  end

  # gRPC status 3 = INVALID_ARGUMENT
  defp parse_by_status(3, message, _details, _context) do
    %RPCError{code: :invalid_argument, message: message, details: nil}
  end

  # gRPC status 7 = PERMISSION_DENIED
  defp parse_by_status(7, message, _details, _context) do
    %RPCError{code: :permission_denied, message: message, details: nil}
  end

  # gRPC status 14 = UNAVAILABLE
  defp parse_by_status(14, message, _details, _context) do
    %RPCError{code: :unavailable, message: message, details: nil}
  end

  # gRPC status 4 = DEADLINE_EXCEEDED
  defp parse_by_status(4, message, _details, _context) do
    %RPCError{code: :deadline_exceeded, message: message, details: nil}
  end

  # gRPC status 16 = UNAUTHENTICATED
  defp parse_by_status(16, message, _details, _context) do
    %RPCError{code: :unauthenticated, message: message, details: nil}
  end

  defp parse_by_status(code, message, _details, _context) do
    %RPCError{code: code, message: message, details: nil}
  end

  # True when `details` contains a `Google.Protobuf.Any` whose `type_url`
  # matches the Temporal error detail type name (e.g.
  # "temporal.api.errordetails.v1.NamespaceNotFoundFailure").
  defp has_detail?(details, type_name) when is_list(details) do
    Enum.any?(details, &match_type?(&1, type_name))
  end

  defp has_detail?(_, _), do: false

  defp match_type?(%{type_url: type_url}, type_name) when is_binary(type_url) do
    String.ends_with?(type_url, "/" <> type_name) or type_url == type_name
  end

  defp match_type?(_, _), do: false

  defp details_or_nil([]), do: nil
  defp details_or_nil(details) when is_list(details), do: details
  defp details_or_nil(_), do: nil
end
