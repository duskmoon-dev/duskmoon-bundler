# Bootstrap this third-party NIF without changing its immutable Hex package.
# ElixirMake's downloader discards header-limit errors and falls back to make.
Mix.start()

Mix.Project.in_project(:lazy_html, "deps/lazy_html", fn _ ->
  config = Mix.Project.config()

  {:ok, target, nif_version, url} =
    ElixirMake.Artefact.current_target_url(
      config,
      CCPrecompiler,
      to_string(:erlang.system_info(:nif_version))
    )

  archive = ElixirMake.Artefact.archive_path(config, target, nif_version)
  filename = Path.basename(archive)
  {checksums, _} = Code.eval_file("checksum.exs")
  "sha256:" <> checksum = Map.fetch!(checksums, filename)
  {:ok, _} = Application.ensure_all_started(:inets)
  {:ok, _} = Application.ensure_all_started(:ssl)

  trust =
    case System.get_env("HEX_CACERTS_PATH") do
      nil -> [cacerts: :public_key.cacerts_get()]
      path -> [cacertfile: String.to_charlist(path)]
    end

  options = [
    timeout: 30_000,
    connect_timeout: 15_000,
    ssl:
      [
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ trust
  ]

  body =
    case :httpc.request(:get, {String.to_charlist(url), []}, options,
           body_format: :binary,
           max_header_size: 65_536
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        body

      {:ok, {{_, status, _}, _, _}} ->
        raise "lazy_html precompiled download returned HTTP #{status}"

      {:error, reason} ->
        raise "lazy_html precompiled download failed: #{inspect(reason)}"
    end

  unless Base.encode16(:crypto.hash(:sha256, body), case: :lower) == checksum,
    do: raise("lazy_html precompiled checksum mismatch")

  File.write!(archive, body)
  IO.puts("Verified lazy_html precompiled archive: #{filename}")
end)
