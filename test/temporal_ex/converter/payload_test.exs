defmodule TemporalEx.Converter.PayloadTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Converter.Payload
  alias TemporalEx.DataConverter.Json

  describe "encode/2" do
    test "encodes a list of terms into Payloads" do
      result = Payload.encode([%{key: "value"}, "hello"], Json)
      assert %Temporal.Api.Common.V1.Payloads{payloads: payloads} = result
      assert length(payloads) == 2

      [first, second] = payloads
      assert %Temporal.Api.Common.V1.Payload{metadata: %{"encoding" => "json/plain"}} = first
      assert {:ok, %{"key" => "value"}} = Jason.decode(first.data)
      assert {:ok, "hello"} = Jason.decode(second.data)
    end

    test "encodes an empty list" do
      result = Payload.encode([], Json)
      assert %Temporal.Api.Common.V1.Payloads{payloads: []} = result
    end
  end

  describe "encode_single/2" do
    test "encodes a single term into a Payload" do
      result = Payload.encode_single(%{foo: "bar"}, Json)
      assert %Temporal.Api.Common.V1.Payload{} = result
      assert result.metadata == %{"encoding" => "json/plain"}
      assert {:ok, %{"foo" => "bar"}} = Jason.decode(result.data)
    end
  end

  describe "decode/2" do
    test "decodes Payloads into a list of terms" do
      payloads = %Temporal.Api.Common.V1.Payloads{
        payloads: [
          %Temporal.Api.Common.V1.Payload{
            metadata: %{"encoding" => "json/plain"},
            data: ~s({"key":"value"})
          },
          %Temporal.Api.Common.V1.Payload{
            metadata: %{"encoding" => "json/plain"},
            data: "42"
          }
        ]
      }

      result = Payload.decode(payloads, Json)
      assert [%{"key" => "value"}, 42] = result
    end

    test "returns empty list for nil" do
      assert Payload.decode(nil, Json) == []
    end
  end

  describe "decode_single/2" do
    test "decodes a single Payload" do
      payload = %Temporal.Api.Common.V1.Payload{
        metadata: %{"encoding" => "json/plain"},
        data: ~s({"name":"Alice"})
      }

      result = Payload.decode_single(payload, Json)
      assert %{"name" => "Alice"} = result
    end
  end

  describe "roundtrip" do
    test "encode then decode preserves data" do
      original = [%{name: "test", count: 42}, [1, 2, 3]]
      encoded = Payload.encode(original, Json)
      decoded = Payload.decode(encoded, Json)

      # Note: atoms become strings through JSON
      assert [%{"name" => "test", "count" => 42}, [1, 2, 3]] = decoded
    end
  end
end
