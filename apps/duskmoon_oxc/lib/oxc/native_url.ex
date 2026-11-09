defmodule OXC.NativeURL do
  @moduledoc false

  # Kept in each native package so standalone Hex consumers need no new dependency.
  @base_url "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{Mix.Project.config()[:version]}"
  @max_header_size 65_536
  @max_attempts 4
  @github_api "https://api.github.com"
  @retry_base_ms 250

  def url(filename), do: resolve(@base_url <> "/" <> filename)

  # `api` is only overridden by tests; other hosts never use the API fallback.
  def resolve(url, api \\ nil) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    case :inets.start(:httpc, profile: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {proxy_options, proxy_auth} = proxy_options()
    :ok = :httpc.set_options(proxy_options, __MODULE__)

    trust =
      case System.get_env("HEX_CACERTS_PATH") do
        nil -> [cacerts: :public_key.cacerts_get()]
        path -> [cacertfile: String.to_charlist(path)]
      end

    http_options = [
      autoredirect: false,
      timeout: 15_000,
      connect_timeout: 15_000,
      ssl:
        [
          verify: :verify_peer,
          depth: 4,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ trust
    ]

    http_options =
      if proxy_auth, do: [{:proxy_auth, proxy_auth} | http_options], else: http_options

    api = api || if(URI.parse(url).host == "github.com", do: @github_api)
    request(url, http_options, api, 0)
  end

  # GitHub's release-download route intermittently returns a 5xx that sticks to
  # one exact asset URL (#20, #22). Retry with backoff, alternating to the
  # `?download=1` variant, then resolve the same immutable asset through the
  # REST API asset route. rustler/zigler precompiled still verify the downloaded
  # bytes against the packaged checksums.
  defp attempt_url(url, attempt) when rem(attempt, 2) == 1 do
    case URI.parse(url) do
      %URI{query: nil} = uri -> URI.to_string(%{uri | query: "download=1"})
      _ -> url
    end
  end

  defp attempt_url(url, _attempt), do: url

  defp request(url, http_options, api, attempt) do
    target_url = attempt_url(url, attempt)

    case head(target_url, [], http_options) do
      {:ok, {{_, status, _}, headers, _}} when status in [301, 302, 303, 307, 308] ->
        redirect_target!(target_url, headers)

      {:ok, {{_, 200, _}, _, _}} ->
        target_url

      {:ok, {{_, status, _}, _, _}} when status >= 500 ->
        retry_or_fallback(url, http_options, api, attempt, "HTTP #{status}")

      {:ok, {{_, status, _}, _, _}} ->
        raise "Native artifact redirect returned HTTP #{status}"

      {:error, reason} ->
        retry_or_fallback(url, http_options, api, attempt, inspect(reason))
    end
  end

  defp retry_or_fallback(url, http_options, api, attempt, _failure)
       when attempt + 1 < @max_attempts do
    Process.sleep(@retry_base_ms * Integer.pow(2, attempt))
    request(url, http_options, api, attempt + 1)
  end

  defp retry_or_fallback(url, http_options, api, _attempt, failure) do
    with api when is_binary(api) <- api,
         %URI{path: path, query: nil} <- URI.parse(url),
         [_, owner, repo, tag, name] <-
           Regex.run(~r{\A/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)\z}, path || "") do
      api_resolve(api, owner, repo, URI.decode(tag), URI.decode(name), http_options, failure)
    else
      _ -> raise native_failure(failure)
    end
  end

  defp native_failure("HTTP " <> _ = failure), do: "Native artifact redirect returned #{failure}"
  defp native_failure(failure), do: "Native artifact redirect failed: #{failure}"

  defp api_resolve(api, owner, repo, tag, name, http_options, failure) do
    release_url = "#{api}/repos/#{owner}/#{repo}/releases/tags/#{URI.encode(tag)}"
    asset_url = release_assets(release_url, http_options) |> Map.get(name)

    with asset_url when is_binary(asset_url) <- asset_url,
         true <- String.starts_with?(asset_url, api <> "/"),
         {:ok, {{_, status, _}, response_headers, _}} when status in [301, 302, 303, 307, 308] <-
           head(asset_url, [{~c"accept", ~c"application/octet-stream"}], http_options) do
      redirect_target!(asset_url, response_headers)
    else
      _ -> raise native_failure(failure) <> "; GitHub API asset fallback was unavailable"
    end
  end

  # One release lookup per process keeps the unauthenticated API budget for
  # the per-asset redirects when several NIFs fall back during one compile.
  defp release_assets(release_url, http_options) do
    key = {__MODULE__, :release_assets, release_url}

    case :persistent_term.get(key, nil) do
      nil ->
        headers = [{~c"accept", ~c"application/vnd.github+json"} | api_headers()]

        case :httpc.request(
               :get,
               {String.to_charlist(release_url), headers},
               http_options,
               [body_format: :binary, max_header_size: @max_header_size],
               __MODULE__
             ) do
          {:ok, {{_, 200, _}, _, body}} ->
            assets =
              for %{"name" => name, "url" => url} <- Map.get(JSON.decode!(body), "assets", []),
                  is_binary(name) and is_binary(url),
                  into: %{},
                  do: {name, url}

            :persistent_term.put(key, assets)
            assets

          _ ->
            %{}
        end

      assets ->
        assets
    end
  end

  defp api_headers, do: [{~c"user-agent", ~c"duskmoon-native-url"}]

  defp head(url, headers, http_options) do
    :httpc.request(
      :head,
      {String.to_charlist(url), headers ++ api_headers()},
      http_options,
      [body_format: :binary, max_header_size: @max_header_size],
      __MODULE__
    )
  end

  defp redirect_target!(url, headers) do
    case List.keyfind(headers, ~c"location", 0) do
      {_, location} ->
        target = URI.merge(url, to_string(location))

        if target.scheme not in ["http", "https"] or not is_nil(target.userinfo) or
             (URI.parse(url).scheme == "https" and target.scheme != "https") do
          raise "Unsafe native artifact redirect"
        end

        URI.to_string(target)

      nil ->
        raise "Native artifact redirect has no Location header"
    end
  end

  defp proxy_options do
    no_proxy =
      (System.get_env("NO_PROXY") || System.get_env("no_proxy") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&(String.trim(&1) |> String.trim_leading(".") |> String.to_charlist()))

    proxies =
      for {option, upper, lower} <- [
            {:proxy, "HTTP_PROXY", "http_proxy"},
            {:https_proxy, "HTTPS_PROXY", "https_proxy"}
          ],
          value = System.get_env(upper) || System.get_env(lower),
          not is_nil(value) do
        case URI.parse(value) do
          %URI{host: host, port: port, userinfo: userinfo}
          when is_binary(host) and is_integer(port) ->
            {option, {{String.to_charlist(host), port}, no_proxy}, userinfo}

          _ ->
            raise "Invalid #{upper} for native artifacts"
        end
      end

    auth =
      proxies
      |> Enum.reverse()
      |> Enum.find_value(fn {_, _, userinfo} ->
        case userinfo && String.split(userinfo, ":", parts: 2) do
          nil ->
            nil

          [user] ->
            {String.to_charlist(URI.decode(user)), ~c""}

          [user, password] ->
            {String.to_charlist(URI.decode(user)), String.to_charlist(URI.decode(password))}
        end
      end)

    family =
      case System.get_env("RUSTLER_PRECOMPILED_IPFAMILY") do
        value when value in [nil, "inet"] -> :inet
        "inet6" -> :inet6
        "inet6fb4" -> :inet6fb4
        _ -> raise "Invalid RUSTLER_PRECOMPILED_IPFAMILY for native artifacts"
      end

    {[{:ipfamily, family} | Enum.map(proxies, fn {key, value, _} -> {key, value} end)], auth}
  end
end
