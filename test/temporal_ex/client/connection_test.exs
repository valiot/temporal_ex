defmodule TemporalEx.Client.ConnectionTest do
  use ExUnit.Case, async: true

  alias TemporalEx.Client.Connection

  describe "normalize_server_address/1" do
    test "adds https:// for tmprl.cloud domains" do
      assert Connection.normalize_server_address("my-ns.tmprl.cloud:7233") ==
               "https://my-ns.tmprl.cloud:7233"
    end

    test "adds https:// for api.temporal.io domains" do
      assert Connection.normalize_server_address("my-ns.api.temporal.io:7233") ==
               "https://my-ns.api.temporal.io:7233"
    end

    test "does not add prefix for localhost" do
      assert Connection.normalize_server_address("localhost:7233") == "localhost:7233"
    end

    test "does not add prefix for plain IP" do
      assert Connection.normalize_server_address("192.168.1.1:7233") == "192.168.1.1:7233"
    end

    test "preserves existing http:// prefix" do
      assert Connection.normalize_server_address("http://localhost:7233") ==
               "http://localhost:7233"
    end

    test "preserves existing https:// prefix" do
      assert Connection.normalize_server_address("https://custom.host:7233") ==
               "https://custom.host:7233"
    end
  end

  describe "authorization_from_api_key/1" do
    test "returns nil for nil" do
      assert Connection.authorization_from_api_key(nil) == nil
    end

    test "returns nil for empty string" do
      assert Connection.authorization_from_api_key("") == nil
    end

    test "wraps plain key with Bearer prefix" do
      assert Connection.authorization_from_api_key("my-key") == "Bearer my-key"
    end

    test "preserves existing Bearer prefix" do
      assert Connection.authorization_from_api_key("Bearer my-key") == "Bearer my-key"
    end
  end

  describe "request_metadata/2" do
    test "builds metadata with both namespace and authorization" do
      metadata = Connection.request_metadata("my-ns", "Bearer token")

      assert metadata == %{
               "temporal-namespace" => "my-ns",
               "authorization" => "Bearer token"
             }
    end

    test "omits nil values" do
      metadata = Connection.request_metadata(nil, "Bearer token")
      assert metadata == %{"authorization" => "Bearer token"}
    end

    test "omits empty string values" do
      metadata = Connection.request_metadata("", nil)
      assert metadata == %{}
    end

    test "returns empty map when both nil" do
      assert Connection.request_metadata(nil, nil) == %{}
    end
  end

  describe "resolve_client_mtls_files/1" do
    test "returns nils when no mTLS config present" do
      assert {nil, nil, []} = Connection.resolve_client_mtls_files(%{})
    end

    test "writes temp files when both cert and key provided" do
      cert_b64 = Base.encode64("-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----")
      key_b64 = Base.encode64("-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----")

      config = %{client_cert_pem_b64: cert_b64, client_key_pem_b64: key_b64}
      {cert_path, key_path, temp_files} = Connection.resolve_client_mtls_files(config)

      assert is_binary(cert_path)
      assert is_binary(key_path)
      assert length(temp_files) == 2
      assert File.exists?(cert_path)
      assert File.exists?(key_path)

      # Verify file permissions
      {:ok, %{mode: cert_mode}} = File.stat(cert_path)
      assert Bitwise.band(cert_mode, 0o777) == 0o600

      # Cleanup
      Connection.cleanup_temp_pem_files(temp_files)
      refute File.exists?(cert_path)
      refute File.exists?(key_path)
    end

    test "raises when only cert is provided" do
      cert_b64 = Base.encode64("cert-data")
      config = %{client_cert_pem_b64: cert_b64}

      assert_raise ArgumentError, ~r/both :client_cert_pem_b64 and :client_key_pem_b64/, fn ->
        Connection.resolve_client_mtls_files(config)
      end
    end

    test "raises when only key is provided" do
      key_b64 = Base.encode64("key-data")
      config = %{client_key_pem_b64: key_b64}

      assert_raise ArgumentError, ~r/both :client_cert_pem_b64 and :client_key_pem_b64/, fn ->
        Connection.resolve_client_mtls_files(config)
      end
    end

    test "raises for invalid base64" do
      config = %{client_cert_pem_b64: "!!!invalid!!!", client_key_pem_b64: "also-invalid"}

      assert_raise ArgumentError, ~r/Invalid base64/, fn ->
        Connection.resolve_client_mtls_files(config)
      end
    end
  end

  describe "format_connect_error/1" do
    test "formats ASN.1 TLS errors" do
      error = {:down, {{:badmatch, {:error, {:asn1, :some_reason}}}, [], []}}
      result = Connection.format_connect_error(error)
      assert result =~ "ASN.1 parse failure"
      assert result =~ "Regenerate"
    end

    test "formats generic errors" do
      result = Connection.format_connect_error(:timeout)
      assert result == "Temporal connection error: :timeout"
    end
  end

  describe "grpc_connect_opts/2" do
    test "returns base opts with no TLS" do
      {opts, temp_files} = Connection.grpc_connect_opts("localhost:7233", %{})
      assert temp_files == []
      assert Keyword.has_key?(opts, :adapter_opts)
    end

    test "includes credentials for https server" do
      {opts, _temp_files} = Connection.grpc_connect_opts("https://cloud.temporal.io:7233", %{})
      assert Keyword.has_key?(opts, :cred)
    end

    test "passes connect_retry to adapter_opts" do
      {opts, _} = Connection.grpc_connect_opts("localhost:7233", %{connect_retry: 3})
      adapter_opts = Keyword.get(opts, :adapter_opts)
      assert Keyword.get(adapter_opts, :retry) == 3
    end
  end

  describe "parse_non_negative_integer/2" do
    test "returns integer as-is when non-negative" do
      assert Connection.parse_non_negative_integer(42, 0) == 42
    end

    test "returns default for negative integer" do
      assert Connection.parse_non_negative_integer(-1, 0) == 0
    end

    test "parses string integers" do
      assert Connection.parse_non_negative_integer("42", 0) == 42
    end

    test "returns default for non-numeric string" do
      assert Connection.parse_non_negative_integer("abc", 0) == 0
    end

    test "returns default for nil" do
      assert Connection.parse_non_negative_integer(nil, 5) == 5
    end
  end

  describe "cleanup_temp_pem_files/1" do
    test "removes files" do
      path =
        Path.join(System.tmp_dir!(), "test-cleanup-#{System.unique_integer([:positive])}.pem")

      File.write!(path, "test")
      assert File.exists?(path)

      Connection.cleanup_temp_pem_files([path])
      refute File.exists?(path)
    end

    test "handles empty list" do
      assert :ok = Connection.cleanup_temp_pem_files([])
    end

    test "handles nil/empty paths gracefully" do
      assert :ok = Connection.cleanup_temp_pem_files([nil, ""])
    end
  end
end
