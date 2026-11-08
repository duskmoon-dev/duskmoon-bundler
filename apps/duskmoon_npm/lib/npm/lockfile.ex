defmodule NPM.Lockfile.InvalidEntryError do
  @moduledoc "Raised when a lockfile entry has an unsafe package name, location, or version."
  defexception [:location, :reason]

  @impl true
  def message(%{location: location, reason: reason}),
    do: "invalid lockfile entry #{inspect(location)}: #{inspect(reason)}"
end

defmodule NPM.Lockfile do
  @moduledoc """
  Read and write npm `package-lock.json` lockfiles.

  The lockfile records resolved versions, integrity hashes, and dependency
  relationships to ensure reproducible installs.

  Entries are validated while reading: package names must be installable npm
  names and versions strict semver, because both become filesystem paths.
  `read/1`, `read_nested/1`, `migrate_legacy/2` and `all_package_names/1`
  return `{:error, {:invalid_lockfile_entry, location, reason}}` for unsafe
  entries; `parse/1` and `parse_packages/1` raise `NPM.Lockfile.InvalidEntryError`.
  """

  alias NPM.Lockfile.InvalidEntryError

  alias NPM.Config
  alias NPM.Security.RegistryPolicy

  @default_path "package-lock.json"
  @legacy_path "npm.lock"
  @npm_ex_metadata "x-npm-ex"
  @package_lock_version 3
  @package_metadata_fields ~w(name version workspaces dependencies devDependencies optionalDependencies peerDependencies)
  @dependency_metadata_fields ~w(dependencies devDependencies optionalDependencies peerDependencies)

  @type entry :: %{
          optional(:peer_dependencies) => %{String.t() => String.t()},
          optional(:peer_dependencies_meta) => %{String.t() => map()},
          optional(:peer) => true,
          version: String.t(),
          integrity: String.t(),
          tarball: String.t(),
          dependencies: %{String.t() => String.t()},
          optional_dependencies: %{String.t() => String.t()},
          has_install_script: boolean()
        }

  @type t :: %{String.t() => entry()}

  @doc "Return the default npm_ex lockfile path."
  @spec default_path :: String.t()
  def default_path, do: @default_path

  @doc "Return the legacy npm_ex lockfile path."
  @spec legacy_path :: String.t()
  def legacy_path, do: @legacy_path

  @doc "Read the lockfile. Returns empty map if it doesn't exist."
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path \\ @default_path)

  def read(@default_path) do
    cond do
      File.exists?(@default_path) -> read_file(@default_path)
      File.exists?(@legacy_path) -> migrate_legacy()
      true -> {:ok, %{}}
    end
  end

  def read(path) do
    read_file(path)
  end

  @doc false
  @spec read_nested(String.t()) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def read_nested(path \\ @default_path) do
    with_valid_entries(fn -> read_nested_json(path) end)
  end

  defp read_nested_json(path) do
    case read_json(path) do
      {:ok, %{"packages" => packages} = data} when is_map(packages) ->
        if package_lock?(data, packages) do
          parse_nested_package_lock_packages(packages)
        else
          {:ok, %{}}
        end

      {:ok, _data} ->
        {:ok, %{}}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Migrates the legacy `npm.lock` schema to `package-lock.json` v3.

  The legacy file is left in place so callers can decide when to remove it.
  """
  @spec migrate_legacy(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def migrate_legacy(legacy_path \\ @legacy_path, target_path \\ @default_path) do
    with {:ok, data} <- read_json(legacy_path),
         {:ok, lockfile} <-
           with_valid_entries(fn ->
             {:ok, parse_legacy_packages(Map.get(data, "packages", %{}))}
           end),
         policy <- lockfile_policy(data),
         :ok <- write_package_lock(lockfile, target_path, policy) do
      {:ok, lockfile}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        data = NPM.JSON.decode!(content)
        with_valid_entries(fn -> {:ok, parse_data(data)} end)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_valid_entries(fun) do
    fun.()
  rescue
    error in InvalidEntryError ->
      {:error, {:invalid_lockfile_entry, error.location, error.reason}}
  end

  # Names and versions become cache and node_modules paths, so reject anything
  # that is not an installable npm name or a strict semver version.
  defp validate_entry!(location, name, entry) do
    case NPM.Cache.validate_package(name, entry.version) do
      :ok -> entry
      {:error, reason} -> raise InvalidEntryError, location: location, reason: reason
    end
  end

  @doc "Write the lockfile."
  @spec write(t(), String.t() | keyword(), keyword()) :: :ok | {:error, term()}
  def write(lockfile, path \\ @default_path, opts \\ [])

  def write(lockfile, opts, []) when is_list(opts) do
    write(lockfile, @default_path, opts)
  end

  def write(lockfile, path, opts) do
    if legacy_path?(path) do
      write_legacy(lockfile, path, current_policy())
    else
      write_package_lock(lockfile, path, current_policy(), opts)
    end
  end

  defp write_package_lock(lockfile, path, policy, opts \\ []) do
    root_data = read_root_package()
    packages = package_lock_packages(lockfile, root_data, opts)
    packages = if opts[:preserve], do: preserve_package_records(packages, path), else: packages

    data =
      %{
        "lockfileVersion" => @package_lock_version,
        "requires" => true,
        "packages" => packages,
        @npm_ex_metadata => %{"policy" => policy}
      }
      |> maybe_put("name", root_data["name"])
      |> maybe_put("version", root_data["version"])

    File.write(path, NPM.JSON.encode_pretty(data))
  end

  defp preserve_package_records(packages, path) do
    previous =
      case read_json(path) do
        {:ok, %{"packages" => previous, "lockfileVersion" => version}} when version in [2, 3] ->
          previous

        _ ->
          %{}
      end

    Map.new(packages, fn {location, record} ->
      old = Map.get(previous, location, %{})

      preserved =
        cond do
          record["link"] == true ->
            Map.merge(old, record)

          match?({:ok, _}, package_name_from_any_location(location)) ->
            if package_lock_entry_from_info(old) == package_lock_entry_from_info(record),
              do: old,
              else: record

          true ->
            old
            |> Map.drop(
              ~w(name version workspaces dependencies devDependencies optionalDependencies peerDependencies)
            )
            |> Map.merge(record)
        end

      {location, preserved}
    end)
  end

  defp write_legacy(lockfile, path, policy) do
    data = %{
      "lockfileVersion" => 1,
      "policy" => policy,
      "packages" => serialize_legacy(lockfile)
    }

    File.write(path, NPM.JSON.encode_pretty(data))
  end

  @doc "Read the security policy recorded in the lockfile."
  @spec read_policy(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def read_policy(path \\ @default_path)

  def read_policy(@default_path) do
    cond do
      File.exists?(@default_path) -> read_policy_file(@default_path)
      File.exists?(@legacy_path) -> read_policy_file(@legacy_path)
      true -> {:ok, nil}
    end
  end

  def read_policy(path), do: read_policy_file(path)

  defp read_policy_file(path) do
    case read_json(path) do
      {:ok, data} -> {:ok, lockfile_policy(data)}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the effective lockfile security policy for new locks."
  @spec current_policy :: map()
  def current_policy do
    %{
      "block_exotic_subdeps" => Config.block_exotic_subdeps?(),
      "exotic_deps" => Config.exotic_deps(),
      "allowed_registries" => RegistryPolicy.allowed_origins(),
      "allow_registry_redirects" => Config.allow_registry_redirects?()
    }
  end

  @doc "Whether a recorded lockfile policy is compatible with current settings."
  @spec policy_matches?(map() | nil) :: boolean()
  def policy_matches?(nil), do: false

  def policy_matches?(policy) when is_map(policy) do
    policy_mismatch_reasons(policy) == []
  end

  @doc "Explain why a recorded lockfile policy does not match current settings."
  @spec policy_mismatch_reasons(map() | nil) :: [String.t()]
  def policy_mismatch_reasons(nil), do: ["no policy recorded in lockfile"]

  def policy_mismatch_reasons(policy) when is_map(policy) do
    current = current_policy()

    []
    |> maybe_mismatch_reason(
      policy["block_exotic_subdeps"] == current["block_exotic_subdeps"],
      "block_exotic_subdeps: lockfile=#{inspect(policy["block_exotic_subdeps"])} current=#{inspect(current["block_exotic_subdeps"])}"
    )
    |> maybe_mismatch_reason(
      MapSet.subset?(
        MapSet.new(policy["exotic_deps"] || []),
        MapSet.new(current["exotic_deps"] || [])
      ),
      "exotic_deps not covered by current allow-list"
    )
    |> maybe_mismatch_reason(
      MapSet.subset?(
        MapSet.new(policy["allowed_registries"] || []),
        MapSet.new(current["allowed_registries"] || [])
      ),
      "allowed_registries: lockfile=#{inspect(policy["allowed_registries"] || [])} current=#{inspect(current["allowed_registries"] || [])}"
    )
    |> maybe_mismatch_reason(
      policy["allow_registry_redirects"] == current["allow_registry_redirects"],
      "allow_registry_redirects: lockfile=#{inspect(policy["allow_registry_redirects"])} current=#{inspect(current["allow_registry_redirects"])}"
    )
  end

  @doc """
  Rewrite only the recorded security policy in an existing lockfile.

  Used after a cache-backed install when dependency versions still match but the
  active registry/security settings have changed.
  """
  @spec refresh_policy(String.t()) :: :ok | {:error, term()}
  def refresh_policy(path \\ @default_path) do
    case read_json(path) do
      {:ok, data} ->
        updated =
          case data do
            %{@npm_ex_metadata => meta} when is_map(meta) ->
              put_in(data, [@npm_ex_metadata, "policy"], current_policy())

            _ ->
              Map.put(data, @npm_ex_metadata, %{"policy" => current_policy()})
          end

        File.write(path, NPM.JSON.encode_pretty(updated))

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec sync_package_metadata(keyword()) :: :ok | {:error, term()}
  def sync_package_metadata(opts \\ []) do
    case read_json(@default_path) do
      {:ok, %{"lockfileVersion" => version, "packages" => packages} = data}
      when version in [2, 3] and is_map(packages) ->
        with {:ok, manifests} <- NPM.Workspace.manifests("."),
             {:ok, updated} <-
               with_valid_entries(fn -> {:ok, sync_package_metadata(data, manifests)} end) do
          cond do
            updated == data -> :ok
            opts[:frozen] -> {:error, :frozen_lockfile}
            true -> File.write(@default_path, NPM.JSON.encode_pretty(updated))
          end
        end

      {:ok, _legacy} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_package_metadata(data, [%{root?: true, data: root_data} | _] = manifests) do
    descriptors =
      %{"" => root_package_descriptor(root_data)}
      |> put_workspace_package_descriptors(manifests)

    workspace_links =
      for manifest <- manifests,
          not manifest.root?,
          name = manifest.data["name"],
          is_binary(name) and name != "",
          into: %{},
          do: {relative_path(manifest.dir), "node_modules/#{name}"}

    root_changed? = not package_metadata_current?(data["packages"][""], descriptors[""], "")

    packages =
      data["packages"]
      |> Map.new(fn {location, record} ->
        if record["link"] == true and match?({:ok, _}, package_name_from_location(location)) do
          {Map.get(workspace_links, record["resolved"], location), record}
        else
          {location, record}
        end
      end)

    packages =
      Enum.reduce(descriptors, packages, fn {location, descriptor}, packages ->
        previous = Map.get(packages, location, %{})

        if package_metadata_current?(previous, descriptor, location) do
          packages
        else
          record =
            previous |> Map.drop(package_metadata_fields(location)) |> Map.merge(descriptor)

          Map.put(packages, location, record)
        end
      end)

    Enum.reduce(~w(name version), Map.put(data, "packages", packages), fn field, updated ->
      if root_changed? or Map.has_key?(data, field) do
        updated |> Map.delete(field) |> maybe_put(field, root_data[field])
      else
        updated
      end
    end)
  end

  defp package_metadata_current?(nil, _descriptor, _location), do: false

  defp package_metadata_current?(previous, descriptor, location) do
    fields = package_metadata_fields(location)

    normalize = fn record ->
      record
      |> Map.take(fields)
      |> Map.reject(fn {field, value} ->
        field in @dependency_metadata_fields and value == %{}
      end)
    end

    normalize.(previous) == normalize.(descriptor)
  end

  defp package_metadata_fields(""), do: @package_metadata_fields
  defp package_metadata_fields(_workspace), do: @package_metadata_fields -- ["workspaces"]

  defp maybe_mismatch_reason(reasons, true, _message), do: reasons
  defp maybe_mismatch_reason(reasons, false, message), do: reasons ++ [message]

  @doc "Parse a raw packages map into lockfile entries."
  @spec parse_packages(map()) :: t()
  def parse_packages(packages) do
    if package_lock_packages?(packages) do
      parse_package_lock_packages(packages)
    else
      parse_legacy_packages(packages)
    end
  end

  @doc "Parse a raw package-lock map into lockfile entries."
  @spec parse(map()) :: t()
  def parse(data) when is_map(data), do: parse_data(data)

  defp parse_data(%{"packages" => packages} = data) when is_map(packages) do
    cond do
      package_lock?(data, packages) -> parse_package_lock_packages(packages)
      true -> parse_legacy_packages(packages)
    end
  end

  defp parse_data(%{"dependencies" => deps}) when is_map(deps),
    do: parse_legacy_dependencies(deps)

  defp parse_data(_), do: %{}

  defp parse_legacy_packages(packages) do
    for {name, info} <- packages, into: %{} do
      {name,
       validate_entry!(name, name, %{
         version: Map.get(info, "version", ""),
         integrity: Map.get(info, "integrity", ""),
         tarball: Map.get(info, "tarball", ""),
         dependencies: Map.get(info, "dependencies", %{}),
         optional_dependencies: optional_dependencies(info),
         has_install_script: has_install_script?(info)
       })}
    end
  end

  defp parse_package_lock_packages(packages) do
    packages
    |> Enum.flat_map(fn {location, info} ->
      with false <- Map.get(info, "link") == true,
           {:ok, name} <- package_name_from_location(location) do
        [{name, validate_entry!(location, name, package_lock_entry_from_info(info))}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_nested_package_lock_packages(packages) do
    packages
    |> Enum.reduce_while({:ok, %{}}, fn {location, info}, {:ok, acc} ->
      cond do
        not nested_package_location?(location) or Map.get(info, "link") == true ->
          {:cont, {:ok, acc}}

        match?({:ok, _name}, nested_package_name(location)) ->
          {:ok, name} = nested_package_name(location)
          entry = validate_entry!(location, name, package_lock_entry_from_info(info))
          {:cont, {:ok, Map.put(acc, location, entry)}}

        true ->
          {:halt, {:error, {:invalid_nested_package_location, location}}}
      end
    end)
  end

  defp nested_package_location?(location) do
    segments = String.split(location, "/")

    "node_modules" in segments and
      (not String.starts_with?(location, "node_modules/") or
         Enum.count(segments, &(&1 == "node_modules")) > 1)
  end

  @doc false
  @spec nested_package_name(String.t()) :: {:ok, String.t()} | :error
  def nested_package_name(location) do
    {prefix, packages} =
      location |> String.split("/", trim: false) |> Enum.split_while(&(&1 != "node_modules"))

    if Enum.all?(prefix, &(&1 not in ["", ".", ".."] and not String.contains?(&1, "\\"))) do
      parse_nested_location(packages, if(prefix == [], do: [], else: [:workspace]))
    else
      :error
    end
  end

  defp parse_nested_location(["node_modules" | rest], parents) do
    with {:ok, name, remaining} <- take_package_name(rest) do
      case remaining do
        [] when parents != [] -> {:ok, name}
        ["node_modules" | _] -> parse_nested_location(remaining, [name | parents])
        _ -> :error
      end
    end
  end

  defp parse_nested_location(_segments, _parents), do: :error

  defp take_package_name(["@" <> scope = scoped, package | rest]) do
    name = "#{scoped}/#{package}"

    if scope != "" and NPM.Scope.valid_name?(name) do
      {:ok, name, rest}
    else
      :error
    end
  end

  defp take_package_name([package | rest]) do
    if NPM.Scope.valid_name?(package) do
      {:ok, package, rest}
    else
      :error
    end
  end

  defp take_package_name(_segments), do: :error

  defp package_lock_entry_from_info(info) do
    %{
      version: Map.get(info, "version", ""),
      integrity: Map.get(info, "integrity", ""),
      tarball: Map.get(info, "resolved", ""),
      dependencies: Map.get(info, "dependencies", %{}),
      optional_dependencies: optional_dependencies(info),
      has_install_script: has_install_script?(info)
    }
    |> maybe_mark_optional(info)
    |> maybe_put_peer_metadata(info)
  end

  # npm 7+ locks record auto-installed peers; keep the edges so reachability
  # does not prune them. Malformed values are ignored rather than trusted.
  defp maybe_put_peer_metadata(entry, info) do
    entry
    |> maybe_put_string_map(:peer_dependencies, info["peerDependencies"], &is_binary/1)
    |> maybe_put_string_map(:peer_dependencies_meta, info["peerDependenciesMeta"], &is_map/1)
    |> then(fn entry -> if info["peer"] == true, do: Map.put(entry, :peer, true), else: entry end)
  end

  defp maybe_put_string_map(entry, key, value, valid_value?)
       when is_map(value) and map_size(value) > 0 do
    if Enum.all?(value, fn {name, v} -> is_binary(name) and valid_value?.(v) end),
      do: Map.put(entry, key, value),
      else: entry
  end

  defp maybe_put_string_map(entry, _key, _value, _valid_value?), do: entry

  defp parse_legacy_dependencies(deps) do
    Map.new(deps, fn {name, info} ->
      {name,
       validate_entry!(name, name, %{
         version: Map.get(info, "version", ""),
         integrity: Map.get(info, "integrity", ""),
         tarball: Map.get(info, "resolved", ""),
         dependencies: Map.get(info, "requires", %{}),
         optional_dependencies: optional_dependencies(info),
         has_install_script: has_install_script?(info)
       })}
    end)
  end

  @doc "Get the lockfile version from a file."
  @spec version(String.t()) :: integer() | nil
  def version(path \\ @default_path)

  def version(@default_path) do
    cond do
      File.exists?(@default_path) -> version_file(@default_path)
      File.exists?(@legacy_path) -> version_file(@legacy_path)
      true -> nil
    end
  end

  def version(path), do: version_file(path)

  defp version_file(path) do
    case read_json(path) do
      {:ok, data} -> Map.get(data, "lockfileVersion")
      {:error, _} -> nil
    end
  end

  @doc "List all package names in the lockfile."
  @spec package_names(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def package_names(path \\ @default_path) do
    case read(path) do
      {:ok, lockfile} -> {:ok, Map.keys(lockfile) |> Enum.sort()}
      error -> error
    end
  end

  @doc """
  Check if a specific package is in the lockfile.
  """
  @spec has_package?(String.t(), String.t()) :: boolean()
  def has_package?(name, path \\ @default_path) do
    case read(path) do
      {:ok, lockfile} -> Map.has_key?(lockfile, name)
      _ -> false
    end
  end

  @doc "Get a single package entry from the lockfile."
  @spec get_package(String.t(), String.t()) :: {:ok, entry()} | :error
  def get_package(name, path \\ @default_path) do
    case read(path) do
      {:ok, lockfile} -> Map.fetch(lockfile, name)
      _ -> :error
    end
  end

  @doc false
  @spec all_package_names(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def all_package_names(path \\ @default_path) do
    with_valid_entries(fn -> read_all_package_names(path) end)
  end

  defp read_all_package_names(path) do
    case read_json(path) do
      {:ok, %{"packages" => packages} = data} when is_map(packages) ->
        names =
          if package_lock?(data, packages) do
            package_lock_all_package_names(packages)
          else
            Map.keys(parse_legacy_packages(packages))
          end

        {:ok, Enum.sort(names)}

      {:ok, data} ->
        {:ok, data |> parse_data() |> Map.keys() |> Enum.sort()}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serialize_legacy(lockfile) do
    for {name, entry} <- Enum.sort_by(lockfile, &elem(&1, 0)), into: %{} do
      {name,
       %{
         "version" => entry.version,
         "integrity" => entry.integrity,
         "tarball" => entry.tarball,
         "dependencies" => entry.dependencies,
         "optional_dependencies" => Map.get(entry, :optional_dependencies, %{}),
         "has_install_script" => Map.get(entry, :has_install_script, false)
       }}
    end
  end

  defp package_lock_packages(lockfile, root_data, opts) do
    manifests = package_manifests()

    %{}
    |> Map.put("", root_package_descriptor(root_data))
    |> put_workspace_package_descriptors(manifests)
    |> put_registry_package_descriptors(lockfile)
    |> put_nested_package_descriptors(Keyword.get(opts, :nested, %{}))
    |> put_workspace_links(manifests)
  end

  defp root_package_descriptor(root_data) do
    %{}
    |> maybe_put("name", root_data["name"])
    |> maybe_put("version", root_data["version"])
    |> maybe_put("workspaces", root_data["workspaces"])
    |> maybe_put("dependencies", empty_to_nil(root_data["dependencies"]))
    |> maybe_put("devDependencies", empty_to_nil(root_data["devDependencies"]))
    |> maybe_put("optionalDependencies", empty_to_nil(root_data["optionalDependencies"]))
    |> maybe_put("peerDependencies", empty_to_nil(root_data["peerDependencies"]))
  end

  defp put_workspace_package_descriptors(packages, manifests) do
    manifests
    |> Enum.reject(& &1.root?)
    |> Enum.reduce(packages, fn manifest, acc ->
      Map.put(acc, relative_path(manifest.dir), package_descriptor(manifest.data))
    end)
  end

  defp package_descriptor(data) do
    %{}
    |> maybe_put("name", data["name"])
    |> maybe_put("version", data["version"])
    |> maybe_put("dependencies", empty_to_nil(data["dependencies"]))
    |> maybe_put("devDependencies", empty_to_nil(data["devDependencies"]))
    |> maybe_put("optionalDependencies", empty_to_nil(data["optionalDependencies"]))
    |> maybe_put("peerDependencies", empty_to_nil(data["peerDependencies"]))
  end

  defp put_registry_package_descriptors(packages, lockfile) do
    Enum.reduce(lockfile, packages, fn {name, entry}, acc ->
      Map.put(acc, "node_modules/#{name}", package_lock_entry(entry))
    end)
  end

  defp put_nested_package_descriptors(packages, nested) do
    Enum.reduce(nested, packages, fn {location, entry}, acc ->
      Map.put(acc, location, package_lock_entry(entry))
    end)
  end

  defp package_lock_entry(entry) do
    %{
      "version" => entry.version,
      "resolved" => entry.tarball,
      "integrity" => entry.integrity
    }
    |> maybe_put("dependencies", empty_to_nil(entry.dependencies))
    |> maybe_put(
      "optionalDependencies",
      empty_to_nil(Map.get(entry, :optional_dependencies, %{}))
    )
    |> maybe_put("hasInstallScript", if(Map.get(entry, :has_install_script, false), do: true))
    |> maybe_put("optional", if(Map.get(entry, :optional, false), do: true))
    |> maybe_put("peer", if(Map.get(entry, :peer, false), do: true))
    |> maybe_put("peerDependencies", Map.get(entry, :peer_dependencies))
    |> maybe_put("peerDependenciesMeta", Map.get(entry, :peer_dependencies_meta))
  end

  defp put_workspace_links(packages, manifests) do
    manifests
    |> Enum.reject(& &1.root?)
    |> Enum.reduce(packages, fn manifest, acc ->
      with name when is_binary(name) and name != "" <- manifest.data["name"] do
        Map.put(acc, "node_modules/#{name}", %{
          "resolved" => relative_path(manifest.dir),
          "link" => true
        })
      else
        _ -> acc
      end
    end)
  end

  defp package_manifests do
    case NPM.Workspace.manifests(".") do
      {:ok, manifests} -> manifests
      _ -> []
    end
  end

  defp read_root_package do
    case NPM.JSON.read_file("package.json") do
      {:ok, data} when is_map(data) -> data
      _ -> %{}
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, NPM.JSON.decode!(content)}
      error -> error
    end
  end

  defp lockfile_policy(data) do
    get_in(data, [@npm_ex_metadata, "policy"]) || Map.get(data, "policy")
  end

  defp package_lock?(data, _packages), do: Map.get(data, "lockfileVersion") in [2, 3]

  defp package_lock_packages?(packages) do
    Map.has_key?(packages, "") or Enum.any?(packages, fn {path, _} -> package_location?(path) end)
  end

  defp package_location?("node_modules/" <> _), do: true
  defp package_location?(_), do: false

  # Top-level `node_modules/<name>` locations yield a name; deeper (nested)
  # locations return :error and are handled by `read_nested/1`. Locations with
  # traversal or malformed segments are rejected outright.
  defp package_name_from_location("node_modules/" <> rest = location) do
    segments = String.split(rest, "/")

    name =
      case segments do
        ["@" <> _ = scope, package] -> "#{scope}/#{package}"
        [package] -> package
        _ -> nil
      end

    cond do
      Enum.any?(segments, &unsafe_location_segment?/1) ->
        raise InvalidEntryError, location: location, reason: :unsafe_location

      is_nil(name) ->
        :error

      NPM.Scope.installable_name?(name) ->
        {:ok, name}

      true ->
        raise InvalidEntryError, location: location, reason: {:invalid_package_name, name}
    end
  end

  defp package_name_from_location(_), do: :error

  defp package_lock_all_package_names(packages) do
    packages
    |> Enum.flat_map(fn {location, info} ->
      with false <- Map.get(info, "link") == true,
           {:ok, name} <- package_name_from_any_location(location) do
        [name]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp package_name_from_any_location(location) do
    segments = String.split(location, "/")

    if "node_modules" in segments and Enum.any?(segments, &unsafe_location_segment?/1) do
      raise InvalidEntryError, location: location, reason: :unsafe_location
    end

    segments
    |> Enum.with_index()
    |> Enum.filter(fn {segment, _index} -> segment == "node_modules" end)
    |> List.last()
    |> case do
      {"node_modules", index} -> package_name_from_segments(Enum.drop(segments, index + 1))
      nil -> :error
    end
  end

  defp package_name_from_segments(["@" <> _ = scope, package | _]),
    do: installable_name("#{scope}/#{package}")

  defp package_name_from_segments([package | _]) when package != "",
    do: installable_name(package)

  defp package_name_from_segments(_), do: :error

  defp installable_name(name) do
    if NPM.Scope.installable_name?(name),
      do: {:ok, name},
      else: raise(InvalidEntryError, location: name, reason: {:invalid_package_name, name})
  end

  defp unsafe_location_segment?(segment),
    do: segment in ["", ".", ".."] or String.contains?(segment, ["\\", <<0>>])

  defp optional_dependencies(info) do
    Map.get(info, "optionalDependencies") || Map.get(info, "optional_dependencies", %{})
  end

  defp has_install_script?(info) do
    Map.get(info, "hasInstallScript") || Map.get(info, "has_install_script", false)
  end

  defp maybe_mark_optional(entry, info) do
    if Map.get(info, "optional", false) do
      Map.put(entry, :optional, true)
    else
      entry
    end
  end

  defp legacy_path?(path), do: Path.basename(path) == @legacy_path

  defp relative_path(path) do
    path
    |> Path.relative_to(File.cwd!())
    |> Path.split()
    |> Enum.join("/")
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
