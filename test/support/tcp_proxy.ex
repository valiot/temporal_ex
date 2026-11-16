defmodule TemporalEx.Test.TcpProxy do
  @moduledoc false
  # A TCP proxy in front of a real server. `blackhole/1` makes every connection
  # open so far go silent in both directions while its sockets stay open —
  # what a client sees when a NAT or load balancer drops a flow without a RST.
  # Connections accepted afterwards are forwarded normally, so a reconnect
  # reaches the server.

  use GenServer

  def start_link(upstream_port) do
    GenServer.start_link(__MODULE__, upstream_port)
  end

  def port(proxy), do: GenServer.call(proxy, :port)

  def blackhole(proxy), do: GenServer.call(proxy, :blackhole)

  @impl true
  def init(upstream_port) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    proxy = self()
    spawn_link(fn -> accept_loop(listen, upstream_port, proxy) end)
    {:ok, %{listen: listen, port: port, pipes: []}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:blackhole, _from, state) do
    Enum.each(state.pipes, &send(&1, :blackhole))
    {:reply, :ok, %{state | pipes: []}}
  end

  def handle_call({:pipe, pid}, _from, state) do
    {:reply, :ok, %{state | pipes: [pid | state.pipes]}}
  end

  defp accept_loop(listen, upstream_port, proxy) do
    {:ok, downstream} = :gen_tcp.accept(listen)

    {:ok, upstream} =
      :gen_tcp.connect({127, 0, 0, 1}, upstream_port, [:binary, active: false])

    pipe = spawn_link(fn -> await_sockets() end)
    :ok = :gen_tcp.controlling_process(downstream, pipe)
    :ok = :gen_tcp.controlling_process(upstream, pipe)
    send(pipe, {:sockets, downstream, upstream})
    :ok = GenServer.call(proxy, {:pipe, pipe})
    accept_loop(listen, upstream_port, proxy)
  end

  defp await_sockets do
    receive do
      {:sockets, downstream, upstream} ->
        :ok = :inet.setopts(downstream, active: true)
        :ok = :inet.setopts(upstream, active: true)
        forward(downstream, upstream, _silent? = false)
    end
  end

  defp forward(downstream, upstream, silent?) do
    receive do
      :blackhole ->
        forward(downstream, upstream, true)

      {:tcp, ^downstream, data} ->
        unless silent?, do: :gen_tcp.send(upstream, data)
        forward(downstream, upstream, silent?)

      {:tcp, ^upstream, data} ->
        unless silent?, do: :gen_tcp.send(downstream, data)
        forward(downstream, upstream, silent?)

      {:tcp_closed, _socket} ->
        :gen_tcp.close(downstream)
        :gen_tcp.close(upstream)
    end
  end
end
