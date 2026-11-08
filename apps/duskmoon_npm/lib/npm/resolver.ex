defmodule NPM.Resolver do
  alias NPM.Security.ExoticDeps
  alias NPM.Security.RegistryPolicy

  @moduledoc """
  `HexSolver.Registry` implementation for npm packages.

  Bridges the npm registry to hex_solver's PubGrub dependency resolver.
  Packuments and solver state are isolated in a caller-owned ETS table for the
  duration of each resolution. Original dependency ranges remain available to
  that caller through `get_original_deps/1` after the table is deleted.
  """

  @behaviour HexSolver.Registry

  defmodule PrefetchError do
    @moduledoc "Raised when resolver prefetching fails before PubGrub can run."

    defexception [:reason]

    @impl true
    def message(%__MODULE__{reason: reason}) do
      "npm dependency prefetch failed: #{NPM.Resolver.format_prefetch_reason(reason)}"
    end
  end

  defmodule SpecError do
    @moduledoc "Raised when a dependency spec cannot be turned into a registry constraint."

    defexception [:package, :version, :dependency, :spec, :reason]

    @impl true
    def message(%__MODULE__{package: nil} = error) do
      "#{error.dependency}: #{inspect(error.spec)} #{error.reason}"
    end

    def message(%__MODULE__{} = error) do
      "#{error.package}@#{error.version} depends on #{error.dependency}: " <>
        "#{inspect(error.spec)} #{error.reason}"
    end
  end

  @cache_key {__MODULE__, :cache}
  @original_deps_key {__MODULE__, :original_deps}
  @dist_tag_regex ~r/^[A-Za-z][A-Za-z0-9._-]*$/
  @max_nesting_depth 128
  @max_prefetch_depth 10
  @prefetch_concurrency 16

  @doc """
  Resolve a set of root dependencies to exact versions.

  Uses a two-phase approach:
  1. Try flat resolution with PubGrub
  2. On conflict, identify conflicting packages and retry with
     those excluded, tracking them as nested dependencies

  Returns `{:ok, %{name => version}}` where the map includes
  a `:nested` key with nested package info when version conflicts exist.
  """
  @spec resolve(%{String.t() => String.t()}, keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def resolve(root_deps, opts \\ [])

  def resolve(root_deps, _opts) when map_size(root_deps) == 0 do
    Process.delete(@original_deps_key)
    {:ok, %{}}
  end

  def resolve(root_deps, opts) do
    table = :ets.new(__MODULE__, [:set, :public])
    previous_cache = Process.put(@cache_key, table)
    Process.delete(@original_deps_key)

    try do
      overrides = Keyword.get(opts, :overrides, %{})
      if overrides != %{}, do: store_overrides(overrides)
      store_resolver_opts(opts)
      result = resolve_with_nesting(root_deps, MapSet.new(), %{}, 0, opts)

      if match?({:ok, _}, result) do
        original_deps =
          :ets.foldl(
            fn
              {{:__original_deps__, package}, deps}, acc -> Map.put(acc, package, deps)
              _, acc -> acc
            end,
            %{},
            table
          )

        Process.put(@original_deps_key, original_deps)
      end

      result
    rescue
      error in [ExoticDeps.Error, PrefetchError, RegistryPolicy.Error, SpecError] ->
        {:error, Exception.message(error)}
    after
      :ets.delete(table)

      if previous_cache do
        Process.put(@cache_key, previous_cache)
      else
        Process.delete(@cache_key)
      end
    end
  end

  defp store_resolver_opts(opts) do
    :ets.insert(cache_table(), {:__resolver_opts__, Keyword.take(opts, [:prefetch_timeout])})
  end

  defp get_resolver_opts do
    case :ets.lookup(cache_table(), :__resolver_opts__) do
      [{_, opts}] -> opts
      [] -> []
    end
  end

  defp store_overrides(overrides) do
    :ets.insert(cache_table(), {:__overrides__, overrides})
  end

  defp get_overrides do
    case :ets.lookup(cache_table(), :__overrides__) do
      [{_, overrides}] -> overrides
      [] -> %{}
    end
  end

  @doc false
  def prefetch_timeout(opts \\ []) do
    Keyword.get(opts, :prefetch_timeout) || NPM.Config.prefetch_timeout()
  end

  defp resolve_with_nesting(_root_deps, _excluded, _nested, depth, _opts)
       when depth > @max_nesting_depth do
    {:error, "Too many resolution retries — deeply conflicting dependencies"}
  end

  defp resolve_with_nesting(root_deps, excluded, nested, depth, opts) do
    case prefetch_tree(Map.keys(root_deps), opts) do
      :ok ->
        dependencies = build_dependencies(root_deps)

        case run_solver(dependencies, excluded) do
          {:ok, result} ->
            final = if nested == %{}, do: result, else: Map.put(result, :nested, nested)
            {:ok, final}

          {:error, message} ->
            conflict_packages =
              message
              |> extract_conflict_packages()
              |> Enum.reject(&MapSet.member?(excluded, &1))

            if conflict_packages != [] do
              new_nested = collect_nested_versions(conflict_packages)
              merged_nested = Map.merge(nested, new_nested)
              new_excluded = Enum.reduce(conflict_packages, excluded, &MapSet.put(&2, &1))
              resolve_with_nesting(root_deps, new_excluded, merged_nested, depth + 1, opts)
            else
              {:error, message}
            end
        end

      {:error, reason} ->
        {:error, prefetch_error_message(reason)}
    end
  end

  defp build_dependencies(root_deps) do
    ensure_packuments!(Map.keys(root_deps))
    Enum.map(root_deps, fn {name, range} -> to_solver_dep({name, range, false}, nil) end)
  end

  defp run_solver(dependencies, excluded) do
    ensure_cache()
    put_excluded(excluded)

    # Remove excluded packages from the version cache to prevent stale data
    if MapSet.size(excluded) > 0, do: strip_excluded_from_cache(excluded)

    case HexSolver.run(__MODULE__, dependencies, [], []) do
      {:ok, solution} ->
        result =
          for {name, {version, _repo}} <- solution, into: %{}, do: {name, to_string(version)}

        {:ok, result}

      {:error, message} ->
        {:error, message}
    end
  end

  defp put_excluded(excluded) do
    ensure_cache()
    :ets.insert(cache_table(), {:__excluded_packages__, excluded})
  end

  defp get_excluded do
    case :ets.lookup(cache_table(), :__excluded_packages__) do
      [{_, excluded}] -> excluded
      [] -> MapSet.new()
    end
  end

  defp strip_excluded_from_cache(excluded) do
    # Delete excluded packages entirely from the cache
    Enum.each(excluded, &:ets.delete(cache_table(), &1))

    # Strip excluded deps from all cached packuments (skip non-packument entries)
    :ets.foldl(
      fn
        {_name, %{versions: _} = packument} = entry, acc ->
          stripped = strip_deps(packument, excluded)
          if stripped != packument, do: :ets.insert(cache_table(), put_elem(entry, 1, stripped))
          acc

        _, acc ->
          acc
      end,
      :ok,
      cache_table()
    )
  end

  defp strip_deps(packument, excluded) do
    versions =
      Map.new(packument.versions, fn {ver, info} ->
        deps = Map.drop(info.dependencies, MapSet.to_list(excluded))
        {ver, %{info | dependencies: deps}}
      end)

    %{packument | versions: versions}
  end

  @doc false
  def extract_conflict_package(message) do
    message
    |> extract_conflict_packages()
    |> List.first()
  end

  @doc false
  def extract_conflict_packages(message) do
    [
      extract_repeated_dependency_targets(message),
      extract_dependency_pair_conflicts(message),
      extract_exact_version_conflicts(message)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp extract_repeated_dependency_targets(message) do
    message
    |> dependency_target_names()
    |> repeated_package_names()
  end

  defp extract_dependency_pair_conflicts(message) do
    ~r/depends on "([^"]+)" and "[^"]+" depends on "([^"]+)"/
    |> Regex.scan(message)
    |> Enum.flat_map(fn [_, left, right] ->
      with {:ok, left_name} <- package_name_from_term(left),
           {:ok, right_name} <- package_name_from_term(right),
           true <- left_name == right_name do
        [left_name]
      else
        _ -> []
      end
    end)
  end

  defp extract_exact_version_conflicts(message) do
    # Look for patterns like: "ms 2.0.0" and "ms 2.1.3" in the error
    case Regex.scan(~r/"(\S+) (\d+\.\d+\.\d+)"/, message) do
      [_, _ | _] = matches ->
        names = Enum.map(matches, fn [_, name, _] -> name end)
        repeated_package_names(names)

      _ ->
        []
    end
  end

  defp dependency_target_names(message) do
    ~r/depends on "([^"]+)"/
    |> Regex.scan(message)
    |> Enum.map(fn [_, term] -> package_name_from_term(term) end)
    |> Enum.flat_map(fn
      {:ok, name} -> [name]
      :error -> []
    end)
  end

  defp package_name_from_term(term) do
    case Regex.run(~r/^(@[^\/\s]+\/[^\s]+|[^\s]+)\s+.+$/, term) do
      [_, name] -> {:ok, name}
      _ -> :error
    end
  end

  defp repeated_package_names(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count >= 2 end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc false
  def get_original_deps(package) do
    @original_deps_key
    |> Process.get(%{})
    |> Map.get(package, %{})
  end

  defp collect_nested_versions(packages) do
    # Before stripping, save the original dependency data
    # so the linker can look up which parents need which version
    Map.new(packages, fn package ->
      save_original_deps(package)
      {package, :nested}
    end)
  end

  defp save_original_deps(package) do
    parent_deps =
      :ets.foldl(
        fn
          {name, %{versions: _} = packument}, acc ->
            find_dependents(name, packument, package, acc)

          _, acc ->
            acc
        end,
        %{},
        cache_table()
      )

    :ets.insert(cache_table(), {{:__original_deps__, package}, parent_deps})
  end

  defp find_dependents(name, %{versions: versions}, package, acc) do
    Enum.reduce(versions, acc, fn {ver, info}, inner_acc ->
      case info |> version_dependencies() |> Map.get(package) do
        nil -> inner_acc
        range -> Map.put(inner_acc, "#{name}@#{ver}", range)
      end
    end)
  end

  defp version_dependencies(%{dependencies: deps}) when is_map(deps), do: deps
  defp version_dependencies(%{"dependencies" => deps}) when is_map(deps), do: deps
  defp version_dependencies(_info), do: %{}

  @doc "Clear the current caller's packument cache and saved original dependency ranges."
  @spec clear_cache() :: :ok
  def clear_cache do
    if table = Process.delete(@cache_key), do: :ets.delete(table)
    Process.delete(@original_deps_key)
    :ok
  end

  # --- HexSolver.Registry callbacks ---

  @impl true
  def versions(_repo, package) do
    case get_cached_packument(package) do
      {:ok, packument} -> {:ok, parse_sorted_versions(packument)}
      {:error, _} -> :error
    end
  end

  @impl true
  def dependencies(_repo, package, version) do
    case get_cached_packument(package) do
      {:ok, packument} -> deps_for_version(package, packument, to_string(version))
      {:error, _} -> :error
    end
  end

  @impl true
  def prefetch(packages) do
    packages
    |> Enum.map(fn {_repo, name} -> name end)
    |> Enum.reject(&cached?/1)
    |> prefetch_packages(get_resolver_opts())
    |> case do
      :ok -> :ok
      {:error, reason} -> raise PrefetchError, reason: reason
    end
  end

  # --- Helpers ---

  @doc false
  def collect_prefetch_results(results) do
    Enum.reduce_while(results, :ok, fn
      {:ok, {:ok, _packument}}, :ok ->
        {:cont, :ok}

      {:ok, {:error, reason}}, :ok ->
        {:halt, {:error, reason}}

      {:exit, reason}, :ok ->
        {:halt, {:error, reason}}
    end)
  end

  @doc false
  def format_prefetch_reason({%{__exception__: true} = error, _stack}) do
    Exception.message(error)
  end

  def format_prefetch_reason(%{__exception__: true} = error), do: Exception.message(error)
  def format_prefetch_reason(reason), do: inspect(reason)

  defp prefetch_error_message(reason), do: Exception.message(%PrefetchError{reason: reason})

  # Prerelease versions are always candidates; each requirement's constraint
  # excludes the prereleases npm semantics would not let it match.
  defp parse_sorted_versions(packument) do
    key = {:__sorted_versions__, packument.name}

    case :ets.lookup(cache_table(), key) do
      [{^key, versions}] ->
        versions

      [] ->
        versions = do_parse_sorted_versions(packument)
        :ets.insert(cache_table(), {key, versions})
        versions
    end
  end

  defp do_parse_sorted_versions(packument) do
    packument.versions
    |> Enum.reject(fn {version_str, info} ->
      exotic_candidate?(packument.name, version_str, info)
    end)
    |> Enum.flat_map(fn {v, _info} ->
      case Version.parse(v) do
        {:ok, version} -> [version]
        :error -> []
      end
    end)
    |> Enum.sort(Version)
  end

  defp exotic_candidate?(package, version_str, info) do
    case validate_version(package, version_str, info) do
      :ok -> false
      {:error, %ExoticDeps.Error{}} -> true
    end
  end

  defp deps_for_version(package, packument, version_str) do
    excluded = get_excluded()

    case Map.get(packument.versions, version_str) do
      nil ->
        :error

      info ->
        validate_version!(package, version_str, info)
        overrides = get_overrides()

        deps =
          info
          |> solver_dependencies(package, excluded, overrides)
          |> to_solver_deps({package, version_str})

        {:ok, deps}
    end
  end

  defp validate_version!(package, version_str, info) do
    case validate_version(package, version_str, info) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp validate_version(package, version_str, info) do
    key = {:__exotic_validation__, package, version_str}

    case :ets.lookup(cache_table(), key) do
      [{^key, result}] ->
        result

      [] ->
        result =
          try do
            ExoticDeps.validate!(package, version_str, info)
            :ok
          rescue
            error in ExoticDeps.Error -> {:error, error}
          end

        :ets.insert(cache_table(), {key, result})
        result
    end
  end

  defp solver_dependencies(info, self_name, excluded, overrides) do
    optional_dependency_names = Map.keys(info.optional_dependencies)

    required =
      info.dependencies
      |> Enum.reject(fn {name, _} ->
        name == self_name or name in optional_dependency_names or
          MapSet.member?(excluded, name)
      end)
      |> Enum.map(fn {name, range} -> {name, Map.get(overrides, name, range), false} end)

    optional =
      info.optional_dependencies
      |> NPM.PlatformOptional.select()
      |> Enum.reject(fn {name, _} ->
        name == self_name or MapSet.member?(excluded, name)
      end)
      |> Enum.map(fn {name, range} -> {name, Map.get(overrides, name, range), false} end)

    required ++ optional
  end

  defp to_solver_deps(deps, parent) do
    deps |> Enum.map(&elem(&1, 0)) |> ensure_packuments!()
    Enum.map(deps, &to_solver_dep(&1, parent))
  end

  defp to_solver_dep({name, spec, optional?}, parent) do
    %{
      repo: nil,
      name: name,
      constraint: requirement_constraint!(name, spec, parent),
      optional: optional?,
      label: name,
      dependencies: []
    }
  end

  defp ensure_packuments!(names) do
    names
    |> Enum.uniq()
    |> Enum.reject(&cached?/1)
    |> prefetch_packages(get_resolver_opts())
    |> case do
      :ok -> :ok
      {:error, reason} -> raise PrefetchError, reason: reason
    end
  end

  defp requirement_constraint!(name, spec, parent) do
    key = {:__constraint__, name, spec}

    case :ets.lookup(cache_table(), key) do
      [{^key, constraint}] ->
        constraint

      [] ->
        constraint = build_constraint!(name, spec, parent)
        :ets.insert(cache_table(), {key, constraint})
        constraint
    end
  end

  defp build_constraint!(name, spec, parent) do
    packument =
      case get_cached_packument(name) do
        {:ok, packument} -> packument
        {:error, _} -> nil
      end

    range_string = effective_range!(name, spec, packument, parent)

    with {:ok, range} <- NPMSemver.parse_range(range_string),
         {:ok, constraint} <- NPMSemver.to_hex_constraint(range_string) do
      exclude_disallowed_prereleases(constraint, range, packument)
    else
      :error -> raise_spec_error!(name, spec, parent, "is not a valid semver range or dist-tag")
    end
  end

  defp effective_range!(name, spec, packument, parent) when is_binary(spec) do
    trimmed = String.trim(spec)

    cond do
      match?({:ok, _}, NPMSemver.parse_range(trimmed)) ->
        trimmed

      String.starts_with?(trimmed, "npm:") ->
        raise_spec_error!(name, spec, parent, "uses an npm: alias, which is not supported here")

      Regex.match?(@dist_tag_regex, trimmed) ->
        dist_tag_version!(name, spec, trimmed, packument, parent)

      true ->
        raise_spec_error!(name, spec, parent, "is not a valid semver range or dist-tag")
    end
  end

  defp effective_range!(name, spec, _packument, parent) do
    raise_spec_error!(name, spec, parent, "is not a valid semver range or dist-tag")
  end

  defp dist_tag_version!(name, spec, tag, packument, parent) do
    case packument_dist_tags(packument) do
      # The packument carries no dist-tag data at all, so `latest` falls back to
      # the highest stable version, which is what the registry's `latest` tag
      # points to unless a publisher retargeted it.
      nil when tag == "latest" ->
        "*"

      nil ->
        raise_spec_error!(name, spec, parent, "names a dist-tag but no dist-tags are available")

      tags ->
        case Map.get(tags, tag) do
          version when is_binary(version) and is_map_key(packument.versions, version) ->
            version

          nil ->
            raise_spec_error!(
              name,
              spec,
              parent,
              "names dist-tag #{inspect(tag)}, which is not published"
            )

          version ->
            raise_spec_error!(
              name,
              spec,
              parent,
              "names dist-tag #{inspect(tag)}, which points to unknown version #{inspect(version)}"
            )
        end
    end
  end

  defp packument_dist_tags(%{dist_tags: tags}) when is_map(tags) and map_size(tags) > 0, do: tags
  defp packument_dist_tags(%{"dist-tags" => tags}) when is_map(tags), do: tags
  defp packument_dist_tags(_packument), do: nil

  defp raise_spec_error!(name, spec, {package, version}, reason) do
    raise SpecError,
      package: package,
      version: version,
      dependency: name,
      spec: spec,
      reason: reason
  end

  defp raise_spec_error!(name, spec, nil, reason) do
    raise SpecError, dependency: name, spec: spec, reason: reason
  end

  # npm (includePrerelease=false): a prerelease satisfies a range only when the
  # same comparator set names a prerelease on the same [major, minor, patch].
  # hex_solver ranges have no such rule, so carve the disallowed prereleases
  # found in the packument out of this requirement's constraint.
  defp exclude_disallowed_prereleases(constraint, _range, nil), do: constraint

  defp exclude_disallowed_prereleases(constraint, range, packument) do
    prerelease_tuples = prerelease_tuples(range)

    packument.versions
    |> Map.keys()
    |> Enum.flat_map(&disallowed_prerelease(&1, range))
    |> Enum.map(&prerelease_exclusion(&1, prerelease_tuples))
    |> Enum.uniq()
    |> case do
      [] ->
        constraint

      exclusions ->
        excluded = exclusions |> Enum.map(&HexSolver.parse_constraint!/1) |> union_constraints()
        HexSolver.Constraint.difference(constraint, excluded)
    end
  end

  defp disallowed_prerelease(version_str, range) do
    with {:ok, %Version{pre: [_ | _]}} <- Version.parse(version_str),
         {:ok, version} <- NPMSemver.parse_version(version_str),
         true <- NPMSemver.Range.satisfies?(range, version, include_prerelease: true),
         false <- NPMSemver.Range.satisfies?(range, version) do
      [{version_str, version}]
    else
      _ -> []
    end
  end

  defp prerelease_exclusion({version_str, version}, prerelease_tuples) do
    tuple = {version.major, version.minor, version.patch}

    if MapSet.member?(prerelease_tuples, tuple) do
      "== #{version_str}"
    else
      release = "#{version.major}.#{version.minor}.#{version.patch}"
      ">= #{release}-0 and < #{release}"
    end
  end

  defp prerelease_tuples(%NPMSemver.Range{sets: sets}) do
    for comparators <- sets,
        {_op, %NPMSemver.Version{pre: [_ | _]} = version} <- comparators,
        into: MapSet.new(),
        do: {version.major, version.minor, version.patch}
  end

  defp union_constraints([first | rest]) do
    Enum.reduce(rest, first, &HexSolver.Constraint.union(&2, &1))
  end

  # --- Cache ---

  defp ensure_cache do
    cache_table()
    :ok
  end

  defp cache_table do
    case Process.get(@cache_key) do
      nil ->
        table = :ets.new(__MODULE__, [:set, :public])
        Process.put(@cache_key, table)
        table

      table ->
        table
    end
  end

  defp cached?(package) do
    :ets.info(cache_table()) != :undefined and :ets.member(cache_table(), package)
  end

  defp get_cached_packument(package) do
    ensure_cache()

    case :ets.lookup(cache_table(), package) do
      [{^package, packument}] -> {:ok, packument}
      [] -> fetch_and_cache(package)
    end
  end

  defp fetch_and_cache(package, table \\ cache_table()) do
    case NPM.Registry.get_packument(package) do
      {:ok, packument} ->
        :ets.insert(table, {package, packument})
        {:ok, packument}

      error ->
        error
    end
  end

  defp prefetch_packages([], _opts), do: :ok

  defp prefetch_packages(packages, opts) do
    table = cache_table()

    packages
    |> Task.async_stream(&safe_fetch_and_cache(&1, table),
      max_concurrency: @prefetch_concurrency,
      timeout: prefetch_timeout(opts),
      ordered: false,
      on_timeout: :kill_task
    )
    |> collect_prefetch_results()
  end

  defp safe_fetch_and_cache(package, table) do
    fetch_and_cache(package, table)
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp prefetch_tree(packages, opts), do: prefetch_tree(packages, 0, opts)
  defp prefetch_tree(_packages, depth, _opts) when depth > @max_prefetch_depth, do: :ok

  defp prefetch_tree(packages, depth, opts) do
    to_fetch = Enum.reject(packages, &cached?/1)

    case prefetch_packages(to_fetch, opts) do
      :ok ->
        next_level =
          to_fetch
          |> Enum.flat_map(&dep_names_from_cache/1)
          |> Enum.uniq()
          |> Enum.reject(&cached?/1)

        if next_level != [] do
          prefetch_tree(next_level, depth + 1, opts)
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dep_names_from_cache(package) do
    case :ets.lookup(cache_table(), package) do
      [{_, packument}] ->
        case latest_version_info(packument) do
          nil -> []
          info -> Map.keys(info.dependencies)
        end

      [] ->
        []
    end
  end

  defp latest_version_info(packument) do
    packument.versions
    |> Map.keys()
    |> Enum.flat_map(fn v ->
      case Version.parse(v) do
        {:ok, ver} -> [{v, ver}]
        :error -> []
      end
    end)
    |> Enum.reject(fn {_, ver} -> ver.pre != [] end)
    |> Enum.sort_by(&elem(&1, 1), {:desc, Version})
    |> case do
      [{latest_str, _} | _] -> Map.get(packument.versions, latest_str)
      [] -> nil
    end
  end
end
