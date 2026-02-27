defmodule TemporalEx.Client do
  @moduledoc """
  GenServer that owns the gRPC channel to a Temporal server and provides
  generic RPC dispatch.

  Adding new RPCs never requires changes to this module — callers simply
  pass the stub function name and a pre-built protobuf request to `rpc/4`.
  """

  use GenServer

  alias TemporalEx.Client.Connection

  @default_server "localhost:7233"
  @default_call_timeout 5_000
  @default_namespace "default"

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
    GenServer.call(client, {:rpc, rpc_name, request, opts}, timeout)
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

    {:ok,
     %{
       channel: nil,
       server: server,
       namespace: namespace,
       connect_opts: connect_opts,
       authorization: Connection.authorization_from_api_key(api_key),
       identity: identity,
       data_converter: data_converter,
       call_timeout: call_timeout,
       temp_pem_files: temp_pem_files
     }}
  end

  @impl true
  def handle_call({:rpc, rpc_name, request, opts}, _from, state) do
    namespace = Keyword.get(opts, :namespace, state.namespace)

    case ensure_channel(state) do
      {:ok, connected_state} ->
        metadata = Connection.request_metadata(namespace, connected_state.authorization)
        call_opts = if map_size(metadata) > 0, do: [metadata: metadata], else: []

        result = invoke_rpc(rpc_name, connected_state.channel, request, call_opts)
        {:reply, result, connected_state}

      {:error, reason, disconnected_state} ->
        {:reply, {:error, reason}, disconnected_state}
    end
  end

  @impl true
  def handle_call(:get_namespace, _from, state) do
    {:reply, state.namespace, state}
  end

  @impl true
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

  defp ensure_channel(%{server: server, connect_opts: connect_opts} = state) do
    case GRPC.Stub.connect(server, connect_opts) do
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

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_), do: %{}
end
