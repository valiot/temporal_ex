Mox.defmock(TemporalEx.MockDataConverter, for: TemporalEx.DataConverter)

# Tests tagged :temporal talk to a real Temporal dev server on localhost:7233
# (`temporal server start-dev`). Without one they are skipped, not failed.
temporal_reachable? =
  case :gen_tcp.connect(~c"localhost", 7233, [], 500) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    {:error, _} ->
      false
  end

unless temporal_reachable? do
  IO.puts("No Temporal on localhost:7233; skipping tests tagged :temporal")
end

ExUnit.start(exclude: if(temporal_reachable?, do: [], else: [:temporal]))
