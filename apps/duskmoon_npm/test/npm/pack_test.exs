defmodule NPM.PackTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "all packing entry points select directory contents, required files and safe bins", %{
    tmp_dir: dir
  } do
    write_package(dir, %{
      "files" => ["dist"],
      "main" => "entry.js",
      "bin" => %{"tool" => "bin/tool.js"},
      "exports" => %{"." => "./exported.js"}
    })

    for file <- [
          "dist/index.js",
          "dist/nested/child.js",
          "dist/.npmrc",
          "dist/node_modules/private/index.js",
          "README.md",
          "LICENSE.txt",
          "entry.js",
          "bin/tool.js",
          "secret.js",
          "exported.js",
          "node_modules/private/index.js",
          "package-lock.json"
        ],
        do: write_file(dir, file, "content")

    assert {:ok, files} = NPM.Pack.list_files(dir)

    assert files == [
             "LICENSE.txt",
             "README.md",
             "bin/tool.js",
             "dist/index.js",
             "dist/nested/child.js",
             "dist/node_modules/private/index.js",
             "entry.js",
             "package.json"
           ]

    assert NPM.Packager.files_to_pack(dir) == files
    assert NPM.Packager.pack_file_count(dir) == length(files)
  end

  test "applies ignore globs and negations at every directory without following symlinks", %{
    tmp_dir: dir
  } do
    write_package(dir)
    write_file(dir, ".npmignore", "*.map\nsecret/\n!keep.map\n")
    write_file(dir, ".gitignore", "index.js\n")
    write_file(dir, "nested/.npmignore", "hidden.js\n")

    for file <- [
          "index.js",
          "index.js.map",
          "keep.map",
          "secret/token",
          "nested/ok.js",
          "nested/hidden.js"
        ],
        do: write_file(dir, file, "content")

    outside = Path.join(dir, "outside-secret")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(dir, "link.js"))
    File.ln_s!(dir, Path.join(dir, "cycle"))
    File.rm!(outside)

    assert {:ok, ["index.js", "keep.map", "nested/ok.js", "package.json"]} =
             NPM.Pack.list_files(dir)
  end

  test "an empty npmignore overrides gitignore and required root files remain included", %{
    tmp_dir: dir
  } do
    write_package(dir)
    write_file(dir, ".gitignore", "*.js\nREADME.md\n")
    write_file(dir, ".npmignore", "")
    write_file(dir, "index.js", "content")
    write_file(dir, "README.md", "readme")

    assert {:ok, ["README.md", "index.js", "package.json"]} = NPM.Pack.list_files(dir)
  end

  test "file allowlists override root ignores while nested ignores still apply", %{tmp_dir: dir} do
    write_package(dir, %{"files" => ["dist"]})
    write_file(dir, ".npmignore", "dist/\n")
    write_file(dir, "dist/.npmignore", "*.map\n")
    write_file(dir, "dist/index.js", "content")
    write_file(dir, "dist/index.js.map", "content")

    assert {:ok, ["dist/index.js", "package.json"]} = NPM.Pack.list_files(dir)
  end

  test "tarball contains exactly the selected files under package/", %{tmp_dir: dir} do
    write_package(dir, %{"files" => ["dist/*.js"]})
    write_file(dir, "dist/index.js", "export default 1;")
    write_file(dir, "dist/private.txt", "secret")

    assert {:ok, %{filename: "scope-fixture-1.2.3.tgz", tarball: tarball, files: files}} =
             NPM.Pack.tarball(dir)

    assert {:ok, entries} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    assert Enum.sort(Enum.map(entries, fn {path, _} -> to_string(path) end)) ==
             Enum.map(files, &("package/" <> &1))

    assert {~c"package/dist/index.js", "export default 1;"} in entries
    refute File.exists?(Path.join(dir, "scope-fixture-1.2.3.tgz"))
  end

  test "rejects unsupported bundled dependencies rather than omitting them silently", %{
    tmp_dir: dir
  } do
    write_package(dir, %{"bundledDependencies" => ["required"]})
    assert {:error, :bundled_dependencies_not_supported} = NPM.Pack.list_files(dir)
  end

  test "explicit credential paths and symlinked entry points cannot bypass exclusions", %{
    tmp_dir: dir
  } do
    write_package(dir, %{"files" => [".npmrc", "dist"], "main" => ".npmrc", "bin" => "bin.js"})
    write_file(dir, ".npmrc", "//registry/:_authToken=secret")
    write_file(dir, "dist/.npmrc", "//registry/:_authToken=secret")
    write_file(dir, "dist/index.js", "safe")
    File.ln_s!(Path.join(dir, ".npmrc"), Path.join(dir, "bin.js"))

    assert {:ok, ["dist/index.js", "package.json"]} = NPM.Pack.list_files(dir)
  end

  test "malformed file allowlists fail instead of publishing every project file", %{tmp_dir: dir} do
    write_package(dir, %{"files" => "dist"})
    write_file(dir, "private.txt", "secret")
    assert {:error, :invalid_files_field} = NPM.Pack.list_files(dir)
  end

  test "repeated ignore rules retain their last-match precedence", %{tmp_dir: dir} do
    write_package(dir)
    write_file(dir, ".npmignore", "*.js\n!keep.js\n*.js\n")
    write_file(dir, "keep.js", "secret")
    assert {:ok, ["package.json"]} = NPM.Pack.list_files(dir)
  end

  test "ignored directories do not leak nested manifests or override root rules", %{tmp_dir: dir} do
    write_package(dir)
    write_file(dir, ".npmignore", "secret/\n!secret/keep.js\n")
    write_file(dir, "secret/package.json", ~s({"secret":"not-for-publishing"}))
    write_file(dir, "secret/README.md", "not-for-publishing")
    write_file(dir, "secret/.npmignore", "!*\n")
    write_file(dir, "secret/keep.js", "not-for-publishing")
    write_file(dir, "safe.js", "safe")

    assert {:ok, ["package.json", "safe.js"]} = NPM.Pack.list_files(dir)
  end

  test "directory-only ignore patterns do not exclude regular files of the same name", %{
    tmp_dir: dir
  } do
    write_package(dir)
    write_file(dir, ".npmignore", "build/\n")
    write_file(dir, "build", "regular file")
    assert {:ok, ["build", "package.json"]} = NPM.Pack.list_files(dir)
  end

  defp write_package(dir, data \\ %{}) do
    write_file(
      dir,
      "package.json",
      JSON.encode!(Map.merge(%{"name" => "@scope/fixture", "version" => "1.2.3"}, data))
    )
  end

  defp write_file(dir, path, content) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
