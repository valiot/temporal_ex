defmodule TemporalEx.DataConverter do
  @moduledoc """
  Behaviour for encoding/decoding Elixir terms to/from Temporal payloads.

  The data converter is responsible for serializing workflow arguments,
  results, and other data that flows through Temporal. Implementations
  must handle arbitrary Elixir terms and produce binary data with
  encoding metadata.

  The default implementation is `TemporalEx.DataConverter.Json`.
  """

  @type encoding :: String.t()
  @type metadata :: %{String.t() => String.t()}

  @doc "Returns the encoding identifier (e.g., `\"json/plain\"`)."
  @callback encoding() :: encoding()

  @doc """
  Encodes an Elixir term into a binary with metadata.

  Returns `{:ok, {binary_data, metadata_map}}` or `{:error, reason}`.
  """
  @callback encode(term()) :: {:ok, {binary(), metadata()}} | {:error, term()}

  @doc """
  Decodes binary data back into an Elixir term.

  The metadata map provides encoding hints (e.g., `%{"encoding" => "json/plain"}`).
  """
  @callback decode(binary(), metadata()) :: {:ok, term()} | {:error, term()}
end
