defmodule TemporalEx.Client do
  @moduledoc """
  GenServer that owns the gRPC channel to a Temporal server and provides
  generic RPC dispatch.

  Adding new RPCs never requires changes to this module — callers simply
  pass the stub function name and a pre-built protobuf request to `rpc/4`.

  ## Concurrency & resilience

  Network I/O runs in the **caller** process, not inside the GenServer.
  The GenServer only checks out / invalidates the shared gun channel so:

    * concurrent RPCs multiplex over one HTTP/2 connection (gun streams)
    * cheap metadata reads (`namespace/1`, `data_converter/1`) never queue
      behind a long `StartWorkflowExecution`
    * when gun dies mid-RPC (`:down: :normal` / `:noproc`), the channel is
      dropped and the **same** `rpc/4` call reconnects and retries once —
      callers typically never see a one-shot transport blip
  """

  use GenServer

  alias TemporalEx.Client.Connection

  @default_server "localhost:7233"
  @default_call_timeout 5_000
  @default_namespace "default"
  # Checkout only holds the GenServer for connect/bookkeeping; keep this
  # bounded so a hung connect can't pin the mailbox forever.
  @checkout_timeout 10_000

  @workflow_service_stub Temporal.Api.Workflowservice.V1.WorkflowService.Stub

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Starts a client process linked to the caller.

  ## Options

    * `:target` — Temporal server address (default: `"localhost:7233"`)
    * `:namespace` — Default namespace (default: `"default"`)
    * `:api_key` — API key or Bearer token for auth
    * `:tls` — TLS/mTLS config map with keys `:client_cert_pem_b64`,
      `:client_key_pem_b64`, `:ca_cert_file`
    * `:identity` — Client identity string
    * `:data_converter` — Module implementing `TemporalEx.DataConverter`
      (default: `TemporalEx.DataConverter.Json`)
    * `:name` — GenServer registration name
    * `:call_timeout` — Default RPC timeout in ms (default: 5000)
    * `:connect_retry` — Number of gRPC connection retries (default: 0)
    * `:adapter_opts` — Extra gRPC adapter options
  """
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends an RPC to the Temporal WorkflowService.

  I/O runs in the calling process. On a transport-level channel death the
  client invalidates the channel, reconnects, and retries the RPC **once**.

  `rpc_name` must be an atom matching a function on the WorkflowService stub
  (e.g., `:start_workflow_execution`).

  `request` is a pre-built protobuf request struct.

  ## Options

    * `:namespace` — Override the default namespace for this call
    * `:timeout` — Override the default call timeout
  """
  @spec rpc(GenServer.server(), atom(), struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def rpc(client, rpc_name, request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    do_rpc(client, rpc_name, request, opts, timeout, _retried? = false)
  end

  @doc "Returns the client's configured namespace."
  @spec namespace(GenServer.server()) :: String.t()
  def namespace(client) do
    GenServer.call(client, :get_namespace)
  end

  @doc "Returns the client's configured data converter module."
  @spec data_converter(GenServer.server()) :: module()
  def data_converter(client) do
    GenServer.call(client, :get_data_converter)
  end

  # ── RPC (caller process) ────────────────────────────────────────────

  defp do_rpc(client, rpc_name, request, opts, timeout, retried?) do
    case GenServer.call(client, {:checkout, opts}, @checkout_timeout) do
      {:ok, channel, call_opts} ->
        result = invoke_rpc(rpc_name, channel, request, put_timeout(call_opts, timeout))

        case transport_dead_error?(result) do
          true ->
            # Drop this channel (no-op if another caller already replaced it),
            # then retry the whole checkout+invoke once.
            _ = GenServer.call(client, {:invalidate, channel}, @checkout_timeout)

            case retried? do
              true -> result
              false -> do_rpc(client, rpc_name, request, opts, timeout, true)
            end

          false ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_timeout(call_opts, timeout) when is_integer(timeout) and timeout > 0 do
    Keyword.put(call_opts, :timeout, timeout)
  end

  defp put_timeout(call_opts, _timeout), do: call_opts

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    server =
      (Keyword.get(opts, :target) || @default_server)
      |> Connection.normalize_server_address()

    namespace = Keyword.get(opts, :namespace, @default_namespace)
    api_key = Keyword.get(opts, :api_key)
    identity = Keyword.get(opts, :identity, "temporal_ex@#{node()}")
    data_converter = Keyword.get(opts, :data_converter, TemporalEx.DataConverter.Json)
    call_timeout = Keyword.get(opts, :call_timeout, @default_call_timeout)

    tls_config = Keyword.get(opts, :tls, %{}) |> normalize_map()

    grpc_config =
      tls_config
      |> Map.merge(%{
        connect_retry: Keyword.get(opts, :connect_retry, 0),
        adapter_opts: Keyword.get(opts, :adapter_opts, [])
      })

    {connect_opts, temp_pem_files} = Connection.grpc_connect_opts(server, grpc_config)

    # Optional test seam: `(server, connect_opts) -> {:ok, channel} | {:error, reason}`.
    # Production always uses GRPC.Stub.connect/2.
    connect_fun = Keyword.get(opts, :connect_fun, &GRPC.Stub.connect/2)

    {:ok,
     %{
       channel: nil,
       server: server,
       namespace: namespace,
       connect_opts: connect_opts,
       connect_fun: connect_fun,
       authorization: Connection.authorization_from_api_key(api_key),
       identity: identity,
       data_converter: data_converter,
       call_timeout: call_timeout,
       temp_pem_files: temp_pem_files
     }}
  end

  @impl true
  def handle_call({:checkout, opts}, _from, state) do
    namespace = Keyword.get(opts, :namespace, state.namespace)

    case ensure_channel(state) do
      {:ok, connected_state} ->
        metadata = Connection.request_metadata(namespace, connected_state.authorization)
        call_opts = if map_size(metadata) > 0, do: [metadata: metadata], else: []
        {:reply, {:ok, connected_state.channel, call_opts}, connected_state}

      {:error, reason, disconnected_state} ->
        {:reply, {:error, reason}, disconnected_state}
    end
  end

  def handle_call({:invalidate, channel}, _from, state) do
    new_state =
      case same_channel?(state.channel, channel) do
        true -> %{state | channel: nil}
        false -> state
      end

    {:reply, :ok, new_state}
  end

  def handle_call(:get_namespace, _from, state) do
    {:reply, state.namespace, state}
  end

  def handle_call(:get_data_converter, _from, state) do
    {:reply, state.data_converter, state}
  end

  @impl true
  def handle_info({:gun_up, _pid, :http2}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_down, _pid, :http2, _reason, _killed_streams}, state) do
    {:noreply, %{state | channel: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    Connection.cleanup_temp_pem_files(Map.get(state, :temp_pem_files, []))
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp ensure_channel(%{channel: channel} = state) when not is_nil(channel) do
    {:ok, state}
  end

  defp ensure_channel(
         %{server: server, connect_opts: connect_opts, connect_fun: connect_fun} = state
       ) do
    case connect_fun.(server, connect_opts) do
      {:ok, channel} ->
        {:ok, %{state | channel: channel}}

      {:error, reason} ->
        {:error, Connection.format_connect_error(reason), %{state | channel: nil}}
    end
  end

  defp invoke_rpc(rpc_name, channel, request, opts) do
    Code.ensure_loaded(@workflow_service_stub)

    if function_exported?(@workflow_service_stub, rpc_name, 3) do
      case apply(@workflow_service_stub, rpc_name, [channel, request, opts]) do
        {:ok, response} -> {:ok, response}
        {:error, _} = error -> error
      end
    else
      {:error, "Unknown Temporal RPC: #{rpc_name}"}
    end
  end

  # Gun adapter maps `{:error, {:down, reason}}` / connection_error to
  # `%GRPC.RPCError{status: unknown, message: ":down: :normal"}` (etc.).
  defp transport_dead_error?({:error, %GRPC.RPCError{message: message}})
       when is_binary(message) do
    transport_dead_message?(message)
  end

  defp transport_dead_error?(_), do: false

  defp transport_dead_message?(message) do
    String.starts_with?(message, ":down:") or
      String.starts_with?(message, ":connection_error:") or
      String.contains?(message, "connection_error")
  end

  defp same_channel?(
         %{adapter_payload: %{conn_pid: a}},
         %{adapter_payload: %{conn_pid: b}}
       )
       when is_pid(a) and is_pid(b),
       do: a == b

  defp same_channel?(_, _), do: false

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_), do: %{}
end
