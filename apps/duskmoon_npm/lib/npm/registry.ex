defmodule NPM.Registry do
  alias NPM.Security.RegistryPolicy

  @moduledoc """
  HTTP client for the npm registry.

  Fetches abbreviated packuments (version list + deps + dist info)
  using the npm registry API.
  """

  @max_retries 3
  @connect_timeout 30_000
  @receive_timeout 120_000

  @type packument :: %{
          name: String.t(),
          versions: %{String.t() => version_info()}
        }

  @type version_info :: %{
          dependencies: %{String.t() => String.t()},
          optional_dependencies: %{String.t() => String.t()},
          peer_dependencies: %{String.t() => String.t()},
          peer_dependencies_meta: %{String.t() => map()},
          bin: %{optional(String.t()) => String.t()},
          engines: %{String.t() => String.t()},
          os: [String.t()],
          cpu: [String.t()],
          has_install_script: boolean(),
          deprecated: String.t() | nil,
          created_at: String.t() | nil,
          published_at: String.t() | nil,
          dist: %{
            tarball: String.t(),
            integrity: String.t(),
            file_count: integer() | nil,
            unpacked_size: integer() | nil
          }
        }

  @doc "Get the configured registry URL."
  @spec registry_url :: String.t()
  def registry_url do
    NPM.Config.registry()
  end

  @doc """
  Fetch package metadata, including publication timestamps when age warnings
  are enabled. With both age thresholds set to zero, request the smaller
  abbreviated packument instead. Enabling age warnings upgrades abbreviated or
  legacy cached metadata once; successful full requests retain the normal TTL
  even when a private registry does not provide publication timestamps.
  """
  @spec get_packument(String.t()) :: {:ok, packument()} | {:error, term()}
  def get_packument(package) do
    registry = NPM.Config.registry_for(package)
    full? = NPM.Config.package_age_warning_days() > 0 or NPM.Config.version_age_warning_days() > 0

    case NPM.PackumentCache.get(package, registry, full: full?) do
      {:ok, packument} ->
        {:ok, normalize_packument(packument, package)}

      _missing_metadata ->
        fetch_packument(package, registry, full?)
    end
  end

  defp fetch_packument(package, registry, full?) do
    url = "#{registry}/#{encode_package(package)}"
    accept = if full?, do: "application/json", else: "application/vnd.npm.install-v1+json"
    headers = auth_headers(registry) ++ [accept: accept]
    fetch_with_retry({package, registry, full?}, url, headers, @max_retries)
  end

  defp fetch_with_retry({package, registry, full?} = source, url, headers, retries_left) do
    RegistryPolicy.validate_url!(url)

    result =
      NPM.HTTPClient.get(
        url,
        Keyword.merge(
          [
            headers: headers,
            decode_body: false,
            redirect: NPM.Config.allow_registry_redirects?()
          ],
          request_options()
        )
      )

    case classify_result(result) do
      {:ok, body} ->
        packument = body |> decode_body() |> parse_packument(package)
        NPM.PackumentCache.put(package, packument, registry, full: full?)
        {:ok, packument}

      {:retry, _} when retries_left > 0 ->
        retry(source, url, headers, retries_left)

      {_, error} ->
        error
    end
  end

  defp request_options do
    [timeout: @receive_timeout, connect_timeout: @connect_timeout]
  end

  defp classify_result({:ok, %{status: 200, body: body}}), do: {:ok, body}
  defp classify_result({:ok, %{status: 404}}), do: {:error, {:error, :not_found}}
  defp classify_result({:ok, %{status: 401}}), do: {:error, {:error, :unauthorized}}
  defp classify_result({:ok, %{status: 403}}), do: {:error, {:error, :forbidden}}
  defp classify_result({:ok, %{status: s}}) when s >= 500, do: {:retry, {:error, {:http, s}}}
  defp classify_result({:ok, %{status: s}}), do: {:error, {:error, {:http, s}}}
  defp classify_result({:error, reason}), do: {:retry, {:error, reason}}

  defp retry(source, url, headers, retries_left) do
    Process.sleep(1000 * (@max_retries - retries_left + 1))
    fetch_with_retry(source, url, headers, retries_left - 1)
  end

  # The token is selected for the registry actually being contacted, so a
  # scope registry never receives another registry's credentials.
  defp auth_headers(registry) do
    case NPM.Config.auth_token(registry) do
      nil -> []
      token -> [authorization: "Bearer #{token}"]
    end
  end

  @doc "URL-encode a package name (handles scoped packages)."
  @spec encode_package(String.t()) :: String.t()
  def encode_package(package), do: String.replace(package, "/", "%2f")

  defp decode_body(body) when is_binary(body), do: NPM.JSON.decode!(body)
  defp decode_body(body) when is_map(body), do: body

  defp parse_packument(data, package) do
    name = Map.get(data, "name", "")
    times = Map.get(data, "time", %{})
    policy = tarball_policy(package)

    versions =
      for {version_str, info} <- Map.get(data, "versions", %{}), into: %{} do
        {version_str, parse_version_info(name, version_str, info, times, policy)}
      end

    %{name: name, versions: versions, dist_tags: parse_dist_tags(data)}
  end

  defp parse_dist_tags(%{"dist-tags" => tags}) when is_map(tags) do
    for {tag, version} <- tags,
        is_binary(tag) and is_binary(version),
        into: %{},
        do: {tag, version}
  end

  defp parse_dist_tags(_data), do: %{}

  defp parse_version_info(name, version, info, times, policy) do
    dist = Map.get(info, "dist", %{})
    tarball = Map.get(dist, "tarball", "")
    integrity = dist_integrity(dist)

    %{
      dependencies: Map.get(info, "dependencies", %{}),
      peer_dependencies: Map.get(info, "peerDependencies", %{}),
      peer_dependencies_meta: Map.get(info, "peerDependenciesMeta", %{}),
      optional_dependencies: Map.get(info, "optionalDependencies", %{}),
      bin: parse_bin(info),
      engines: Map.get(info, "engines", %{}),
      os: Map.get(info, "os", []),
      cpu: Map.get(info, "cpu", []),
      has_install_script: Map.get(info, "hasInstallScript", false),
      deprecated: Map.get(info, "deprecated", nil),
      created_at: Map.get(times, "created"),
      published_at: Map.get(times, version),
      dist: %{
        tarball: normalized_tarball_url(name, version, tarball, integrity, policy),
        integrity: integrity,
        file_count: Map.get(dist, "fileCount"),
        unpacked_size: Map.get(dist, "unpackedSize")
      }
    }
  end

  # Old packuments only carry a hex sha1 `shasum`; npm converts it to SRI.
  defp dist_integrity(%{"integrity" => integrity}) when is_binary(integrity) and integrity != "",
    do: integrity

  defp dist_integrity(%{"shasum" => shasum}) when is_binary(shasum) do
    case Base.decode16(shasum, case: :mixed) do
      {:ok, digest} when byte_size(digest) == 20 -> "sha1-" <> Base.encode64(digest)
      _ -> ""
    end
  end

  defp dist_integrity(_dist), do: ""

  defp parse_bin(%{"bin" => bin}) when is_map(bin), do: bin
  defp parse_bin(%{"bin" => bin}) when is_binary(bin), do: %{}
  defp parse_bin(_), do: %{}

  @doc false
  @spec __normalized_tarball_url__(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def __normalized_tarball_url__(name, version, tarball, integrity) do
    normalized_tarball_url(name, version, tarball, integrity, tarball_policy(name))
  end

  defp normalize_packument(%{name: name, versions: versions} = packument, package)
       when is_map(versions) do
    policy = tarball_policy(package)

    versions =
      Map.new(versions, fn {version, info} ->
        {version, normalize_version_info(name, version, info, policy)}
      end)

    %{packument | versions: versions}
  end

  defp normalize_packument(packument, _package), do: packument

  # Registry policy for one requested package, read once rather than once per
  # version: the allowed origins, and the registry untrusted tarball URLs are
  # rewritten to (the package's scope registry when configured, else the first
  # allowed registry).
  defp tarball_policy(package) do
    registries = NPM.Config.allowed_registries()

    %{
      origins: registries |> Enum.map(&RegistryPolicy.origin/1) |> Enum.reject(&is_nil/1),
      registry: NPM.Config.scope_registry(package) || List.first(registries)
    }
  end

  defp normalize_version_info(name, version, %{dist: %{tarball: tarball} = dist} = info, policy) do
    integrity = Map.get(dist, :integrity, "")
    tarball = normalized_tarball_url(name, version, tarball, integrity, policy)
    Map.put(info, :dist, Map.put(dist, :tarball, tarball))
  end

  defp normalize_version_info(
         name,
         version,
         %{"dist" => %{"tarball" => tarball} = dist} = info,
         policy
       ) do
    integrity = Map.get(dist, "integrity", "")
    tarball = normalized_tarball_url(name, version, tarball, integrity, policy)
    Map.put(info, "dist", Map.put(dist, "tarball", tarball))
  end

  defp normalize_version_info(_name, _version, info, _policy), do: info

  defp normalized_tarball_url(_name, _version, tarball, _integrity, _policy)
       when tarball in [nil, ""],
       do: tarball || ""

  defp normalized_tarball_url(name, version, tarball, integrity, policy) do
    cond do
      RegistryPolicy.origin(tarball) in policy.origins ->
        tarball

      integrity in [nil, ""] ->
        tarball

      is_binary(policy.registry) ->
        NPM.Registry.URL.tarball_url(name, version, policy.registry)

      true ->
        RegistryPolicy.validate_url!(tarball)
        tarball
    end
  end
end
