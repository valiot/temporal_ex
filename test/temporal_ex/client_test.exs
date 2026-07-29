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

    # Production failure mode on Temporal Cloud: gun reports
    # `{:error, {:down, :normal}}` mid-RPC → `%GRPC.RPCError{message: ":down: :normal"}`.
    # Client must not stick on the corpse channel; it invalidates, reconnects,
    # and retries the same call once so a single blip is invisible when the
    # server is reachable again.
    test "retries once after gun dies mid-RPC with :normal" do
      # Unreachable target: first attempt dies on the planted channel, retry
      # re-runs GRPC.Stub.connect and surfaces a connection error — never a
      # sticky `:down: :normal` on subsequent calls.
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      install_dying_channel!(pid, exit_reason: :normal, hold_ms: 20)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      # Transparent retry: caller sees the reconnect attempt, not the first
      # `:down: :normal` (target is down so reconnect fails with connect error).
      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      assert :sys.get_state(pid).channel == nil

      # Still not stuck on a corpse — another call also tries a fresh connect.
      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      GenServer.stop(pid)
    end

    test "retries once after gun dies mid-RPC with :noproc" do
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      # Already-dead process: gun.await reports `{:down, :noproc}` (the sticky
      # corpse case pipex's ConnectionWatchdog was written for).
      install_dead_channel!(pid)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      assert :sys.get_state(pid).channel == nil

      GenServer.stop(pid)
    end

    test "transport death triggers a second connect attempt on the same rpc" do
      # Without a live Temporal we cannot assert a successful retry body;
      # prove the retry *path* instead: connect is invoked twice per rpc
      # when the first channel dies mid-RPC.
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      connect_fun = fn _server, _opts ->
        n = Agent.get_and_update(attempts, fn c -> {c + 1, c + 1} end)

        case n do
          1 ->
            {:ok, dying_channel(hold_ms: 20, exit_reason: :normal)}

          _ ->
            # Second checkout: deterministic connect failure without Temporal.
            {:error, :econnrefused}
        end
      end

      {:ok, pid} = Client.start_link(target: "localhost:17233", connect_fun: connect_fun)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      assert {:error, "Temporal connection error:" <> _} =
               Client.rpc(pid, :get_system_info, request, timeout: 2_000)

      # checkout #1 (dying) + reconnect after invalidate = 2 connect attempts
      assert Agent.get(attempts, & &1) == 2

      GenServer.stop(pid)
    end

    test "late gun_down for an old conn_pid does not wipe a reconnected channel" do
      {:ok, pid} = Client.start_link(target: "localhost:17233")

      old_gun = spawn(fn -> Process.sleep(:infinity) end)
      new_gun = spawn(fn -> Process.sleep(:infinity) end)

      put_channel!(pid, new_gun)
      assert channel_conn_pid(:sys.get_state(pid).channel) == new_gun

      # Simulate a delayed down from a predecessor connection.
      send(pid, {:gun_down, old_gun, :http2, :closed, []})
      # Allow handle_info to run.
      _ = :sys.get_state(pid)

      assert channel_conn_pid(:sys.get_state(pid).channel) == new_gun

      # A down for the current pid still clears.
      send(pid, {:gun_down, new_gun, :http2, :closed, []})
      _ = :sys.get_state(pid)
      assert :sys.get_state(pid).channel == nil

      for g <- [old_gun, new_gun], Process.alive?(g), do: Process.exit(g, :kill)
      GenServer.stop(pid)
    end

    test "namespace reads stay responsive while an RPC awaits gun" do
      # Before offloading I/O from the GenServer, a mid-flight RPC blocked
      # every other call (including cheap namespace reads) for the full gun
      # await — the pipex EventSubscriber `get_namespace` timeout storm.
      {:ok, pid} = Client.start_link(target: "localhost:17233", namespace: "zn-prod")

      install_dying_channel!(pid, exit_reason: :normal, hold_ms: 400)

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      rpc_task =
        Task.async(fn ->
          Client.rpc(pid, :get_system_info, request, timeout: 2_000)
        end)

      # Let the RPC check out the channel and enter gun.await.
      Process.sleep(30)

      {elapsed_us, namespace} = :timer.tc(fn -> Client.namespace(pid) end)
      assert namespace == "zn-prod"
      # Must not wait on the 400ms hold — GenServer is free during await.
      assert elapsed_us < 100_000

      _ = Task.await(rpc_task, 5_000)
      GenServer.stop(pid)
    end

    test "namespace/data_converter reads stay lock-free while the GenServer blocks in connect" do
      # The prolamsa-prod `get_namespace` timeout storm: a concurrent caller
      # sits inside `handle_call({:checkout})` running a slow connect, pinning
      # the mailbox. Metadata reads are served from persistent_term, so they
      # must not queue behind that connect — before this they timed out at 5s.
      test_pid = self()

      slow_connect = fn _server, _opts ->
        send(test_pid, :connecting)
        Process.sleep(1_000)
        {:error, :simulated_unreachable}
      end

      {:ok, pid} =
        Client.start_link(
          target: "localhost:17233",
          namespace: "blocked-ns",
          connect_fun: slow_connect
        )

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      # Kick a checkout from another process so the GenServer is stuck in connect.
      _ = spawn(fn -> Client.rpc(pid, :get_system_info, request, timeout: 3_000) end)
      assert_receive :connecting, 1_000

      {ns_us, namespace} = :timer.tc(fn -> Client.namespace(pid) end)
      {dc_us, converter} = :timer.tc(fn -> Client.data_converter(pid) end)

      assert namespace == "blocked-ns"
      assert converter == TemporalEx.DataConverter.Json
      # Must not wait on the 1s connect hold — persistent_term, not GenServer.call.
      assert ns_us < 100_000
      assert dc_us < 100_000

      GenServer.stop(pid)
    end

    test "reads via pid stay lock-free for a name-registered client blocked in connect" do
      # start_link returns a pid even when a name is registered, and the docs are
      # pid-first — so a caller may hold the pid of a named client. That pid must
      # still resolve to the name-keyed cache (via Process.info), not fall back to
      # the GenServer, or it would time out behind a blocking connect.
      test_pid = self()

      slow_connect = fn _server, _opts ->
        send(test_pid, :connecting)
        Process.sleep(1_000)
        {:error, :simulated_unreachable}
      end

      {:ok, pid} =
        Client.start_link(
          name: :meta_named_blocked_client,
          target: "localhost:17233",
          namespace: "named-ns",
          connect_fun: slow_connect
        )

      request = %Temporal.Api.Workflowservice.V1.GetSystemInfoRequest{}

      # Block the GenServer in connect via the registered name.
      _ =
        spawn(fn ->
          Client.rpc(:meta_named_blocked_client, :get_system_info, request, timeout: 3_000)
        end)

      assert_receive :connecting, 1_000

      # Read by the PID (not the name) while the mailbox is pinned.
      {ns_us, namespace} = :timer.tc(fn -> Client.namespace(pid) end)
      assert namespace == "named-ns"
      assert ns_us < 100_000

      GenServer.stop(pid)
    end
  end

  # ── Channel-death fixtures ──────────────────────────────────────────
  #
  # Real gun/gRPC path: `:gun.post` casts a request to `conn_pid`, then
  # `:gun.await` monitors it. When the process exits mid-await, gun returns
  # `{:error, {:down, reason}}` which the GRPC gun adapter turns into
  # `%GRPC.RPCError{status: 2, message: ":down: #{inspect(reason)}"}`.

  defp install_dying_channel!(client, opts) do
    put_channel!(client, dying_conn_pid(opts))
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

  defp dying_channel(opts) do
    channel_for(dying_conn_pid(opts))
  end

  defp dying_conn_pid(opts) do
    reason = Keyword.get(opts, :exit_reason, :normal)
    hold_ms = Keyword.get(opts, :hold_ms, 20)

    spawn(fn ->
      receive do
        {:"$gen_cast", _} ->
          # Delay so gun.await installs its monitor before we exit —
          # otherwise the race can report :noproc instead of reason.
          Process.sleep(hold_ms)
          exit(reason)
      end
    end)
  end

  defp put_channel!(client, conn_pid) do
    :sys.replace_state(client, fn state -> %{state | channel: channel_for(conn_pid)} end)
  end

  defp channel_for(conn_pid) do
    %GRPC.Channel{
      host: "localhost",
      port: 17_233,
      scheme: "http",
      adapter: GRPC.Client.Adapters.Gun,
      adapter_payload: %{conn_pid: conn_pid},
      codec: GRPC.Codec.Proto
    }
  end

  defp channel_conn_pid(%{adapter_payload: %{conn_pid: pid}}), do: pid
  defp channel_conn_pid(_), do: nil
end
