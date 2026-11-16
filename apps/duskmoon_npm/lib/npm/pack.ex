defmodule NPM.Pack do
  @moduledoc """
  Selects package files and creates npm tarballs for both `npm.pack` and
  `npm.publish`. Directory allowlists are recursive; ignore files are applied
  at their own directory, with `.npmignore` taking precedence over `.gitignore`.
  Symlinks are omitted. Bundled dependencies are not yet supported and are
  rejected rather than silently producing an incomplete package.
  """

  @always_exclude ~w(.git .svn .hg CVS .npm .DS_Store .npmrc .npmignore .gitignore npm-debug.log)
  @root_exclude ~w(node_modules package-lock.json npm.lock bun.lockb yarn.lock pnpm-lock.yaml)

  @doc "List the files included in a package tarball, relative to the project directory."
  @spec list_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_files(project_dir) do
    with {:ok, data} <- NPM.JSON.read_file(Path.join(project_dir, "package.json")),
         :ok <- supported_package(data),
         {:ok, files} <- walk_files(project_dir, "") do
      patterns = Map.get(data, "files")
      allowlisted? = is_list(patterns)
      required = required_files(data)
      ignores = ignore_rules(project_dir, files, allowlisted?)

      selected =
        files
        |> Enum.filter(fn file ->
          always_included?(file) or file in required or
            ((not allowlisted? or allowed_file?(file, patterns)) and
               not ignored_file?(file, ignores))
        end)
        |> Enum.sort()

      {:ok, selected}
    end
  end

  @doc "Build an npm tarball in a temporary location and return its bytes and selected files."
  @spec tarball(String.t()) :: {:ok, map()} | {:error, term()}
  def tarball(project_dir) do
    with {:ok, data} <- NPM.JSON.read_file(Path.join(project_dir, "package.json")),
         :ok <- validate_identity(data),
         {:ok, files} <- list_files(project_dir) do
      temporary =
        Path.join(
          System.tmp_dir!(),
          "npm-pack-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.tgz"
        )

      entries =
        Enum.map(files, fn file ->
          {String.to_charlist("package/" <> file),
           String.to_charlist(Path.join(project_dir, file))}
        end)

      try do
        with :ok <- :erl_tar.create(String.to_charlist(temporary), entries, [:compressed]),
             {:ok, tarball} <- File.read(temporary) do
          {:ok, %{filename: tarball_name(data), tarball: tarball, files: files, data: data}}
        end
      after
        File.rm(temporary)
      end
    end
  end

  @doc "Generate the conventional tarball filename from package metadata."
  @spec tarball_name(map()) :: String.t()
  def tarball_name(%{"name" => name, "version" => version}) do
    safe_name = name |> String.replace("/", "-") |> String.replace_prefix("@", "")
    "#{safe_name}-#{version}.tgz"
  end

  def tarball_name(%{"name" => name}), do: tarball_name(%{"name" => name, "version" => "0.0.0"})

  @doc "Check default exclusions for any path component."
  @spec excluded?(String.t()) :: boolean()
  def excluded?(path) do
    parts = Path.split(path)

    hd(parts) in @root_exclude or
      Enum.any?(parts, fn component ->
        component in @always_exclude or String.starts_with?(component, "._")
      end)
  end

  @doc "Check files that are always included at the package root."
  @spec always_included?(String.t()) :: boolean()
  def always_included?(path) do
    Path.dirname(path) == "." and
      (path == "package.json" or Regex.match?(~r/^(readme|licen[cs]e|changelog)(\..*)?$/i, path))
  end

  @doc "List files using default selection and ignore rules."
  @spec default_files(String.t()) :: [String.t()]
  def default_files(project_dir) do
    case list_files(project_dir) do
      {:ok, files} -> files
      {:error, _reason} -> []
    end
  end

  defp validate_identity(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version) do
    if NPM.Scope.installable_name?(name) and match?({:ok, _}, Version.parse(version)),
      do: :ok,
      else: {:error, :invalid_package_identity}
  end

  defp validate_identity(_data), do: {:error, :invalid_package_identity}

  defp supported_package(data) when is_map(data) do
    bundled = Map.get(data, "bundledDependencies", Map.get(data, "bundleDependencies", []))
    files = Map.get(data, "files")

    cond do
      bundled not in [nil, false, []] -> {:error, :bundled_dependencies_not_supported}
      is_nil(files) -> :ok
      is_list(files) and Enum.all?(files, &is_binary/1) -> :ok
      true -> {:error, :invalid_files_field}
    end
  end

  defp supported_package(_data), do: {:error, :invalid_package_manifest}

  defp walk_files(base, relative) do
    with {:ok, entries} <- File.ls(Path.join(base, relative)) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, files} ->
        path = if relative == "", do: entry, else: Path.join(relative, entry)

        case File.lstat(Path.join(base, path)) do
          {:ok, _stat}
          when entry in @always_exclude or (relative == "" and entry in @root_exclude) ->
            {:cont, {:ok, files}}

          {:ok, %File.Stat{type: :directory}} ->
            case walk_files(base, path) do
              {:ok, nested} -> {:cont, {:ok, nested ++ files}}
              {:error, _reason} = error -> {:halt, error}
            end

          {:ok, %File.Stat{type: :regular}} ->
            {:cont, {:ok, if(excluded?(path), do: files, else: [path | files])}}

          {:ok, _symlink_or_special_file} ->
            {:cont, {:ok, files}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp required_files(data) do
    bin =
      case data["bin"] do
        path when is_binary(path) -> [path]
        paths when is_map(paths) -> Map.values(paths)
        _ -> []
      end

    [data["main"] | bin]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.replace_prefix(&1, "./", ""))
  end

  defp allowed_file?(file, patterns) do
    Enum.reduce(patterns, false, fn
      "!" <> pattern, allowed ->
        allowed and not NPM.Ignore.matches?(file, pattern, true)

      pattern, allowed when is_binary(pattern) ->
        allowed or NPM.Ignore.matches?(file, pattern, true)

      _invalid, allowed ->
        allowed
    end)
  end

  defp ignore_rules(project_dir, files, allowlisted?) do
    files
    |> Enum.flat_map(fn file -> ancestor_dirs(Path.dirname(file)) end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "." and allowlisted?))
    |> Enum.map(fn directory ->
      {directory, NPM.Ignore.effective_patterns(Path.join(project_dir, directory))}
    end)
    |> Enum.sort_by(fn {directory, _} -> length(Path.split(directory)) end)
  end

  defp ancestor_dirs("."), do: ["."]
  defp ancestor_dirs(directory), do: [directory | ancestor_dirs(Path.dirname(directory))]

  defp ignored_file?(file, rules) do
    Enum.reduce_while(rules, false, fn {directory, patterns}, ignored ->
      if directory == "." or String.starts_with?(file, directory <> "/") do
        relative = if directory == ".", do: file, else: Path.relative_to(file, directory)

        excluded_parent? =
          relative
          |> Path.dirname()
          |> ancestor_dirs()
          |> Enum.reject(&(&1 == "."))
          |> Enum.any?(&NPM.Ignore.apply_rules(&1, patterns, false, true))

        if excluded_parent? do
          # Ignore rules inside an excluded directory cannot re-include its
          # contents. Required root metadata is handled before ignore rules.
          {:halt, true}
        else
          {:cont, NPM.Ignore.apply_rules(relative, patterns, ignored)}
        end
      else
        {:cont, ignored}
      end
    end)
  end
end
