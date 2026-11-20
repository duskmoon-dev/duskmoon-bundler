defmodule DuskmoonBundler.Builder.Resolver do
  @moduledoc "Resolve import specifiers to absolute file paths for the build graph."

  alias DuskmoonBundler.JS.{Extensions, Resolution}
  alias DuskmoonBundler.JS.Resolver, as: JSResolver
  alias NPM.Resolution.PackageResolver

  @doc """
  Resolve an import specifier to an absolute file path.

  Returns `{:ok, path}`, `:skip` (for externals/node builtins), or `{:error, reason}`.
  """
  def resolve(specifier, importer, ctx) do
    {path_specifier, query} = DuskmoonBundler.URL.split_query(specifier)

    if external?(path_specifier, ctx.external) do
      :skip
    else
      do_resolve(path_specifier, importer, ctx, query)
    end
  end

  @doc "Whether a specifier names an external package or one of its subpaths."
  def external?(specifier, external) do
    MapSet.member?(external, specifier) or
      Enum.any?(external, &String.starts_with?(specifier, &1 <> "/"))
  end

  def absolute?(specifier), do: String.starts_with?(specifier, "/")

  defp do_resolve(specifier, importer, ctx, query) do
    case DuskmoonBundler.PluginRunner.resolve(ctx.plugins, specifier, importer) do
      {:ok, resolved} -> {:ok, DuskmoonBundler.URL.append_query(resolved, query)}
      nil -> resolve_specifier(specifier, importer, ctx, query)
    end
  end

  defp resolve_specifier(specifier, importer, ctx, query) do
    case JSResolver.resolve(specifier, ctx.aliases) do
      {:ok, aliased} -> append_query(resolve_aliased(aliased, ctx), query)
      :pass -> append_query(resolve_by_type(specifier, importer, ctx), query)
    end
  end

  defp resolve_aliased(aliased, ctx) do
    case PackageResolver.try_resolve(Path.expand(aliased),
           extensions: Extensions.resolvable(ctx.plugins)
         ) do
      {:ok, _} = ok -> ok
      :error -> {:error, {:not_found, aliased}}
    end
  end

  defp append_query({:ok, path}, query), do: {:ok, DuskmoonBundler.URL.append_query(path, query)}
  defp append_query(other, _query), do: other

  defp resolve_by_type(specifier, importer, ctx) do
    cond do
      PackageResolver.node_builtin?(specifier) ->
        :skip

      String.starts_with?(specifier, "#") ->
        resolve_package_import(specifier, importer, ctx)

      PackageResolver.relative?(specifier) ->
        resolve_relative(specifier, importer, ctx)

      true ->
        resolve_bare(specifier, importer, ctx)
    end
  end

  @js_to_ts_map %{".js" => [".ts", ".tsx"], ".jsx" => [".tsx"], ".mjs" => [".mts"]}

  defp resolve_package_import(specifier, importer, ctx) do
    {importer_path, _query} = DuskmoonBundler.URL.split_query(importer)

    case PackageResolver.resolve(specifier, Path.dirname(importer_path),
           extensions: Extensions.resolvable(ctx.plugins),
           conditions: Resolution.browser_conditions()
         ) do
      {:ok, _} = ok -> ok
      :error -> {:error, {:not_found, specifier}}
      {:builtin, _} -> :skip
    end
  end

  defp resolve_relative(specifier, importer, ctx) do
    {importer_path, _query} = DuskmoonBundler.URL.split_query(importer)
    base = Path.expand(specifier, Path.dirname(importer_path))

    case PackageResolver.try_resolve(base,
           extensions: Extensions.resolvable(ctx.plugins)
         ) do
      {:ok, _} = ok ->
        ok

      :error ->
        try_ts_extension(base) ||
          if(type_declaration?(base), do: :skip, else: {:error, {:not_found, base}})
    end
  end

  defp try_ts_extension(base) do
    ext = Path.extname(base)

    case Map.get(@js_to_ts_map, ext) do
      nil ->
        nil

      ts_exts ->
        root = Path.rootname(base)

        Enum.find_value(ts_exts, fn ts_ext ->
          path = root <> ts_ext
          if File.regular?(path), do: {:ok, path}
        end)
    end
  end

  defp type_declaration?(base) do
    File.exists?(base <> ".d.ts") or File.exists?(base <> ".d.cts") or
      File.exists?(base <> ".d.mts")
  end

  defp resolve_bare(specifier, importer, ctx) do
    {importer_path, _query} = DuskmoonBundler.URL.split_query(importer)
    {package_name, _subpath} = PackageResolver.split_specifier(specifier)

    dir =
      importer_path
      |> Path.dirname()
      |> node_modules_dirs()
      |> Enum.find(&File.dir?(Path.join(&1, package_name)))

    case dir do
      nil ->
        resolve_configured_bare(specifier, ctx.node_modules, ctx.resolve_dirs, ctx.plugins)

      dir ->
        resolve_in_package(specifier, dir, Path.join(dir, package_name), ctx.plugins) ||
          {:error, {:not_found, specifier}}
    end
  end

  defp node_modules_dirs(dir) do
    parent = Path.dirname(dir)
    current = Path.join(dir, "node_modules")

    if parent == dir, do: [current], else: [current | node_modules_dirs(parent)]
  end

  defp resolve_configured_bare(specifier, node_modules, resolve_dirs, plugins) do
    dirs = if node_modules, do: [node_modules | resolve_dirs], else: resolve_dirs
    {package_name, _subpath} = PackageResolver.split_specifier(specifier)

    case Enum.find(dirs, &File.dir?(Path.join(&1, package_name))) do
      nil ->
        {:error, {:not_found, specifier}}

      dir ->
        resolve_in_package(specifier, dir, Path.join(dir, package_name), plugins) ||
          {:error, {:not_found, specifier}}
    end
  end

  defp resolve_in_package(specifier, dir, package_dir, plugins) do
    subpath = subpath_for(specifier)
    extensions = Extensions.resolvable(plugins)
    manifest? = File.regular?(Path.join(package_dir, "package.json"))

    # A package manifest makes the npm resolver authoritative, including exports
    # denials and exports that intentionally map a subpath back to the main file.
    # Keep the legacy direct-path fallback only for directories without a manifest.
    case PackageResolver.resolve_entry(package_dir,
           subpath: subpath,
           extensions: extensions,
           conditions: Resolution.browser_conditions()
         ) do
      {:ok, _resolved} = ok when manifest? ->
        ok

      {:ok, resolved} ->
        maybe_try_direct_path(resolved, subpath, dir, specifier, package_dir, extensions)

      :error when manifest? ->
        nil

      :error ->
        case PackageResolver.try_resolve(Path.join(dir, specifier),
               extensions: extensions
             ) do
          {:ok, _} = ok -> ok
          :error -> nil
        end
    end
  end

  defp maybe_try_direct_path(resolved, ".", _dir, _specifier, _package_dir, _extensions),
    do: {:ok, resolved}

  defp maybe_try_direct_path(resolved, _subpath, dir, specifier, package_dir, extensions) do
    main = resolve_main(package_dir, extensions)

    if resolved == main do
      case PackageResolver.try_resolve(Path.join(dir, specifier),
             extensions: extensions
           ) do
        {:ok, _} = ok -> ok
        :error -> {:ok, resolved}
      end
    else
      {:ok, resolved}
    end
  end

  defp resolve_main(package_dir, extensions) do
    case PackageResolver.resolve_entry(package_dir,
           subpath: ".",
           extensions: extensions,
           conditions: Resolution.browser_conditions()
         ) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  defp subpath_for(specifier) do
    case PackageResolver.split_specifier(specifier) do
      {_, nil} -> "."
      {_, subpath} -> subpath
    end
  end
end
