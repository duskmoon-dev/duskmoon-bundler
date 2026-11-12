defmodule NPM do
  alias NPM.Install.Linker
  alias NPM.Install.LockfileBuilder
  alias NPM.Install.ScriptInstall
  alias NPM.Package.JSON
  alias NPM.Security.Age
  alias NPM.Security.ExoticDeps

  @moduledoc """
  npm package manager for Elixir.

  Resolves, fetches, and installs npm packages using Mix tasks.
  Dependencies are declared in `package.json` files and locked in `package-lock.json`.

  ## Mix tasks

      mix npm.install              # Install all deps from package.json/workspaces
      mix npm.install lodash       # Add latest version
      mix npm.install lodash@^4.0  # Add with specific range
      mix npm.install --frozen     # Fail if lockfile is stale (CI mode)
      mix npm.get                  # Fetch locked deps without resolving
      mix npm.remove lodash        # Remove a package
      mix npm.list                 # List installed packages

  Packages are cached globally in `~/.npm_ex/cache/` and copied into
  `node_modules/` so Node-compatible tools resolve sibling dependencies
  from the installed dependency tree.
  """

  @node_modules "node_modules"

  @doc """
  Install npm packages in a script context, without a Mix project.

  Works like `Mix.install/2` — installs to a content-addressed cache directory,
  is idempotent, and can only be called once per VM (raises on different deps).

      NPM.install(%{"tailwindcss" => "^4.2.2"})

  After installation, use `NPM.install_dir!/0` and `NPM.node_modules_dir!/0`
  to locate the installed packages.

  ## Options

    * `:force` — reinstall even if cached (default: `false`)
  """
  @spec install(map(), keyword()) :: :ok
  def install(deps, opts) when is_map(deps) do
    ScriptInstall.install(deps, opts)
  end

  @doc """
  Returns whether `NPM.install/2` has been called in this VM.
  """
  @spec installed? :: boolean()
  defdelegate installed?, to: ScriptInstall

  @doc """
  Returns the root directory of the current `NPM.install/2` installation.

  Raises if `NPM.install/2` has not been called.
  """
  @spec install_dir! :: String.t()
  defdelegate install_dir!, to: ScriptInstall

  @doc """
  Returns the `node_modules` path of the current `NPM.install/2` installation.

  Raises if `NPM.install/2` has not been called.
  """
  @spec node_modules_dir! :: String.t()
  defdelegate node_modules_dir!, to: ScriptInstall

  @doc """
  Install all dependencies from `package.json` and configured workspaces.

  Existing satisfiable lockfile records, including workspace-local and nested
  packages, are retained when adding dependencies. Use `update/0` to refresh
  the complete dependency graph.

  Ordinary and frozen installs validate each manifest from its package location,
  so workspace-local pins may coexist with different hoisted versions.
  Ordinary installs refresh changed root and workspace package metadata without
  re-resolving current dependencies; frozen installs reject stale metadata.
  Ordinary installs also prune lock records no longer reachable from any
  root or workspace manifest, keeping remaining records unchanged.

  ## Options

    * `:frozen` - when `true`, fails if `package-lock.json` doesn't match
      `package.json` instead of re-resolving. Useful for CI.
    * `:production` - when `true`, skips `devDependencies`.
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) when is_list(opts) do
    with_root_dir(fn ->
      if opts[:frozen] do
        with {:ok, dependencies, local_links} <- NPM.Workspace.frozen_dependencies(opts),
             :ok <- NPM.Lockfile.sync_package_metadata(frozen: true) do
          if Enum.all?(dependencies, fn {_location, deps} -> deps == [] end) do
            do_install(%{}, local_links: local_links, frozen: true)
          else
            frozen_install(dependencies, local_links)
          end
        else
          {:error, :frozen_lockfile} = error ->
            Mix.shell().error(
              "package-lock.json contains stale root or workspace package metadata.\n" <>
                "Run `mix npm.install` to update the lockfile."
            )

            error

          error ->
            error
        end
      else
        with {:ok, project} <- NPM.Workspace.read_all(),
             {:ok, deps} <- NPM.Workspace.install_dependencies(project, opts),
             :ok <- do_install(deps, Keyword.put(opts, :local_links, project.local_links)) do
          NPM.Lockfile.sync_package_metadata()
        end
      end
    end)
  end

  @doc """
  Add a package to `package.json` and install all dependencies.

  ## Options

    * `:dev` - when `true`, adds to `devDependencies` instead of `dependencies`
  """
  @spec add(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def add(name, range \\ "latest", opts \\ []) do
    range = if range == "latest", do: resolve_latest(name, opts), else: range

    with range_str when is_binary(range_str) <- range,
         {:ok, package_dir} <- NPM.Workspace.package_dir(),
         package_path <- Path.join(package_dir, "package.json"),
         :ok <- JSON.add_dep(name, range_str, package_path, opts) do
      install([])
    end
  end

  @doc """
  Remove a package from `package.json` and re-install.
  """
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(name) do
    with {:ok, package_dir} <- NPM.Workspace.package_dir(),
         package_path <- Path.join(package_dir, "package.json"),
         :ok <- JSON.remove_dep(name, package_path) do
      install([])
    end
  end

  @doc """
  Update all packages to the latest versions matching their ranges.

  Clears the resolver cache and re-resolves from scratch.
  """
  @spec update :: :ok | {:error, term()}
  def update do
    with_root_dir(fn ->
      with {:ok, project} <- NPM.Workspace.read_all(),
           {:ok, deps} <- NPM.Workspace.install_dependencies(project) do
        do_install(deps, local_links: project.local_links, force_resolve: true)
      end
    end)
  end

  @doc """
  Update a specific package to the latest version matching its range.

  Only re-resolves the named package; other locked versions are preserved.
  """
  @spec update(String.t()) :: :ok | {:error, term()}
  def update(name) do
    with_root_dir(fn ->
      with {:ok, project} <- NPM.Workspace.read_all(),
           {:ok, all_deps} <- NPM.Workspace.install_dependencies(project) do
        if Map.has_key?(all_deps, name) do
          do_install(all_deps, local_links: project.local_links, unlock: [name])
        else
          Mix.shell().error("Package #{name} not found in package.json.")
          {:error, {:not_found, name}}
        end
      end
    end)
  end

  @doc """
  Fetch locked dependencies without re-resolving.

  Reads `package-lock.json` and populates the global cache and `node_modules/`
  for any missing packages.
  """
  @spec get :: :ok | {:error, term()}
  def get do
    with_root_dir(fn ->
      with {:ok, lockfile} <- NPM.Lockfile.read(),
           {:ok, nested_lockfile} <- NPM.Lockfile.read_nested() do
        if lockfile == %{} and nested_lockfile == %{} do
          Mix.shell().info("No package-lock.json found, run `mix npm.install` first.")
          :ok
        else
          with {:ok, _dependencies, local_links} <- NPM.Workspace.frozen_dependencies([]) do
            link_from_lockfile(lockfile, local_links, nested_lockfile)
          end
        end
      end
    end)
  end

  @doc """
  List installed packages with versions.

  Returns a list of `{name, version}` tuples.
  """
  @spec list :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list do
    with_root_dir(fn ->
      case NPM.Lockfile.read() do
        {:ok, lockfile} when lockfile == %{} ->
          {:ok, []}

        {:ok, lockfile} ->
          packages =
            lockfile
            |> Enum.map(fn {name, entry} -> {name, entry.version} end)
            |> Enum.sort_by(&elem(&1, 0))

          {:ok, packages}

        error ->
          error
      end
    end)
  end

  # --- Private ---

  defp with_root_dir(fun) do
    with {:ok, root_dir} <- NPM.Workspace.root_dir() do
      File.cd!(root_dir, fun)
    end
  end

  defp do_install(deps, opts) when map_size(deps) == 0 do
    local_links = Keyword.get(opts, :local_links, %{})

    cond do
      not Keyword.get(opts, :frozen, false) and not locked_graph_reachable?(opts, local_links) ->
        prune_locked_graph(local_links, opts)

      local_links == %{} ->
        Mix.shell().info("No npm dependencies found in package.json.")
        :ok

      true ->
        with :ok <- Linker.link(%{}, @node_modules),
             :ok <- Linker.link_local_packages(local_links, @node_modules) do
          Mix.shell().info(
            "Linked #{map_size(local_links)} local npm package#{plural(local_links)}."
          )

          :ok
        end
    end
  end

  defp do_install(deps, opts) do
    full_install(
      deps,
      Keyword.get(opts, :local_links, %{}),
      opts
    )
  end

  defp prune_locked_graph(local_links, opts) do
    with {:ok, flat} <- NPM.Lockfile.read(),
         {:ok, nested} <- NPM.Lockfile.read_nested(),
         {:ok, overrides} <- JSON.read_overrides() do
      update_locked_graph(flat, nested, local_links, overrides, opts)
    end
  end

  defp frozen_install(deps, local_links) do
    with {:ok, lockfile} <- NPM.Lockfile.read(),
         {:ok, nested_lockfile} <- NPM.Lockfile.read_nested(),
         {:ok, overrides} <- JSON.read_overrides() do
      if lockfile == %{} and nested_lockfile == %{} do
        Mix.shell().error("package-lock.json not found. Run `mix npm.install` first.")
        {:error, :no_lockfile}
      else
        locations = lockfile_locations(lockfile, nested_lockfile)

        if frozen_dependencies_satisfied?(locations, deps) and
             frozen_records_complete?(locations, local_links, overrides) and
             lockfile_policy_current?() do
          link_from_lockfile(lockfile, local_links, nested_lockfile)
        else
          Mix.shell().error(
            "package-lock.json is out of date with package.json or current security policy.\n" <>
              "Run `mix npm.install` to update the lockfile."
          )

          {:error, :frozen_lockfile}
        end
      end
    end
  end

  defp frozen_dependencies_satisfied?(locations, dependencies) do
    Enum.all?(dependencies, fn {location, deps} ->
      Enum.all?(deps, fn {name, range} ->
        case frozen_dependency_entry(locations, location, name) do
          nil -> false
          entry -> lockfile_entry_satisfies_range?(entry, range)
        end
      end)
    end)
  end

  defp frozen_records_complete?(locations, local_links, overrides) do
    Enum.all?(locations, fn {location, entry} ->
      Enum.all?(effective_dependencies(entry, overrides), fn {name, range} ->
        Map.has_key?(local_links, name) or
          case frozen_dependency_entry(locations, location, name) do
            nil -> false
            resolved -> lockfile_entry_satisfies_range?(resolved, range)
          end
      end)
    end)
  end

  defp effective_dependencies(entry, overrides) do
    entry.dependencies
    |> Map.merge(Map.get(entry, :optional_dependencies, %{}))
    |> Map.new(fn {name, range} -> {name, Map.get(overrides, name, range)} end)
  end

  defp frozen_dependency_entry(locations, location, name) do
    Map.get(locations, frozen_dependency_location(locations, location, name))
  end

  defp frozen_dependency_location(locations, location, name) do
    candidate =
      if location == "", do: "node_modules/#{name}", else: "#{location}/node_modules/#{name}"

    found? = Path.basename(location) != "node_modules" and Map.has_key?(locations, candidate)

    cond do
      found? ->
        candidate

      location != "" ->
        parent = Path.dirname(location)
        parent = if parent == ".", do: "", else: parent
        frozen_dependency_location(locations, parent, name)

      true ->
        nil
    end
  end

  defp lockfile_policy_current? do
    case NPM.Lockfile.read_policy() do
      {:ok, nil} -> true
      {:ok, policy} -> NPM.Lockfile.policy_matches?(policy)
      _ -> false
    end
  end

  defp lockfile_matches?(lockfile, opts, local_links, overrides) do
    with {:ok, nested} <- NPM.Lockfile.read_nested(),
         {:ok, dependencies, _links} <- NPM.Workspace.frozen_dependencies(opts) do
      locations = lockfile_locations(lockfile, nested)

      locations != %{} and frozen_dependencies_satisfied?(locations, dependencies) and
        frozen_records_complete?(locations, local_links, overrides) and
        all_locations_reachable?(locations, opts, local_links, overrides)
    else
      {:error, _reason} -> false
    end
  end

  defp lockfile_entry_satisfies_range?(_entry, range) when range in ["", "*", "latest"],
    do: true

  defp lockfile_entry_satisfies_range?(entry, range) do
    case NPM.Alias.parse(range) do
      {:alias, _package, alias_range} -> NPMSemver.matches?(entry.version, alias_range)
      {:normal, normal_range} -> NPMSemver.matches?(entry.version, normal_range)
    end
  end

  defp lockfile_locations(lockfile, nested_lockfile) do
    Map.new(lockfile, fn {name, entry} -> {"node_modules/#{name}", entry} end)
    |> Map.merge(nested_lockfile)
  end

  defp full_install(deps, local_links, opts) do
    validate_direct_exotic_deps!(deps)
    {:ok, old_lockfile} = NPM.Lockfile.read()
    {:ok, overrides} = JSON.read_overrides()

    matches? = lockfile_matches?(old_lockfile, opts, local_links, overrides)

    policy_ok? = lockfile_policy_current?()
    policy_reasons = lockfile_policy_mismatch_reasons()
    cache_ok? = matches? and cache_covers_lockfile?(old_lockfile)
    nm_intact? = matches? and node_modules_intact?(old_lockfile, local_links)

    cond do
      Keyword.get(opts, :force_resolve, false) or Keyword.get(opts, :unlock, []) != [] ->
        resolve_and_install(deps, old_lockfile, local_links, overrides, opts)

      matches? and policy_ok? and nm_intact? ->
        Mix.shell().info("Already up to date.")
        :ok

      matches? and policy_ok? ->
        Mix.shell().info("Installing from current package-lock.json.")
        link_from_lockfile(old_lockfile, local_links)

      matches? and cache_ok? ->
        warn_policy_mismatch(policy_reasons)
        Mix.shell().info("Installing from cached packages without re-resolving.")

        with :ok <- link_from_lockfile(old_lockfile, local_links) do
          _ = NPM.Lockfile.refresh_policy()
          :ok
        end

      true ->
        if policy_reasons != [] and matches? do
          warn_policy_mismatch(policy_reasons)
          Mix.shell().info("Cache incomplete — re-resolving dependencies.")
        end

        resolve_and_install(deps, old_lockfile, local_links, overrides, opts)
    end
  end

  defp lockfile_policy_mismatch_reasons do
    case NPM.Lockfile.read_policy() do
      {:ok, nil} -> []
      {:ok, policy} -> NPM.Lockfile.policy_mismatch_reasons(policy)
      _ -> ["unable to read lockfile policy"]
    end
  end

  defp warn_policy_mismatch(reasons) do
    Mix.shell().info("Lockfile security policy differs from current settings:")

    Enum.each(reasons, fn reason ->
      Mix.shell().info("  - #{reason}")
    end)
  end

  defp cache_covers_lockfile?(lockfile) do
    skipped = Linker.skipped_packages(lockfile)

    Enum.all?(lockfile, fn {name, entry} ->
      MapSet.member?(skipped, name) or NPM.Cache.cached?(name, entry.version)
    end)
  end

  defp validate_direct_exotic_deps!(deps) do
    Enum.each(deps, fn {name, spec} -> ExoticDeps.validate_direct!(name, spec) end)
  end

  defp node_modules_intact?(lockfile, local_links) do
    skipped = Linker.skipped_packages(lockfile)
    linkable_lockfile = linkable_lockfile(lockfile, skipped)
    strategy = Linker.strategy()

    lockfile_intact? =
      Enum.all?(linkable_lockfile, fn {name, entry} ->
        registry_package_intact?(Path.join(@node_modules, name), entry.version, strategy)
      end)

    local_links_intact? =
      Enum.all?(local_links, fn {name, _path} ->
        Path.join([@node_modules, name, "package.json"]) |> File.exists?()
      end)

    nested_lockfile_intact? =
      case NPM.Lockfile.read_nested() do
        {:ok, nested_lockfile} ->
          Enum.all?(nested_lockfile, fn {location, entry} ->
            nested_location_skipped?(location, skipped) or
              registry_package_intact?(location, entry.version, strategy)
          end)

        {:error, _reason} ->
          false
      end

    lockfile_intact? and nested_lockfile_intact? and local_links_intact?
  end

  defp nested_location_skipped?(location, skipped) do
    Enum.any?(skipped, fn name ->
      String.starts_with?(location, "node_modules/#{name}/node_modules/")
    end)
  end

  defp resolve_and_install(deps, old_lockfile, local_links, overrides, opts) do
    with {:ok, nested} <- NPM.Lockfile.read_nested() do
      if not Keyword.get(opts, :force_resolve, false) and (old_lockfile != %{} or nested != %{}) do
        update_locked_graph(old_lockfile, nested, local_links, overrides, opts)
      else
        resolve_fresh_and_install(deps, old_lockfile, local_links, overrides)
      end
    end
  end

  defp update_locked_graph(old_flat, old_nested, local_links, overrides, opts) do
    with {:ok, dependencies, _links} <- NPM.Workspace.frozen_dependencies(opts) do
      unlocked = Keyword.get(opts, :unlock, [])
      preferred = locked_preferences(old_flat, old_nested) |> Map.drop(unlocked)
      flat = Map.drop(old_flat, unlocked)

      nested =
        Map.reject(old_nested, fn {location, _} ->
          {:ok, name} = NPM.Lockfile.nested_package_name(location)
          name in unlocked
        end)

      unmet =
        for {location, requirements} <- dependencies,
            {name, range} <- requirements,
            not dependency_satisfied?(name, range, location, flat, nested),
            into: %{},
            do: {name, range}

      {flat, nested} =
        Enum.reduce(Map.merge(overrides, unmet), {flat, nested}, fn {name, range} = dependency,
                                                                    {flat, _nested} = state ->
          case Map.get(flat, name) do
            nil ->
              state

            entry ->
              if lockfile_entry_satisfies_range?(entry, range) do
                state
              else
                expand_dependency(dependency, "", state, false, local_links, overrides, preferred)
              end
          end
        end)

      {flat, nested} =
        Enum.reduce(dependencies, {flat, nested}, fn {location, deps}, state ->
          Enum.reduce(deps, state, fn dependency, acc ->
            expand_dependency(dependency, location, acc, false, local_links, overrides, preferred)
          end)
        end)

      {flat, nested} = expand_all_dependencies(flat, nested, local_links, overrides, preferred)
      locations = lockfile_locations(flat, nested)

      with true <- frozen_dependencies_satisfied?(locations, dependencies),
           {:ok, reachable} <-
             reachable_lockfile_locations(locations, opts, local_links, overrides) do
        flat =
          Map.filter(flat, fn {name, _} -> MapSet.member?(reachable, "node_modules/#{name}") end)

        nested = Map.take(nested, MapSet.to_list(reachable))
        persist_graph(flat, nested, old_flat, local_links, overrides, preserve: true)
      else
        false -> incomplete_graph()
        {:error, _reason} = error -> error
      end
    end
  end

  # Lock records stay reachable from every manifest dependency group;
  # production installs skip devDependencies but must not drop their records.
  defp reachable_lockfile_locations(locations, opts, local_links, overrides) do
    with {:ok, dependencies, _links} <-
           NPM.Workspace.frozen_dependencies(Keyword.delete(opts, :production)) do
      reachable =
        dependencies
        |> Enum.flat_map(fn {location, deps} ->
          Enum.map(deps, fn {name, _range} -> {location, name} end)
        end)
        |> reachable_locations(locations, local_links, overrides, MapSet.new())

      {:ok, reachable}
    end
  end

  defp all_locations_reachable?(locations, opts, local_links, overrides) do
    case reachable_lockfile_locations(locations, opts, local_links, overrides) do
      {:ok, reachable} -> Enum.all?(Map.keys(locations), &MapSet.member?(reachable, &1))
      {:error, _reason} -> false
    end
  end

  defp locked_graph_reachable?(opts, local_links) do
    with {:ok, flat} <- NPM.Lockfile.read(),
         {:ok, nested} <- NPM.Lockfile.read_nested(),
         {:ok, overrides} <- JSON.read_overrides() do
      all_locations_reachable?(lockfile_locations(flat, nested), opts, local_links, overrides)
    else
      {:error, _reason} -> false
    end
  end

  defp locked_preferences(flat, nested) do
    nested_entries =
      nested
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {location, entry} ->
        {:ok, name} = NPM.Lockfile.nested_package_name(location)
        {name, entry}
      end)

    Enum.reduce(Enum.to_list(flat) ++ nested_entries, %{}, fn {name, entry}, acc ->
      Map.update(acc, name, [entry], &(&1 ++ [entry]))
    end)
  end

  defp reachable_locations([], _locations, _links, _overrides, seen), do: seen

  defp reachable_locations([{parent, name} | rest], locations, links, overrides, seen) do
    location = frozen_dependency_location(locations, parent, name)

    if location == nil or Map.has_key?(links, name) or MapSet.member?(seen, location) do
      reachable_locations(rest, locations, links, overrides, seen)
    else
      entry = locations[location]

      # Peers resolve like regular deps; absent (optional) peers yield no location.
      deps =
        entry
        |> effective_dependencies(overrides)
        |> Map.keys()
        |> Enum.concat(Map.keys(Map.get(entry, :peer_dependencies, %{})))
        |> Enum.map(&{location, &1})

      reachable_locations(deps ++ rest, locations, links, overrides, MapSet.put(seen, location))
    end
  end

  defp resolve_fresh_and_install(deps, old_lockfile, local_links, overrides) do
    {resolve_us, result} =
      :timer.tc(fn ->
        NPM.Resolver.clear_cache()
        NPM.Resolver.resolve(deps, overrides: overrides)
      end)

    case result do
      {:ok, resolved} ->
        {nested_info, flat} = Map.pop(resolved, :nested, %{})
        pkg_count = map_size(flat)
        Mix.shell().info("Resolved #{pkg_count} packages in #{format_ms(resolve_us)}")

        if nested_info != %{} do
          Mix.shell().info("  (#{map_size(nested_info)} packages with nested versions)")
        end

        nested_lockfile = build_nested_lockfile(nested_info, flat, overrides)
        lockfile = build_lockfile(flat)

        {lockfile, nested_lockfile} =
          expand_all_dependencies(lockfile, nested_lockfile, local_links, overrides)

        persist_graph(lockfile, nested_lockfile, old_lockfile, local_links, overrides, [])

      {:error, message} ->
        Mix.shell().error("Resolution failed:\n#{message}")
        {:error, :resolution_failed}
    end
  end

  defp persist_graph(flat, nested, old, links, overrides, opts) do
    if frozen_records_complete?(lockfile_locations(flat, nested), links, overrides) do
      print_lockfile_diff(old, flat)

      with :ok <- NPM.Lockfile.write(flat, Keyword.put(opts, :nested, nested)) do
        link_from_lockfile(flat, links, nested)
      end
    else
      incomplete_graph()
    end
  end

  defp incomplete_graph do
    Mix.shell().error("Resolution failed: incomplete dependency graph.")
    {:error, :resolution_failed}
  end

  defp link_from_lockfile(lockfile, local_links, nested_lockfile \\ :read)

  defp link_from_lockfile(lockfile, local_links, :read) do
    with {:ok, nested_lockfile} <- NPM.Lockfile.read_nested() do
      link_from_lockfile(lockfile, local_links, nested_lockfile)
    end
  end

  defp link_from_lockfile(lockfile, local_links, nested_lockfile) do
    skipped = Linker.skipped_packages(lockfile)
    linkable_lockfile = linkable_lockfile(lockfile, skipped)
    total = length(linkable_lockfile)

    cached =
      Enum.count(linkable_lockfile, fn {name, entry} -> NPM.Cache.cached?(name, entry.version) end)

    to_fetch = total - cached

    if to_fetch > 0 do
      Mix.shell().info("Fetching #{to_fetch} package#{if to_fetch != 1, do: "s", else: ""}...")
    end

    strategy = Linker.strategy()

    {link_us, result} =
      :timer.tc(fn ->
        with :ok <- Linker.link(lockfile, @node_modules, strategy, skipped),
             :ok <-
               Linker.link_nested_lockfile(
                 nested_lockfile,
                 @node_modules,
                 strategy,
                 skipped
               ) do
          NPM.Install.Linker.link_local_packages(local_links, @node_modules)
        end
      end)

    case result do
      :ok ->
        ms = div(link_us, 1000)
        Mix.shell().info(NPM.DepsOutput.format_summary(total, ms))
        warn_ignored_install_scripts(lockfile)
        Mix.shell().info(NPM.DepsOutput.format_lockfile(lockfile))
        :ok

      error ->
        error
    end
  end

  defp linkable_lockfile(lockfile, skipped) do
    Enum.reject(lockfile, fn {name, _entry} -> MapSet.member?(skipped, name) end)
  end

  defp registry_package_intact?(package_dir, version, strategy) do
    with {:ok, %File.Stat{type: type}} <- File.lstat(package_dir),
         true <- type == :directory or (type == :symlink and strategy == :symlink),
         {:ok, %{"version" => ^version}} <-
           NPM.JSON.read_file(Path.join(package_dir, "package.json")) do
      true
    else
      _ ->
        false
    end
  end

  defp plural(map) do
    if map_size(map) == 1, do: "", else: "s"
  end

  defp build_lockfile(resolved) do
    lockfile = LockfileBuilder.build(resolved, &warn_age_heuristics/3)

    warn_unmet_peers(resolved)
    lockfile
  end

  defp build_nested_lockfile(nested_info, _flat, _overrides) when map_size(nested_info) == 0,
    do: %{}

  defp build_nested_lockfile(nested_info, flat, overrides) do
    Enum.reduce(nested_info, %{}, fn {nested_pkg, _}, acc ->
      original_deps = NPM.Resolver.get_original_deps(nested_pkg)

      Enum.reduce(flat, acc, fn {parent_name, parent_version}, inner_acc ->
        range = Map.get(original_deps, "#{parent_name}@#{parent_version}")
        range = if range, do: Map.get(overrides, nested_pkg, range), else: nil

        case nested_lockfile_entry(nested_pkg, range) do
          {:ok, entry} ->
            Map.put(
              inner_acc,
              "node_modules/#{parent_name}/node_modules/#{nested_pkg}",
              entry
            )

          :error ->
            inner_acc
        end
      end)
    end)
  end

  defp nested_lockfile_entry(_name, nil), do: :error

  defp nested_lockfile_entry(name, range) do
    case resolve_version(name, range) do
      {:ok, version_str, info} ->
        {:ok,
         %{
           version: version_str,
           integrity: info.dist.integrity,
           tarball: info.dist.tarball,
           dependencies: info.dependencies,
           optional_dependencies: Map.get(info, :optional_dependencies, %{}),
           has_install_script: Map.get(info, :has_install_script, false)
         }}

      :error ->
        :error
    end
  end

  defp expand_all_dependencies(
         lockfile,
         nested_lockfile,
         local_links,
         overrides,
         preferred \\ %{}
       ) do
    lockfile
    |> lockfile_locations(nested_lockfile)
    |> Enum.reduce({lockfile, nested_lockfile}, fn {location, entry}, state ->
      expand_entry_dependencies(entry, location, state, local_links, overrides, preferred)
    end)
  end

  defp expand_entry_dependencies(entry, location, state, local_links, overrides, preferred) do
    optional = Map.get(entry, :optional_dependencies, %{})
    inherited_optional? = Map.get(entry, :optional, false)

    Enum.reduce(effective_dependencies(entry, overrides), state, fn {name, _range} = dependency,
                                                                    acc ->
      optional? = inherited_optional? or Map.has_key?(optional, name)
      expand_dependency(dependency, location, acc, optional?, local_links, overrides, preferred)
    end)
  end

  defp expand_dependency(
         {name, range},
         parent_location,
         {flat, nested} = state,
         optional?,
         local_links,
         overrides,
         preferred
       ) do
    if Map.has_key?(local_links, name) or
         dependency_satisfied?(name, range, parent_location, flat, nested) do
      state
    else
      case resolve_entry(name, range, preferred) do
        {:ok, entry} ->
          entry =
            if optional?, do: Map.put(entry, :optional, true), else: Map.delete(entry, :optional)

          {state, installed_location} =
            put_expanded_dependency(name, entry, parent_location, flat, nested)

          expand_entry_dependencies(
            entry,
            installed_location,
            state,
            local_links,
            overrides,
            preferred
          )

        :error ->
          state
      end
    end
  end

  defp resolve_entry(name, range, preferred) do
    case Enum.find(Map.get(preferred, name, []), &lockfile_entry_satisfies_range?(&1, range)) do
      nil ->
        case resolve_version(name, range) do
          {:ok, version, info} ->
            warn_age_heuristics(name, version, info)

            {:ok,
             %{
               version: version,
               integrity: info.dist.integrity,
               tarball: info.dist.tarball,
               dependencies: info.dependencies,
               optional_dependencies: Map.get(info, :optional_dependencies, %{}),
               has_install_script: Map.get(info, :has_install_script, false)
             }}

          :error ->
            :error
        end

      entry ->
        {:ok, entry}
    end
  end

  defp dependency_satisfied?(name, range, parent_location, flat, nested) do
    case nearest_dependency_entry(name, parent_location, flat, nested) do
      nil -> false
      entry -> lockfile_entry_satisfies_range?(entry, range)
    end
  end

  defp nearest_dependency_entry(name, parent_location, flat, nested) do
    flat
    |> lockfile_locations(nested)
    |> frozen_dependency_entry(parent_location, name)
  end

  defp put_expanded_dependency(name, entry, "", flat, nested) do
    {{Map.put(flat, name, entry), nested}, "node_modules/#{name}"}
  end

  defp put_expanded_dependency(name, entry, parent_location, flat, nested) do
    if nearest_dependency_entry(name, parent_location, flat, nested) != nil do
      location = "#{parent_location}/node_modules/#{name}"
      {{flat, Map.put(nested, location, entry)}, location}
    else
      location = "node_modules/#{name}"
      {{Map.put(flat, name, entry), nested}, location}
    end
  end

  defp resolve_version(name, range) do
    case NPM.Registry.get_packument(name) do
      {:ok, packument} ->
        packument.versions
        |> Enum.filter(fn {v, _} ->
          NPMSemver.matches?(v, range) and match?({:ok, _}, Version.parse(v))
        end)
        |> Enum.sort_by(fn {v, _} -> Version.parse!(v) end, {:desc, Version})
        |> case do
          [{version_str, info} | _] ->
            ExoticDeps.validate!(name, version_str, info)
            {:ok, version_str, info}

          [] ->
            :error
        end

      _ ->
        :error
    end
  end

  defp warn_age_heuristics(name, version, info) do
    info
    |> Age.warnings()
    |> Enum.each(fn warning ->
      Mix.shell().info("Warning: #{Age.format(name, version, warning)}")
    end)
  end

  defp warn_unmet_peers(resolved) do
    Enum.each(resolved, fn {name, version_str} ->
      case NPM.Registry.get_packument(name) do
        {:ok, packument} ->
          info = Map.fetch!(packument.versions, version_str)
          check_peers(name, info, resolved)
          check_deprecated(name, version_str, info)

        _ ->
          :ok
      end
    end)
  end

  defp warn_ignored_install_scripts(lockfile) do
    packages =
      lockfile
      |> Enum.filter(fn {_name, entry} -> Map.get(entry, :has_install_script, false) end)
      |> Enum.map_join(", ", fn {name, entry} -> "#{name}@#{entry.version}" end)

    if packages != "" do
      Mix.shell().info(
        "npm WARN ignored lifecycle scripts for #{packages}. " <>
          "npm_ex never runs preinstall/install/postinstall hooks automatically."
      )
    end
  end

  defp check_deprecated(name, version, info) do
    case Map.get(info, :deprecated) do
      nil ->
        :ok

      false ->
        :ok

      msg when is_binary(msg) ->
        Mix.shell().info("npm WARN #{name}@#{version} is deprecated: #{msg}")

      _ ->
        :ok
    end
  end

  defp check_peers(name, info, resolved) do
    peers = Map.get(info, :peer_dependencies, %{})
    meta = Map.get(info, :peer_dependencies_meta, %{})

    Enum.each(peers, fn {peer_name, peer_range} ->
      optional? = get_in(meta, [peer_name, "optional"]) == true

      case Map.get(resolved, peer_name) do
        nil when not optional? ->
          Mix.shell().info(
            "npm WARN #{name} requires peer #{peer_name}@#{peer_range} — not installed"
          )

        _ ->
          :ok
      end
    end)
  end

  defp resolve_latest(name, opts) do
    case NPM.Registry.get_packument(name) do
      {:ok, packument} -> latest_stable_range(packument, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp latest_stable_range(packument, opts) do
    packument.versions
    |> Map.keys()
    |> Enum.flat_map(&parse_stable_version/1)
    |> Enum.sort(Version)
    |> List.last()
    |> case do
      nil -> {:error, :no_versions}
      v -> if opts[:exact], do: "#{v}", else: "^#{v}"
    end
  end

  defp parse_stable_version(v) do
    case Version.parse(v) do
      {:ok, ver} -> if ver.pre == [], do: [ver], else: []
      :error -> []
    end
  end

  defp print_lockfile_diff(old, new) when old == %{}, do: new
  defp print_lockfile_diff(old, new) when old == new, do: :ok

  defp print_lockfile_diff(old, new) do
    diff = NPM.DepsOutput.format_diff(old, new)
    if diff != "", do: Mix.shell().info(diff)
  end

  defp format_ms(microseconds) do
    ms = div(microseconds, 1000)
    if ms < 1000, do: "#{ms}ms", else: "#{Float.round(ms / 1000, 1)}s"
  end
end
