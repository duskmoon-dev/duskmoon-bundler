defmodule NPM.Tarball do
  @moduledoc """
  Download and extract npm package tarballs.

  Verifies SRI integrity and extracts contents to disk.
  """

  @max_retries 3
  @connect_timeout 30_000
  @receive_timeout 120_000

  @doc """
  Download a tarball, verify its integrity, and extract to a directory.

  Returns `{:ok, file_count}` or `{:error, reason}`.
  """
  @spec fetch_and_extract(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fetch_and_extract(tarball_url, integrity, dest_dir) do
    fetch_and_extract(tarball_url, integrity, dest_dir, @max_retries)
  end

  defp fetch_and_extract(tarball_url, integrity, dest_dir, retries_left) do
    case fetch(tarball_url) do
      {:ok, %{status: 200, body: body}} ->
        with :ok <- maybe_verify_integrity(body, integrity, tarball_url) do
          extract(body, dest_dir)
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} when retries_left > 0 ->
        retry(tarball_url, integrity, dest_dir, reason, retries_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(tarball_url) do
    case NPM.HTTPClient.get(tarball_url, request_options()) do
      {:ok, %{status: status}} = response when status in 200..499 ->
        response

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_options do
    [decode_body: false, timeout: @receive_timeout, connect_timeout: @connect_timeout]
  end

  defp retry(tarball_url, integrity, dest_dir, reason, retries_left) do
    Mix.shell().error(
      "tarball fetch failed for #{tarball_url}, retrying in #{retry_delay_ms(retries_left)}ms: #{inspect(reason)}"
    )

    Process.sleep(retry_delay_ms(retries_left))
    fetch_and_extract(tarball_url, integrity, dest_dir, retries_left - 1)
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
  """
  @spec extract(binary(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def extract(tgz_data, dest_dir) do
    File.mkdir_p!(dest_dir)

    case :erl_tar.extract({:binary, tgz_data}, [:compressed, :memory]) do
      {:ok, entries} ->
        modes = extract_modes(tgz_data)

        with {:ok, files} <- safe_entries(entries, dest_dir) do
          write_and_chmod(files, modes)
          {:ok, length(files)}
        end

      {:error, reason} ->
        {:error, {:extract, reason}}
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

  defp extract_modes(tgz_data) do
    case :erl_tar.table({:binary, tgz_data}, [:compressed, :verbose]) do
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
