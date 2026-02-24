defmodule TemporalEx.DataConverter.Json do
  @moduledoc """
  Default JSON data converter using Jason.

  Encodes Elixir terms as `"json/plain"` payloads. Decodes JSON binaries
  back into Elixir maps/lists/scalars.
  """

  @behaviour TemporalEx.DataConverter

  @encoding "json/plain"

  @impl true
  def encoding, do: @encoding

  @impl true
  def encode(term) do
    case Jason.encode(term) do
      {:ok, json} ->
        {:ok, {json, %{"encoding" => @encoding}}}

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  @impl true
  def decode(binary, _metadata) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, term} -> {:ok, term}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end
end
