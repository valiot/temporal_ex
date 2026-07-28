defmodule TemporalEx.ClientTest do
  use ExUnit.Case

  alias TemporalEx.Client

  describe "start_link/1" do
    test "starts with default options" do
      assert {:ok, pid} = Client.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom name" do
      assert {:ok, pid} = Client.start_link(name: :test_temporal_client)
      assert Process.alive?(pid)
      assert Process.whereis(:test_temporal_client) == pid
      GenServer.stop(pid)
    end

    test "stores configured namespace" do
      {:ok, pid} = Client.start_link(namespace: "my-namespace")
      assert Client.namespace(pid) == "my-namespace"
      GenServer.stop(pid)
    end

    test "defaults namespace to 'default'" do
      {:ok, pid} = Client.start_link()
      assert Client.namespace(pid) == "default"
      GenServer.stop(pid)
    end

    test "stores configured data converter" do
      {:ok, pid} = Client.start_link(data_converter: TemporalEx.DataConverter.Json)
      assert Client.data_converter(pid) == TemporalEx.DataConverter.Json
      GenServer.stop(pid)
    end

    test "defaults data converter to Json" do
      {:ok, pid} = Client.start_link()
      assert Client.data_converter(pid) == TemporalEx.DataConverter.Json
      GenServer.stop(pid)
    end

    test "accepts target option" do
      {:ok, pid} = Client.start_link(target: "custom-host:7233")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "normalizes Temporal Cloud target" do
      {:ok, pid} = Client.start_link(target: "my-ns.tmprl.cloud:7233")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts api_key option" do
      {:ok, pid} = Client.start_link(api_key: "test-api-key")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts tls config as map" do
      {:ok, pid} = Client.start_link(tls: %{})
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts tls config as keyword list" do
      {:ok, pid} = Client.start_link(tls: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "rpc/4" do
    test "returns connection error when server is not reachable" do
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}
      result = Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      assert {:error, "Temporal connection error:" <> _} = result

      GenServer.stop(pid)
    end

    # Reproduces the production failure mode seen by pipex on Temporal Cloud:
    # gun reports `{:error, {:down, :normal}}` mid-RPC (clean channel death),
    # which becomes `%GRPC.RPCError{status: 2, message: ":down: :normal"}`.
    # Before the fix, Client kept the dead channel in state, so every later
    # RPC reused the corpse and failed the same way forever — ConnectionWatchdog
    # in pipex had to terminate/restart the whole GenServer to recover.
    test "clears channel and reconnects after gun dies mid-RPC with :normal" do
      # Point at an unused port so a reconnect attempt can't silently "succeed"
      # against a real Temporal; we only care that connect is *attempted*.
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      install_dying_channel!(pid, exit_reason: :normal)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      # First RPC rides the dying channel → transport-down error.
      assert {:error, %GRPC.RPCError{status: 2, message: ":down: :normal"}} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      # Channel must be invalidated so the next call re-runs GRPC.Stub.connect
      # instead of reusing the dead gun pid.
      assert :sys.get_state(pid).channel == nil

      # Second RPC attempts a fresh connect to the unreachable target →
      # connection error, NOT another `:down: :normal` from the corpse channel.
      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      GenServer.stop(pid)
    end

    test "clears channel after gun dies mid-RPC with :noproc" do
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      # Already-dead process: gun.await reports `{:down, :noproc}` (the sticky
      # corpse case pipex's ConnectionWatchdog was written for).
      install_dead_channel!(pid)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      assert {:error, %GRPC.RPCError{status: 2, message: ":down: :noproc"}} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      assert :sys.get_state(pid).channel == nil

      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      GenServer.stop(pid)
    end
  end

  # ── Channel-death fixtures ──────────────────────────────────────────
  #
  # Real gun/gRPC path: `:gun.post` casts a request to `conn_pid`, then
  # `:gun.await` monitors it. When the process exits mid-await, gun returns
  # `{:error, {:down, reason}}` which the GRPC gun adapter turns into
  # `%GRPC.RPCError{status: 2, message: ":down: #{inspect(reason)}"}`.

  defp install_dying_channel!(client, exit_reason: reason) do
    fake_gun =
      spawn(fn ->
        receive do
          {:"$gen_cast", _} ->
            # Brief delay so gun.await has time to install its monitor before
            # we exit — otherwise the race can report :noproc instead of reason.
            Process.sleep(20)
            exit(reason)
        end
      end)

    put_channel!(client, fake_gun)
  end

  defp install_dead_channel!(client) do
    dead =
      spawn(fn -> :ok end)
      |> tap(fn pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
      end)

    put_channel!(client, dead)
  end

  defp put_channel!(client, conn_pid) do
    channel = %GRPC.Channel{
      host: "localhost",
      port: 17_233,
      scheme: "http",
      adapter: GRPC.Client.Adapters.Gun,
      adapter_payload: %{conn_pid: conn_pid},
      codec: GRPC.Codec.Proto
    }

    :sys.replace_state(client, fn state -> %{state | channel: channel} end)
  end
end
