defmodule NPM.Tarball do
  alias NPM.Security.RegistryPolicy

  @moduledoc """
  Download and extract npm package tarballs.

  Verifies SRI integrity and extracts contents to disk.
  """

  @max_retries 3
  @connect_timeout 30_000
  @receive_timeout 120_000

  @max_redirects 5

  @doc """
  Download a tarball, verify its integrity, and extract to a directory.

  Returns `{:ok, file_count}` or `{:error, reason}`.

  The registry auth token is only sent when the tarball URL has the same origin
  as the registry the package was resolved from (`:registry`, default
  `NPM.Config.registry/0`). Same-origin redirects are followed. A redirect to
  another origin is followed, without the `Authorization` header, only when
  that origin is an allowed registry or `NPM.Config.allow_registry_redirects?/0`
  is set; otherwise it fails with `{:error, {:redirect_blocked, url}}`.

  Downloads larger than `NPM.Config.max_tarball_bytes/0` fail with
  `{:error, {:tarball_too_large, limit}}`.
  """
  @spec fetch_and_extract(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fetch_and_extract(tarball_url, integrity, dest_dir, opts \\ []) when is_list(opts) do
    registry = Keyword.get_lazy(opts, :registry, &NPM.Config.registry/0)
    fetch_and_extract(tarball_url, integrity, dest_dir, registry, @max_retries)
  end

  defp fetch_and_extract(tarball_url, integrity, dest_dir, registry, retries_left) do
    case fetch(tarball_url, registry) do
      {:ok, %{status: 200, body: body}} ->
        with :ok <- maybe_verify_integrity(body, integrity, tarball_url) do
          extract(body, dest_dir)
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, {:permanent, reason}} ->
        {:error, reason}

      {:error, reason} when retries_left > 0 ->
        retry(tarball_url, integrity, dest_dir, registry, reason, retries_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(tarball_url, registry) do
    request(tarball_url, auth_headers(tarball_url, registry), @max_redirects)
  end

  # Credentials belong to the registry a package was resolved from; a tarball
  # hosted on any other origin is fetched anonymously.
  defp auth_headers(tarball_url, registry) do
    with origin when is_binary(origin) <- RegistryPolicy.origin(tarball_url),
         ^origin <- RegistryPolicy.origin(registry),
         token when is_binary(token) <- NPM.Config.auth_token(registry) do
      [authorization: "Bearer #{token}"]
    else
      _ -> []
    end
  end

  defp request(url, headers, redirects_left) do
    case NPM.HTTPClient.get(url, [headers: headers] ++ request_options()) do
      {:ok, %{status: status, headers: response_headers}} = response
      when status in [301, 302, 303, 307, 308] ->
        case redirect_target(url, response_headers) do
          nil -> response
          target -> follow_redirect(url, target, headers, redirects_left)
        end

      {:ok, %{status: status}} = response when status in 200..499 ->
        response

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, {:body_too_large, limit}} ->
        {:error, {:permanent, {:tarball_too_large, limit}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect_target(url, response_headers) do
    Enum.find_value(response_headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "location" and value != "",
        do: url |> URI.merge(value) |> URI.to_string()
    end)
  end

  defp follow_redirect(_url, _target, _headers, 0),
    do: {:error, {:permanent, :too_many_redirects}}

  defp follow_redirect(url, target, headers, redirects_left) do
    target_origin = RegistryPolicy.origin(target)

    cond do
      target_origin == nil ->
        {:error, {:permanent, {:redirect_blocked, target}}}

      target_origin == RegistryPolicy.origin(url) ->
        request(target, headers, redirects_left - 1)

      NPM.Config.allow_registry_redirects?() or target_origin in RegistryPolicy.allowed_origins() ->
        request(target, [], redirects_left - 1)

      true ->
        {:error, {:permanent, {:redirect_blocked, target}}}
    end
  end

  defp request_options do
    [
      decode_body: false,
      redirect: false,
      max_body_bytes: NPM.Config.max_tarball_bytes(),
      timeout: @receive_timeout,
      connect_timeout: @connect_timeout
    ]
  end

  defp retry(tarball_url, integrity, dest_dir, registry, reason, retries_left) do
    Mix.shell().error(
      "tarball fetch failed for #{tarball_url}, retrying in #{retry_delay_ms(retries_left)}ms: #{inspect(reason)}"
    )

    Process.sleep(retry_delay_ms(retries_left))
    fetch_and_extract(tarball_url, integrity, dest_dir, registry, retries_left - 1)
  end

  # npm installs entries without a recorded integrity (old lockfiles, legacy
  # packuments) without verification; mirror that, but warn. A present but
  # unusable integrity string is an error.
  defp maybe_verify_integrity(_body, integrity, tarball_url) when integrity in [nil, ""] do
    Mix.shell().error("warning: no integrity recorded for #{tarball_url}; skipping verification")
    :ok
  end

  defp maybe_verify_integrity(body, integrity, _tarball_url),
    do: verify_integrity(body, integrity)

  defp retry_delay_ms(retries_left), do: 1000 * (@max_retries - retries_left + 1)

  @supported_algorithms [
    {"sha512", :sha512},
    {"sha384", :sha384},
    {"sha256", :sha256},
    {"sha1", :sha}
  ]

  @doc """
  Verify a binary against an SRI integrity string.

  Follows npm/ssri semantics: the string may hold several space-separated
  hashes, and only the strongest supported algorithm present is checked (any
  hash of that algorithm may match). Empty, malformed, or unsupported-only
  integrity strings are rejected with `{:error, :invalid_integrity}`.
  """
  @spec verify_integrity(binary(), String.t() | nil) ::
          :ok | {:error, :integrity_mismatch | :invalid_integrity}
  def verify_integrity(body, integrity) do
    case strongest_hashes(integrity) do
      {:ok, algorithm, expected} ->
        actual = :crypto.hash(algorithm, body) |> Base.encode64()
        if actual in expected, do: :ok, else: {:error, :integrity_mismatch}

      :error ->
        {:error, :invalid_integrity}
    end
  end

  @doc """
  Whether a previously verified integrity string satisfies an expected one.

  A missing expectation is always satisfied. Otherwise `recorded` must contain
  one of the expected digests for the strongest algorithm in `expected`.
  """
  @spec integrity_satisfied?(String.t() | nil, String.t() | nil) :: boolean()
  def integrity_satisfied?(_recorded, expected) when expected in [nil, ""], do: true

  def integrity_satisfied?(recorded, expected) do
    with {:ok, algorithm, expected_digests} <- strongest_hashes(expected),
         recorded_digests when recorded_digests != [] <- digests(recorded, algorithm) do
      Enum.any?(recorded_digests, &(&1 in expected_digests))
    else
      _ -> false
    end
  end

  defp strongest_hashes(integrity) when is_binary(integrity) do
    Enum.find_value(@supported_algorithms, :error, fn {_name, algorithm} ->
      case digests(integrity, algorithm) do
        [] -> nil
        digests -> {:ok, algorithm, digests}
      end
    end)
  end

  defp strongest_hashes(_integrity), do: :error

  defp digests(integrity, algorithm) when is_binary(integrity) do
    {name, ^algorithm} = List.keyfind(@supported_algorithms, algorithm, 1)

    integrity
    |> String.split()
    |> Enum.flat_map(fn hash ->
      case String.split(hash, "-", parts: 2) do
        [^name, digest] -> digest |> String.split("?", parts: 2) |> hd() |> List.wrap()
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp digests(_integrity, _algorithm), do: []

  @doc """
  Extract a `.tgz` tarball into a destination directory.

  Strips the single top-level directory used by npm package tarballs.
  Returns `{:ok, file_count}`.

  An archive that unpacks to more than `NPM.Config.max_unpacked_bytes/0` fails
  with `{:error, {:unpacked_too_large, limit}}` before anything is written.
  """
  @spec extract(binary(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def extract(tgz_data, dest_dir) do
    limit = NPM.Config.max_unpacked_bytes()

    with {:ok, tar_data} <- inflate(tgz_data, limit),
         :ok <- check_tar_sizes(tar_data, limit, 0) do
      File.mkdir_p!(dest_dir)

      case extract_entries(tar_data) do
        {:ok, entries} ->
          modes = extract_modes(tar_data)

          with {:ok, files} <- safe_entries(entries, dest_dir) do
            write_and_chmod(files, modes)
            {:ok, length(files)}
          end

        {:error, reason} ->
          {:error, {:extract, reason}}
      end
    end
  end

  defp extract_entries(tar_data) do
    :erl_tar.extract({:binary, tar_data}, [:memory])
  rescue
    # erl_tar returns errors for malformed numeric tar fields, but its PAX
    # numeric conversions raise instead. Keep invalid archives in this API's
    # error result without catching filesystem or unrelated exceptions.
    ArgumentError -> {:error, :invalid_header}
  end

  # Inflate the gzip stream ourselves so the unpacked size is bounded while
  # decompressing; `:erl_tar` would inflate the whole archive into memory first.
  # Raw tar inputs have the same bound. Malformed gzip is never passed to an
  # unbounded fallback decompressor.
  defp inflate(<<0x1F, 0x8B, _::binary>> = data, limit) do
    zstream = :zlib.open()

    try do
      :zlib.inflateInit(zstream, 31)
      inflate_chunks(:zlib.safeInflate(zstream, data), zstream, [], 0, limit)
    rescue
      ErlangError -> {:error, {:extract, :invalid_gzip}}
    after
      :zlib.close(zstream)
    end
  end

  defp inflate(data, limit) when byte_size(data) > limit,
    do: {:error, {:unpacked_too_large, limit}}

  defp inflate(data, _limit), do: {:ok, data}

  defp inflate_chunks({status, output}, zstream, acc, size, limit) do
    size = size + IO.iodata_length(output)

    cond do
      size > limit -> {:error, {:unpacked_too_large, limit}}
      status == :finished -> finish_inflate(zstream, [acc, output])
      true -> inflate_chunks(:zlib.safeInflate(zstream, []), zstream, [acc, output], size, limit)
    end
  end

  # GNU sparse headers describe logical files much larger than their stored
  # tar data. Both :erl_tar.extract/2 and even :erl_tar.table/2 expand sparse
  # holes in memory, so check the cumulative logical sizes before either call.
  # Walk using stored sizes, including GNU's optional sparse-map blocks.
  defp check_tar_sizes(<<0::size(4096), _::binary>>, _limit, _size), do: :ok
  defp check_tar_sizes(<<>>, _limit, _size), do: :ok

  defp check_tar_sizes(<<header::binary-size(512), rest::binary>>, limit, size) do
    type = :binary.at(header, 156)

    with {:ok, stored_size} <- tar_number(binary_part(header, 124, 12)),
         stored_size = if(type in [?1, ?2, ?5], do: 0, else: stored_size),
         {:ok, logical_size} <- logical_size(header, type, stored_size) do
      if size + logical_size > limit do
        {:error, {:unpacked_too_large, limit}}
      else
        with {:ok, rest} <- skip_sparse_maps(header, type, rest),
             {:ok, tail} <- skip_tar_data(rest, stored_size) do
          check_tar_sizes(tail, limit, size + logical_size)
        end
      end
    end
  end

  defp check_tar_sizes(_truncated, _limit, _size), do: {:error, {:extract, :eof}}

  defp logical_size(header, ?S, _stored_size), do: tar_number(binary_part(header, 483, 12))
  defp logical_size(_header, _type, stored_size), do: {:ok, stored_size}

  # Tar numeric fields use octal ASCII or GNU's signed base-256 encoding.
  defp tar_number(<<1::1, value::signed-integer-size(95)>>) when value >= 0,
    do: {:ok, value}

  defp tar_number(field) do
    value = field |> :binary.split(<<0>>) |> hd() |> String.trim()

    case Integer.parse(if(value == "", do: "0", else: value), 8) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, {:extract, :invalid_header}}
    end
  end

  defp skip_sparse_maps(header, ?S, rest),
    do: skip_sparse_maps(rest, :binary.at(header, 482) != 0)

  defp skip_sparse_maps(_header, _type, rest), do: {:ok, rest}
  defp skip_sparse_maps(rest, false), do: {:ok, rest}

  defp skip_sparse_maps(<<extension::binary-size(512), rest::binary>>, true),
    do: skip_sparse_maps(rest, :binary.at(extension, 504) != 0)

  defp skip_sparse_maps(_truncated, true), do: {:error, {:extract, :eof}}

  defp skip_tar_data(data, size) do
    padded = div(size + 511, 512) * 512

    case data do
      <<_::binary-size(padded), rest::binary>> -> {:ok, rest}
      _ -> {:error, {:extract, :eof}}
    end
  end

  defp safe_entries(entries, dest_dir) do
    paths = Enum.map(entries, fn {path, _content} -> to_string(path) end)
    prefix = common_root_prefix(paths)

    Enum.reduce_while(entries, {:ok, []}, fn {path, content}, {:ok, acc} ->
      original_path = to_string(path)
      rel_path = strip_prefix(original_path, prefix)

      case safe_path(dest_dir, rel_path) do
        {:ok, full_path} -> {:cont, {:ok, [{full_path, content, original_path} | acc]}}
        {:error, reason} -> {:halt, {:error, {reason, original_path}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp safe_path(dest_dir, rel_path) do
    dest = Path.expand(dest_dir)
    full_path = Path.expand(rel_path, dest)

    cond do
      rel_path in ["", "."] ->
        {:error, :unsafe_path}

      unsafe_segments?(Path.split(rel_path)) ->
        {:error, :unsafe_path}

      not inside_dir?(full_path, dest) ->
        {:error, :unsafe_path}

      true ->
        {:ok, full_path}
    end
  end

  defp unsafe_segments?(segments), do: Enum.any?(segments, &(&1 in ["..", ""]))

  defp inside_dir?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp write_and_chmod(files, modes) do
    Enum.each(files, fn {full_path, content, original_path} ->
      write_entry(full_path, content)
      maybe_apply_mode(full_path, original_path, modes)
    end)
  end

  # `inflateEnd/1` raises unless the gzip stream ended.
  defp finish_inflate(zstream, output) do
    :zlib.inflateEnd(zstream)
    {:ok, IO.iodata_to_binary(output)}
  end

  defp extract_modes(tar_data) do
    case :erl_tar.table({:binary, tar_data}, [:verbose]) do
      {:ok, table_entries} -> Map.new(table_entries, &parse_table_entry/1)
      _ -> %{}
    end
  end

  defp parse_table_entry({path, _type, _size, _mtime, mode, _uid, _gid}),
    do: {to_string(path), mode}

  defp parse_table_entry({path, info}) when is_tuple(info),
    do: {to_string(path), :erlang.element(8, info)}

  defp parse_table_entry({path, _}),
    do: {to_string(path), nil}

  defp write_entry(full_path, content) do
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp maybe_apply_mode(_full_path, _original_path, modes) when modes == %{}, do: :ok

  defp maybe_apply_mode(full_path, original_path, modes) do
    case Map.get(modes, original_path) do
      mode when is_integer(mode) and :erlang.band(mode, 0o111) != 0 ->
        File.chmod(full_path, :erlang.band(mode, 0o777))

      _ ->
        :ok
    end
  end

  defp common_root_prefix([]), do: nil

  defp common_root_prefix(paths) do
    roots =
      Enum.map(paths, fn path ->
        case String.split(path, "/", parts: 2) do
          [root, rest] when root not in ["", ".", ".."] and rest != "" -> root
          _ -> nil
        end
      end)

    case Enum.uniq(roots) do
      [root] when is_binary(root) -> root <> "/"
      _ -> nil
    end
  end

  defp strip_prefix(path, nil), do: path
  defp strip_prefix(path, prefix), do: String.replace_prefix(path, prefix, "")
end
