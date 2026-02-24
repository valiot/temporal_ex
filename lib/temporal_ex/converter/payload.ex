defmodule TemporalEx.Converter.Payload do
  @moduledoc """
  Converts between Elixir terms and Temporal `Payload`/`Payloads` protobuf structs.
  """

  @doc """
  Encodes a list of Elixir terms into a `Temporal.Api.Common.V1.Payloads` struct.
  """
  def encode(terms, converter) when is_list(terms) do
    payloads = Enum.map(terms, &encode_single(&1, converter))
    %Temporal.Api.Common.V1.Payloads{payloads: payloads}
  end

  @doc """
  Encodes a single Elixir term into a `Temporal.Api.Common.V1.Payload` struct.
  """
  def encode_single(term, converter) do
    {:ok, {data, metadata}} = converter.encode(term)

    %Temporal.Api.Common.V1.Payload{
      metadata: metadata,
      data: data
    }
  end

  @doc """
  Decodes a `Temporal.Api.Common.V1.Payloads` struct into a list of Elixir terms.
  """
  def decode(%Temporal.Api.Common.V1.Payloads{payloads: payloads}, converter)
      when is_list(payloads) do
    Enum.map(payloads, &decode_single(&1, converter))
  end

  def decode(nil, _converter), do: []

  @doc """
  Decodes a single `Temporal.Api.Common.V1.Payload` struct into an Elixir term.
  """
  def decode_single(%Temporal.Api.Common.V1.Payload{data: data, metadata: metadata}, converter) do
    {:ok, term} = converter.decode(data, metadata)
    term
  end
end
