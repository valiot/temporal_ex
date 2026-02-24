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
  end
end
