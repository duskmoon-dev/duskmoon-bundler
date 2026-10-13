defmodule DuskmoonToolchain.PackageStage do
  @moduledoc "Stages the synchronized Hex cohort outside the checkout without editing source files."
  @apps ~w(duskmoon_bundler duskmoon_bundler_runtime duskmoon_oxc duskmoon_oxide duskmoon_vize duskmoon_quickbeam duskmoon_npm duskmoon_hex_solver)a
  @root_keys [:build_path, :config_path, :deps_path, :lockfile]

  def apps, do: @apps

  def normalize_manifest(source, version) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {:@, meta, [{:version, attr_meta, [_]}]} ->
        {:@, meta, [{:version, attr_meta, [version]}]}

      {app, opts} = node when is_atom(app) and is_list(opts) ->
        if app in @apps and Keyword.get(opts, :in_umbrella) do
          {:{}, [], [app, "== #{version}", Keyword.delete(opts, :in_umbrella)]}
        else
          node
        end

      {:{}, meta, [app, opts]} = node when is_atom(app) and is_list(opts) ->
        if app in @apps and Keyword.get(opts, :in_umbrella) do
          {:{}, meta, [app, "== #{version}", Keyword.delete(opts, :in_umbrella)]}
        else
          node
        end

      list when is_list(list) ->
        if Keyword.keyword?(list), do: Keyword.drop(list, @root_keys ++ [:override]), else: list

      node ->
        node
    end)
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  def stage!(root, output, version) do
    root = Path.expand(root)
    output = Path.expand(output)
    Version.parse!(version)

    if output == root or String.starts_with?(output, root <> "/"),
      do: raise("Package staging output must be outside the developer checkout")

    if File.exists?(output), do: raise("Refusing to overwrite existing staging output #{output}")
    Mix.start()
    File.mkdir_p!(output)

    packages = Enum.map(@apps, &stage_app!(root, output, &1, version))
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    manifest = %{version: version, source_sha: String.trim(sha), packages: packages}
    File.write!(Path.join(output, "manifest.json"), JSON.encode!(manifest) <> "\n")
    manifest
  end

  defp stage_app!(root, output, app, version) do
    source = Path.join([root, "apps", to_string(app)])
    target = Path.join(output, to_string(app))
    config = Mix.Project.in_project(app, source, fn _ -> Mix.Project.config() end)
    patterns = Keyword.fetch!(config, :package) |> Keyword.fetch!(:files)

    paths =
      (patterns ++ ["native", ".cargo"])
      |> Enum.flat_map(&Path.wildcard(Path.join(source, &1), match_dot: true))
      |> Enum.flat_map(fn path ->
        if File.dir?(path),
          do: Path.wildcard(Path.join(path, "**/*"), match_dot: true),
          else: [path]
      end)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(fn path ->
        Enum.any?(
          Path.split(Path.relative_to(path, source)),
          &(&1 in ["target", "node_modules", "_build", "deps"])
        )
      end)
      |> Enum.uniq()
      |> Enum.sort()

    File.mkdir_p!(target)

    for path <- paths do
      if File.lstat!(path).type == :symlink, do: raise("Symlink cannot enter package: #{path}")
      destination = Path.join(target, Path.relative_to(path, source))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(path, destination)
    end

    mixfile = Path.join(target, "mix.exs")
    File.write!(mixfile, normalize_manifest(File.read!(mixfile), version))
    validate_manifest!(mixfile)

    dependencies =
      config[:deps]
      |> Enum.flat_map(fn
        {dep, opts} when is_list(opts) -> if dep in @apps, do: [to_string(dep)], else: []
        {dep, _, _} -> if dep in @apps, do: [to_string(dep)], else: []
        {_, _} -> []
      end)

    hashes =
      for path <- Path.wildcard(Path.join(target, "**/*"), match_dot: true),
          File.regular?(path),
          into: %{} do
        {Path.relative_to(path, target),
         :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
      end

    %{name: to_string(app), version: version, dependencies: dependencies, files: hashes}
  end

  defp validate_manifest!(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    Macro.prewalk(ast, fn
      {key, _} when key in [:in_umbrella, :path, :git, :github] ->
        raise("Local dependency #{key} leaked into #{path}")

      node ->
        node
    end)

    :ok
  end
end
