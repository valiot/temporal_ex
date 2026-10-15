defmodule TemporalEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # grpc >= 1.0 starts GRPC.Client.Supervisor from its own application tree.
    children = []

    opts = [strategy: :one_for_one, name: TemporalEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
