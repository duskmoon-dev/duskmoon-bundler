defmodule NPM.TarballSizeTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    env = System.get_env("NPM_EX_MAX_UNPACKED_BYTES")
    limit = Application.get_env(:duskmoon_npm, :max_unpacked_bytes)
    System.delete_env("NPM_EX_MAX_UNPACKED_BYTES")

    on_exit(fn ->
      if env,
        do: System.put_env("NPM_EX_MAX_UNPACKED_BYTES", env),
        else: System.delete_env("NPM_EX_MAX_UNPACKED_BYTES")

      if limit,
        do: Application.put_env(:duskmoon_npm, :max_unpacked_bytes, limit),
        else: Application.delete_env(:duskmoon_npm, :max_unpacked_bytes)
    end)
  end

  test "checks raw tar size before the uncompressed fallback can extract", %{tmp_dir: dir} do
    tar = ordinary_tar(dir, :binary.copy("x", 20_000))
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 10_000)
    dest = Path.join(dir, "dest")

    assert {:error, {:unpacked_too_large, 10_000}} = NPM.Tarball.extract(tar, dest)
    refute File.exists?(dest)
  end

  test "still extracts bounded raw tar archives", %{tmp_dir: dir} do
    tar = ordinary_tar(dir, "raw data")
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, byte_size(tar))
    dest = Path.join(dir, "dest")

    assert {:ok, 1} = NPM.Tarball.extract(tar, dest)
    assert File.read!(Path.join(dest, "data")) == "raw data"
  end

  test "rejects truncated gzip without falling back to unbounded decompression", %{tmp_dir: dir} do
    gzip = ordinary_tar(dir, "data") |> :zlib.gzip()
    truncated = binary_part(gzip, 0, byte_size(gzip) - 8)
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 100_000)
    dest = Path.join(dir, "dest")

    assert {:error, {:extract, :invalid_gzip}} = NPM.Tarball.extract(truncated, dest)
    refute File.exists?(dest)
  end

  test "bounds sparse logical sizes before memory extraction", %{tmp_dir: dir} do
    tar = sparse_tar([{"package/sparse", 1_000_001, false}])
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 20_000)

    for {archive, name} <- [{tar, "raw"}, {:zlib.gzip(tar), "gzip"}] do
      dest = Path.join(dir, name)
      assert {:error, {:unpacked_too_large, 20_000}} = NPM.Tarball.extract(archive, dest)
      refute File.exists?(dest)
    end
  end

  test "bounds the total logical size across sparse entries", %{tmp_dir: dir} do
    tar = sparse_tar([{"package/one", 60_001, false}, {"package/two", 60_001, false}])
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 100_000)
    dest = Path.join(dir, "dest")

    assert {:error, {:unpacked_too_large, 100_000}} = NPM.Tarball.extract(:zlib.gzip(tar), dest)
    refute File.exists?(dest)
  end

  test "bounds GNU base-256 logical size fields too", %{tmp_dir: dir} do
    tar = sparse_tar([{"package/sparse", 1_000_001, false}], :base256)
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 20_000)
    dest = Path.join(dir, "dest")

    assert {:error, {:unpacked_too_large, 20_000}} = NPM.Tarball.extract(:zlib.gzip(tar), dest)
    refute File.exists?(dest)
  end

  test "supports bounded sparse archives including extended maps", %{tmp_dir: dir} do
    tar = sparse_tar([{"package/one", 60_001, true}, {"package/two", 2, false}])
    Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 100_000)
    dest = Path.join(dir, "dest")

    assert {:ok, 2} = NPM.Tarball.extract(:zlib.gzip(tar), dest)
    assert File.stat!(Path.join(dest, "one")).size == 60_001
    assert :binary.last(File.read!(Path.join(dest, "one"))) == ?X
    assert File.read!(Path.join(dest, "two")) == <<0, ?X>>
  end

  for field <- ~w(size uid gid mtime) do
    test "returns an error for malformed PAX #{field} instead of raising", %{tmp_dir: dir} do
      tar = pax_tar(dir, unquote(field), "not-a-number")
      Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 20_000)
      dest = Path.join(dir, "dest")

      assert {:error, {:extract, :invalid_header}} = NPM.Tarball.extract(:zlib.gzip(tar), dest)
      assert File.ls!(dest) == []
    end
  end

  defp ordinary_tar(dir, content) do
    path = Path.join(dir, "ordinary.tar")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"package/data", content}], [])
    File.read!(path)
  end

  defp pax_tar(dir, key, value) do
    tar = ordinary_tar(dir, "X")
    <<header::binary-size(512), _::binary>> = tar
    record = pax_record(key <> "=" <> value <> "\n", 1)

    header =
      header
      |> put(124, octal(byte_size(record), 12))
      |> put(148, "        ")
      |> put(156, "x")

    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    header = put(header, 148, octal(checksum, 7) <> " ")
    padding = :binary.copy(<<0>>, rem(512 - rem(byte_size(record), 512), 512))
    IO.iodata_to_binary([header, record, padding, tar])
  end

  defp pax_record(line, size) do
    expected = byte_size(Integer.to_string(size)) + 1 + byte_size(line)

    if size == expected,
      do: Integer.to_string(size) <> " " <> line,
      else: pax_record(line, expected)
  end

  # An old GNU sparse header describes one byte at the end of the logical
  # file. Nothing proportional to the logical size is allocated by the writer.
  defp sparse_tar(entries, size_encoding \\ :octal) do
    entries
    |> Enum.map(fn {name, size, extended?} ->
      sparse_entry = octal(size - 1, 12) <> octal(1, 12)

      header =
        :binary.copy(<<0>>, 512)
        |> put(0, name)
        |> put(100, "0000644\0")
        |> put(108, "0000000\0")
        |> put(116, "0000000\0")
        |> put(124, octal(1, 12))
        |> put(136, octal(0, 12))
        |> put(148, "        ")
        |> put(156, "S")
        |> put(257, "ustar  \0")
        |> put(386, if(extended?, do: :binary.copy(<<0>>, 24), else: sparse_entry))
        |> put(482, if(extended?, do: <<1>>, else: <<0>>))
        |> put(483, sparse_size(size, size_encoding))

      checksum = header |> :binary.bin_to_list() |> Enum.sum()
      header = put(header, 148, octal(checksum, 7) <> " ")
      extension = if extended?, do: put(:binary.copy(<<0>>, 512), 0, sparse_entry), else: ""
      [header, extension, "X", :binary.copy(<<0>>, 511)]
    end)
    |> Kernel.++([:binary.copy(<<0>>, 1024)])
    |> IO.iodata_to_binary()
  end

  defp sparse_size(size, :octal), do: octal(size, 12)
  defp sparse_size(size, :base256), do: <<1::1, size::signed-integer-size(95)>>

  defp octal(value, size),
    do: String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> <<0>>

  defp put(binary, offset, replacement) do
    <<prefix::binary-size(offset), _old::binary-size(byte_size(replacement)), rest::binary>> =
      binary

    prefix <> replacement <> rest
  end
end
