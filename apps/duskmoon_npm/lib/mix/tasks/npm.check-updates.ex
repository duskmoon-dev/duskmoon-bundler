# Mix preserves the hyphen when resolving the command to a module name.
defmodule :"Elixir.Mix.Tasks.Npm.Check-updates" do
  @moduledoc """
  Check the latest registry versions against the declarations in `package.json`.

      mix npm.check-updates         # Preview updates for the current package
      mix npm.check-updates -w      # Preview updates for the root and all workspaces
      mix npm.check-updates -w -u   # Write updates to the root and workspace manifests

  `-w` (`--workspaces`) includes all declared npm workspaces. Use `--no-root`
  with this option to check only workspace packages.

  `-u` (`--upgrade`) writes proposed changes to `package.json`. Run
  `mix npm.install` separately to install the new versions and refresh the lockfile.

  Checks registry dependencies in `dependencies`, `devDependencies` and
  `optionalDependencies`. Supports exact versions, single version constraints
  such as `^1.2.3`, and partial versions such as `1.x`. It skips local
  references and compound ranges.
  """

  use Mix.Task

  @switches [workspaces: :boolean, upgrade: :boolean, root: :boolean]
  @aliases [w: :workspaces, u: :upgrade]
  @dependency_fields ~w(dependencies devDependencies optionalDependencies)
  @version_range ~r/\A(?<operator>\^|~|>=|>|=)?(?<prefix>v?)(?<base>\d+(?:\.(?:\d+|[xX*])){0,2})(?<suffix>(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)\z/

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        if Keyword.has_key?(opts, :root) and !opts[:workspaces] do
          Mix.raise("--root and --no-root require --workspaces")
        end

        {manifests, local_names} = manifests!(opts)
        declarations = Enum.map(manifests, &{&1, declarations(&1.data, local_names)})
        latest = latest_versions!(declarations)

        Enum.each(declarations, fn {manifest, deps} ->
          changes =
            for {field, name, current, package, alias_prefix, range} <- deps,
                version = latest[package],
                {:ok, upgraded} <- [upgrade_range(range, version)] do
              {field, name, current, alias_prefix <> upgraded}
            end

          report!(manifest, changes, opts[:upgrade])
        end)

      _ ->
        Mix.raise("Usage: mix npm.check-updates [-w | --workspaces] [-u | --upgrade] [--no-root]")
    end
  end

  defp manifests!(opts) do
    if opts[:workspaces] do
      {:ok, root_dir} = read!(NPM.Workspace.root_dir(), File.cwd!())
      {:ok, [root | workspaces]} = read!(NPM.Workspace.manifests(root_dir), root_dir)

      unless match?(%{"workspaces" => patterns} when is_list(patterns), root.data) or
               match?(
                 %{"workspaces" => %{"packages" => patterns}} when is_list(patterns),
                 root.data
               ) do
        Mix.raise("workspaces property missing from #{root.path}")
      end

      names = MapSet.new(workspaces, &(&1.data["name"] || Path.basename(&1.dir)))
      selected = if Keyword.get(opts, :root, true), do: [root | workspaces], else: workspaces
      {selected, names}
    else
      {:ok, dir} = NPM.Workspace.package_dir()
      path = Path.join(dir, "package.json")
      {:ok, data} = read!(NPM.JSON.read_file(path), path)

      unless is_map(data), do: Mix.raise("Expected an object in #{path}")

      {[%{path: path, data: data}], MapSet.new()}
    end
  end

  defp declarations(data, local_names) do
    for field <- @dependency_fields,
        deps = data[field],
        is_map(deps),
        {name, current} <- Enum.sort(deps),
        is_binary(current),
        !MapSet.member?(local_names, name),
        {package, prefix, range} = dependency_target(name, current),
        !MapSet.member?(local_names, package),
        NPM.Scope.installable_name?(package),
        captures = Regex.named_captures(@version_range, String.trim(range)),
        captures != nil,
        match?({:ok, _}, NPMSemver.parse_range(range)) do
      {field, name, current, package, prefix, captures}
    end
  end

  defp dependency_target(name, current) do
    case NPM.Alias.parse(current) do
      {:alias, package, range} -> {package, "npm:#{package}@", range}
      {:normal, range} -> {name, "", range}
    end
  end

  defp latest_versions!(declarations) do
    packages =
      declarations
      |> Enum.flat_map(fn {_manifest, deps} -> Enum.map(deps, &elem(&1, 3)) end)
      |> Enum.uniq()

    if packages != [], do: NPM.MixBootstrap.ensure_started!()

    Map.new(packages, fn package ->
      case NPM.Registry.get_packument(package) do
        {:ok, %{dist_tags: %{"latest" => latest}}} -> {package, latest}
        {:ok, _packument} -> {package, nil}
        {:error, reason} -> Mix.raise("Could not check #{package}: #{inspect(reason)}")
      end
    end)
  end

  defp upgrade_range(
         %{"operator" => operator, "prefix" => prefix, "base" => base, "suffix" => suffix},
         latest
       ) do
    parts = String.split(base, ".")
    lower_parts = Enum.map(parts, &if(&1 in ~w(x X *), do: "0", else: &1))
    lower = Enum.join(lower_parts ++ List.duplicate("0", 3 - length(parts)), ".") <> suffix

    with {:ok, current} <- Version.parse(lower),
         {:ok, target} <- Version.parse(latest),
         true <- target.pre == [] or current.pre != [],
         :gt <- Version.compare(target, current) do
      target_parts = Enum.map([target.major, target.minor, target.patch], &Integer.to_string/1)

      upgraded_base =
        Enum.zip_with(parts, target_parts, fn part, target_part ->
          if part in ~w(x X *), do: part, else: target_part
        end)
        |> Enum.join(".")

      if upgraded_base != base or (length(parts) == 3 and !Enum.any?(parts, &(&1 in ~w(x X *)))) do
        target_suffix = String.replace_prefix(latest, Enum.join(target_parts, "."), "")
        updated_operator = if operator == ">", do: ">=", else: operator
        {:ok, updated_operator <> prefix <> upgraded_base <> target_suffix}
      end
    end
  end

  defp report!(manifest, changes, upgrade?) do
    path = Path.relative_to_cwd(manifest.path)
    Mix.shell().info("#{if upgrade?, do: "Upgrading", else: "Checking"} #{path}")

    case changes do
      [] ->
        Mix.shell().info("No dependency updates found.")

      _ ->
        Enum.each(changes, fn {field, name, current, upgraded} ->
          Mix.shell().info("  #{name}  #{current} → #{upgraded} (#{field})")
        end)

        if upgrade? do
          data =
            Enum.reduce(changes, manifest.data, fn {field, name, _current, upgraded}, data ->
              put_in(data, [field, name], upgraded)
            end)

          case File.write(manifest.path, NPM.JSON.encode_pretty(data)) do
            :ok -> Mix.shell().info("Run `mix npm.install` to install the new versions.")
            {:error, reason} -> Mix.raise("Could not write #{path}: #{inspect(reason)}")
          end
        end
    end
  end

  defp read!({:ok, value}, _path), do: {:ok, value}
  defp read!({:error, reason}, path), do: Mix.raise("Could not read #{path}: #{inspect(reason)}")
end
