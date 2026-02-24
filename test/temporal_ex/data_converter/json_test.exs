defmodule TemporalEx.DataConverter.JsonTest do
  use ExUnit.Case, async: true

  alias TemporalEx.DataConverter.Json

  describe "encoding/0" do
    test "returns json/plain" do
      assert Json.encoding() == "json/plain"
    end
  end

  describe "encode/1" do
    test "encodes a map" do
      assert {:ok, {json, metadata}} = Json.encode(%{key: "value", number: 42})
      assert metadata == %{"encoding" => "json/plain"}
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded == %{"key" => "value", "number" => 42}
    end

    test "encodes a list" do
      assert {:ok, {json, _metadata}} = Json.encode([1, 2, 3])
      assert json == "[1,2,3]"
    end

    test "encodes a string" do
      assert {:ok, {json, _metadata}} = Json.encode("hello")
      assert json == "\"hello\""
    end

    test "encodes nil" do
      assert {:ok, {"null", _metadata}} = Json.encode(nil)
    end

    test "encodes a number" do
      assert {:ok, {"42", _metadata}} = Json.encode(42)
    end

    test "returns error for non-encodable terms" do
      assert {:error, {:encode_failed, _}} = Json.encode(self())
    end
  end

  describe "decode/2" do
    test "decodes a JSON object" do
      assert {:ok, %{"key" => "value"}} = Json.decode(~s({"key":"value"}), %{})
    end

    test "decodes a JSON array" do
      assert {:ok, [1, 2, 3]} = Json.decode("[1,2,3]", %{})
    end

    test "decodes a JSON string" do
      assert {:ok, "hello"} = Json.decode("\"hello\"", %{})
    end

    test "decodes JSON null" do
      assert {:ok, nil} = Json.decode("null", %{})
    end

    test "returns error for invalid JSON" do
      assert {:error, {:decode_failed, _}} = Json.decode("not valid json", %{})
    end

    test "roundtrips a complex structure" do
      original = %{"users" => [%{"name" => "Alice", "age" => 30}], "count" => 1}
      assert {:ok, {json, metadata}} = Json.encode(original)
      assert {:ok, decoded} = Json.decode(json, metadata)
      assert decoded == original
    end
  end
end
