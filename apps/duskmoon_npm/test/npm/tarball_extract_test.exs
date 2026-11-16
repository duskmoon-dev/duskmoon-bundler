defmodule NPM.TarballExtractTest do
  use ExUnit.Case, async: true

  alias NPM.Tarball

  @moduletag :tmp_dir

  # Layout: tmp/root/dest is the extraction target, so "../.." style escapes
  # still land inside the ExUnit tmp dir, where the tests can look for them.
  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    dest = Path.join(root, "dest")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "victim.txt"), "original")

    {:ok, dest: dest, outside: outside, root: root}
  end

  # Minimal ustar writer: `:erl_tar` cannot produce hard links or hostile names.
  defp tgz(entries) do
    entries
    |> Enum.map(&tar_entry/1)
    |> Kernel.++([<<0::size(1024 * 8)>>])
    |> IO.iodata_to_binary()
    |> :zlib.gzip()
  end

  defp tar_entry({:file, name, content}),
    do: [header(name, ?0, "", byte_size(content)), pad(content)]

  defp tar_entry({:symlink, name, target}), do: header(name, ?2, target, 0)
  defp tar_entry({:hardlink, name, target}), do: header(name, ?1, target, 0)

  defp header(name, type, linkname, size) do
    {prefix, name} = split_name(name)

    fields = [
      field(name, 100),
      "0000644\0",
      "0000000\0",
      "0000000\0",
      octal(size, 11) <> "\0",
      "00000000000\0",
      "        ",
      <<type>>,
      field(linkname, 100),
      "ustar\0",
      "00",
      field("", 32),
      field("", 32),
      "0000000\0",
      "0000000\0",
      field(prefix, 155),
      field("", 12)
    ]

    header = IO.iodata_to_binary(fields)
    512 = byte_size(header)
    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    <<before::binary-size(148), _::binary-size(8), rest::binary>> = header
    before <> octal(checksum, 6) <> "\0 " <> rest
  end

  # Long names use the ustar prefix field (`prefix/name`).
  defp split_name(name) when byte_size(name) <= 100, do: {"", name}

  defp split_name(name) do
    segments = Path.split(name)
    {prefix, rest} = Enum.split(segments, length(segments) - 2)
    {Path.join(prefix), Path.join(rest)}
  end

  defp field(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))
  defp octal(value, width), do: value |> Integer.to_string(8) |> String.pad_leading(width, "0")

  defp pad(content) do
    case rem(byte_size(content), 512) do
      0 -> content
      remainder -> content <> :binary.copy(<<0>>, 512 - remainder)
    end
  end

  defp files_under(dir) do
    dir |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.reject(&File.dir?/1)
  end

  defp assert_nothing_escaped(context) do
    assert File.read!(Path.join(context.outside, "victim.txt")) == "original"
    assert File.ls!(context.outside) == ["victim.txt"]
    assert File.ls!(context.root) -- ["dest"] == []
    assert File.ls!(context.tmp_dir) |> Enum.sort() == ["outside", "root"]
  end

  test "extracts an ordinary archive built by the helper", %{dest: dest} do
    archive = tgz([{:file, "package/package.json", "{}"}, {:file, "package/lib/a.js", "a"}])

    assert {:ok, 2} = Tarball.extract(archive, dest)
    assert File.read!(Path.join(dest, "lib/a.js")) == "a"
  end

  for name <- [
        "package/../../x",
        "package/../x",
        "package/lib/../../../x",
        "../x",
        "package/..",
        "package/a/../../../outside/victim.txt"
      ] do
    test "rejects the traversal path #{name}", %{dest: dest} = context do
      archive = tgz([{:file, "package/package.json", "{}"}, {:file, unquote(name), "pwned"}])

      assert {:error, _reason} = Tarball.extract(archive, dest)
      assert files_under(dest) == []
      assert_nothing_escaped(context)
    end
  end

  test "rejects an absolute path", %{dest: dest, outside: outside} = context do
    absolute = Path.join(outside, "absolute.txt")
    archive = tgz([{:file, "package/package.json", "{}"}, {:file, absolute, "pwned"}])

    assert {:error, _reason} = Tarball.extract(archive, dest)
    assert files_under(dest) == []
    assert_nothing_escaped(context)
  end

  test "never writes through a symlink entry", %{dest: dest} = context do
    archive =
      tgz([
        {:file, "package/package.json", "{}"},
        {:symlink, "package/link", "../../outside"},
        {:file, "package/link/pwned.txt", "pwned"},
        {:symlink, "package/victim-link", "../../outside/victim.txt"},
        {:file, "package/victim-link", "pwned"}
      ])

    result = Tarball.extract(archive, dest)

    assert_nothing_escaped(context)

    # Whether the archive is rejected or the link entries are dropped, no
    # symlink may exist in the extracted tree.
    case result do
      {:ok, _count} ->
        for path <- Path.wildcard(Path.join(dest, "**"), match_dot: true) do
          refute match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)), path
        end

      {:error, _reason} ->
        :ok
    end
  end

  test "never creates a hard link to a file outside the package",
       %{dest: dest, outside: outside} = context do
    victim = Path.join(outside, "victim.txt")

    archive =
      tgz([
        {:file, "package/package.json", "{}"},
        {:hardlink, "package/hard", "../../outside/victim.txt"},
        {:hardlink, "package/hard2", "package/../../../outside/victim.txt"},
        {:file, "package/hard", "pwned"}
      ])

    result = Tarball.extract(archive, dest)

    assert_nothing_escaped(context)
    assert File.stat!(victim).links == 1

    case result do
      {:ok, _count} -> assert File.stat!(Path.join(dest, "hard")).links == 1
      {:error, _reason} -> :ok
    end
  end

  test "extracts archives created by :erl_tar that contain a symlink",
       %{
         tmp_dir: tmp_dir,
         dest: dest,
         outside: outside
       } = context do
    src = Path.join([tmp_dir, "root", "src"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "index.js"), "ok")
    File.ln_s!(outside, Path.join(src, "link"))
    archive_path = Path.join([tmp_dir, "root", "pkg.tgz"])

    :ok =
      :erl_tar.create(
        String.to_charlist(archive_path),
        [
          {~c"package/index.js", String.to_charlist(Path.join(src, "index.js"))},
          {~c"package/link", String.to_charlist(Path.join(src, "link"))}
        ],
        [:compressed]
      )

    archive = File.read!(archive_path)
    File.rm_rf!(src)
    File.rm!(archive_path)

    result = Tarball.extract(archive, dest)
    assert_nothing_escaped(context)

    case result do
      {:ok, _count} ->
        refute match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(dest, "link")))

      {:error, _reason} ->
        :ok
    end
  end
end
