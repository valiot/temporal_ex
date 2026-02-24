defmodule TemporalEx.Client.Connection do
  @moduledoc """
  Pure functions for building gRPC connection options, TLS credentials,
  and request metadata.

  Ported from `Temporalio.Client` — all side-effect-free except for
  temporary PEM file writes in `resolve_client_mtls_files/1`.
  """

  @doc """
  Normalizes a server address, auto-prepending `https://` for known
  Temporal Cloud domains.

  ## Examples

      iex> normalize_server_address("my-ns.tmprl.cloud:7233")
      "https://my-ns.tmprl.cloud:7233"

      iex> normalize_server_address("localhost:7233")
      "localhost:7233"

      iex> normalize_server_address("https://custom.host:7233")
      "https://custom.host:7233"
  """
  @spec normalize_server_address(String.t()) :: String.t()
  def normalize_server_address(server) when is_binary(server) do
    if needs_https_prefix?(server) do
      "https://" <> server
    else
      server
    end
  end

  @doc """
  Builds a `GRPC.Credential` for TLS/mTLS, along with a list of
  temporary PEM file paths to clean up on shutdown.

  Returns `{credential | nil, temp_pem_file_paths}`.
  """
  @spec build_credential(String.t(), map()) :: {GRPC.Credential.t() | nil, [String.t()]}
  def build_credential(server, config) when is_map(config) do
    {client_cert_file, client_key_file, temp_pem_files} =
      resolve_client_mtls_files(config)

    ca_cert_file = resolve_ca_cert_file(config)

    credential =
      if tls_server?(server) or (client_cert_file && client_key_file) do
        ssl_opts =
          []
          |> put_ssl_opt(:verify, :verify_peer)
          |> put_ssl_opt(:depth, 99)
          |> put_ssl_opt(:cacertfile, ca_cert_file)
          |> put_ssl_opt(:certfile, client_cert_file)
          |> put_ssl_opt(:keyfile, client_key_file)

        GRPC.Credential.new(ssl: ssl_opts)
      else
        nil
      end

    {credential, temp_pem_files}
  end

  @doc """
  Resolves mTLS client certificate and key from base64-encoded config values.

  Writes decoded PEM data to temporary files and returns their paths.

  Returns `{cert_path | nil, key_path | nil, temp_file_paths}`.
  """
  @spec resolve_client_mtls_files(map()) :: {String.t() | nil, String.t() | nil, [String.t()]}
  def resolve_client_mtls_files(config) when is_map(config) do
    cert_pem = decode_b64_value(Map.get(config, :client_cert_pem_b64), "client_cert")
    key_pem = decode_b64_value(Map.get(config, :client_key_pem_b64), "client_key")

    cond do
      present?(cert_pem) and present?(key_pem) ->
        cert_path = write_temp_pem_file!("temporal-client-cert", cert_pem)
        key_path = write_temp_pem_file!("temporal-client-key", key_pem)
        {cert_path, key_path, [cert_path, key_path]}

      present?(cert_pem) or present?(key_pem) ->
        raise ArgumentError,
              "Temporal mTLS config requires both :client_cert_pem_b64 and :client_key_pem_b64"

      true ->
        {nil, nil, []}
    end
  end

  @doc """
  Builds gRPC request metadata map from namespace and authorization.
  """
  @spec request_metadata(String.t() | nil, String.t() | nil) :: map()
  def request_metadata(namespace, authorization) do
    %{}
    |> maybe_put("temporal-namespace", namespace)
    |> maybe_put("authorization", authorization)
  end

  @doc """
  Converts an API key string to a Bearer authorization header value.
  """
  @spec authorization_from_api_key(String.t() | nil) :: String.t() | nil
  def authorization_from_api_key(nil), do: nil
  def authorization_from_api_key(""), do: nil
  def authorization_from_api_key("Bearer " <> _ = auth), do: auth
  def authorization_from_api_key(api_key) when is_binary(api_key), do: "Bearer " <> api_key

  @doc """
  Builds the base gRPC connection options including adapter opts and retry config.

  Returns `{connect_opts, temp_pem_file_paths}`.
  """
  @spec grpc_connect_opts(String.t(), map()) :: {keyword(), [String.t()]}
  def grpc_connect_opts(server, config) when is_map(config) do
    connect_retry =
      config
      |> Map.get(:connect_retry, 0)
      |> parse_non_negative_integer(0)

    adapter_opts =
      config
      |> Map.get(:adapter_opts, [])
      |> List.wrap()
      |> Keyword.put_new(:retry, connect_retry)

    base_opts = [adapter_opts: adapter_opts]

    {credential, temp_pem_files} = build_credential(server, config)

    connect_opts =
      case credential do
        nil -> base_opts
        _ -> [cred: credential] ++ base_opts
      end

    {connect_opts, temp_pem_files}
  end

  @doc """
  Removes temporary PEM files created during mTLS setup.
  """
  @spec cleanup_temp_pem_files([String.t()]) :: :ok
  def cleanup_temp_pem_files(paths) when is_list(paths) do
    Enum.each(paths, fn path ->
      if is_binary(path) and path != "" do
        _ = File.rm(path)
      end
    end)

    :ok
  end

  @doc """
  Formats a gRPC connection error into a human-readable string.
  """
  @spec format_connect_error(term()) :: String.t()
  def format_connect_error({:down, {{:badmatch, {:error, {:asn1, _}}}, _stack, _}}) do
    "Temporal connection error: mTLS client certificate/key is not accepted by Erlang TLS (ASN.1 parse failure). " <>
      "Regenerate the Temporal client certificate/key pair or use API key auth."
  end

  def format_connect_error(reason) do
    "Temporal connection error: #{inspect(reason)}"
  end

  # Private helpers

  defp needs_https_prefix?(server) do
    !String.starts_with?(server, ["http://", "https://"]) and
      String.contains?(server, [".tmprl.cloud", ".api.temporal.io"])
  end

  defp tls_server?(server), do: String.starts_with?(server, "https://")

  defp resolve_ca_cert_file(config) do
    case Map.get(config, :ca_cert_file) do
      path when is_binary(path) and path != "" ->
        ensure_file_exists!(path, :ca_cert_file)
        path

      _ ->
        if Code.ensure_loaded?(CAStore), do: CAStore.file_path(), else: nil
    end
  end

  defp decode_b64_value(nil, _label), do: nil
  defp decode_b64_value("", _label), do: nil

  defp decode_b64_value(value, label) when is_binary(value) do
    case Base.decode64(value, ignore: :whitespace) do
      {:ok, decoded} -> decoded
      :error -> raise ArgumentError, "Invalid base64 value for Temporal #{label}"
    end
  end

  defp write_temp_pem_file!(prefix, pem) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}.pem"
      )

    {:ok, file} = File.open(path, [:write, :exclusive, :binary])

    try do
      IO.binwrite(file, pem)
      File.chmod!(path, 0o600)
      path
    after
      File.close(file)
    end
  end

  defp ensure_file_exists!(path, key_name) do
    unless File.regular?(path) do
      raise ArgumentError, "Temporal #{key_name} file not found: #{path}"
    end
  end

  defp put_ssl_opt(opts, _key, nil), do: opts
  defp put_ssl_opt(opts, _key, ""), do: opts
  defp put_ssl_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  @doc false
  def parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  def parse_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  def parse_non_negative_integer(_value, default), do: default
end
