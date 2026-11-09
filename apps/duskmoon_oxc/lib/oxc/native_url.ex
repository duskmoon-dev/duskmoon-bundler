defmodule OXC.NativeURL do
  @moduledoc false

  # Kept in each native package so standalone Hex consumers need no new dependency.
  @base_url "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{Mix.Project.config()[:version]}"
  @max_header_size 65_536
  @max_attempts 6
  @retry_base_ms 250

  def url(filename), do: resolve(@base_url <> "/" <> filename)

  def resolve(url) do
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

    request(url, http_options, 0)
  end

  # GitHub's release-download route intermittently returns a sticky 5xx for one
  # exact URL while the same asset resolves with an extra query parameter.
  # Retry with backoff, alternating to that variant; rustler/zigler precompiled
  # still verify the downloaded bytes against the packaged checksums.
  defp attempt_url(url, attempt) when rem(attempt, 2) == 1 do
    case URI.parse(url) do
      %URI{query: nil} = uri -> URI.to_string(%{uri | query: "download=1"})
      _ -> url
    end
  end

  defp attempt_url(url, _attempt), do: url

  defp retry(url, http_options, attempt) do
    Process.sleep(@retry_base_ms * Integer.pow(2, attempt))
    request(url, http_options, attempt + 1)
  end

  defp request(url, http_options, attempt) do
    target_url = attempt_url(url, attempt)

    response =
      :httpc.request(
        :head,
        {String.to_charlist(target_url), []},
        http_options,
        [body_format: :binary, max_header_size: @max_header_size],
        __MODULE__
      )

    case response do
      {:ok, {{_, status, _}, headers, _}} when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, ~c"location", 0) do
          {_, location} ->
            target = URI.merge(target_url, to_string(location))

            if target.scheme not in ["http", "https"] or not is_nil(target.userinfo) or
                 (URI.parse(target_url).scheme == "https" and target.scheme != "https") do
              raise "Unsafe native artifact redirect"
            end

            URI.to_string(target)

          nil ->
            raise "Native artifact redirect has no Location header"
        end

      {:ok, {{_, 200, _}, _, _}} ->
        target_url

      {:ok, {{_, status, _}, _, _}} when status >= 500 and attempt + 1 < @max_attempts ->
        retry(url, http_options, attempt)

      {:ok, {{_, status, _}, _, _}} ->
        raise "Native artifact redirect returned HTTP #{status}"

      {:error, _reason} when attempt + 1 < @max_attempts ->
        retry(url, http_options, attempt)

      {:error, reason} ->
        raise "Native artifact redirect failed: #{inspect(reason)}"
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
