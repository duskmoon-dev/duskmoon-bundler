defmodule DuskmoonBundler.Builder.Collector do
  @moduledoc "Walks the dependency graph from entry files, collecting modules and workers."

  alias DuskmoonBundler.Builder.Resolver

  @doc """
  Walk the dependency graph from an entry file.

  Returns `{:ok, modules, dep_map, workers}` where:
  - `modules` is `[{abs_path, label, source}]` in dependency order
  - `dep_map` tracks static, dynamic, and CommonJS dependencies by absolute path
  - `workers` is `%{importer_path => %{specifier => worker_abs_path}}`
  """
  def collect(entry_path, ctx) do
    with {:ok, modules, dep_map, workers, specifier_labels, path_labels, _compiled} <-
           collect_compiled(entry_path, ctx) do
      {:ok, modules, dep_map, workers, specifier_labels, path_labels}
    end
  end

  @doc "Collect the graph and retain pipeline output for the production build."
  def collect_compiled(entry_path, ctx) do
    label = Path.basename(entry_path)

    state = %DuskmoonBundler.Builder.Collector.State{
      ctx: ctx,
      root: Path.dirname(entry_path),
      used_labels: MapSet.new([label]),
      path_labels: %{entry_path => label}
    }

    case do_collect(entry_path, label, state) do
      {:ok, state} ->
        {:ok, Enum.reverse(state.files), state.dep_map, state.workers, state.specifier_labels,
         state.path_labels,
         Map.new(state.compiled, fn {path, {:ok, result}} -> {path, result} end)}

      {:error, _} = error ->
        error
    end
  end

  defp do_collect(abs_path, label, state) do
    path = module_path(abs_path)

    cond do
      MapSet.member?(state.seen, abs_path) ->
        {:ok, state}

      DuskmoonBundler.Assets.asset?(path) ->
        collect_asset(abs_path, label, state)

      true ->
        case Map.get_lazy(state.loaded, abs_path, fn -> read_module(path, state.ctx.plugins) end) do
          {:ok, source, content_type} ->
            process_source(abs_path, label, source, content_type, state)

          {:error, reason} ->
            {:error, {:file_read_error, abs_path, reason}}
        end
    end
  end

  defp module_path(module_id), do: module_id |> DuskmoonBundler.URL.split_query() |> elem(0)

  defp collect_asset(abs_path, label, state) do
    source = ""

    {:ok,
     %{
       state
       | seen: MapSet.put(state.seen, abs_path),
         files: [{abs_path, label, source} | state.files],
         dep_map: Map.put(state.dep_map, abs_path, %DuskmoonBundler.Builder.Dependencies{})
     }}
  end

  defp read_module(path, plugins) do
    case DuskmoonBundler.PluginRunner.load(plugins, path) do
      {:ok, code, content_type} ->
        {:ok, code, content_type}

      {:ok, code} ->
        {:ok, code, nil}

      nil ->
        case File.read(path) do
          {:ok, source} -> {:ok, source, nil}
          error -> error
        end
    end
  end

  defp process_source(abs_path, label, source, content_type, state) do
    path = module_path(abs_path)

    result =
      Map.get_lazy(state.compiled, abs_path, fn ->
        compile_source(path, label, source, content_type, state.ctx)
      end)

    with {:ok, compiled} <- result do
      graph_source = if compiled.type == :js, do: compiled.code, else: source
      state = %{state | compiled: Map.put(state.compiled, abs_path, result)}
      process_imports(abs_path, label, source, graph_source, content_type, state)
    end
  end

  defp process_imports(abs_path, label, source, graph_source, content_type, state) do
    state = %{
      state
      | seen: MapSet.put(state.seen, abs_path),
        files: [{abs_path, label, source} | state.files]
    }

    case extract_typed_imports(
           graph_source,
           abs_path,
           content_type,
           state.ctx.loaders,
           state.ctx.plugins,
           graph_source != source
         ) do
      {:ok, imports} ->
        %{imports: typed_imports, requires: requires, workers: worker_specs} =
          without_generated_helpers(imports, source, abs_path, content_type, state.ctx)

        state = %{
          state
          | dep_map: Map.put(state.dep_map, abs_path, split_imports(typed_imports, requires))
        }

        {state, worker_specs} = resolve_workers(worker_specs, abs_path, state)
        specifiers = Enum.map(typed_imports, fn {_type, spec} -> spec end)

        worker_imports =
          Enum.map(worker_specs, fn {specifier, resolved_path} ->
            {:resolved, specifier, resolved_path}
          end)

        collect_imports(specifiers ++ worker_imports, abs_path, state)

      {:error, _} = error ->
        error
    end
  end

  # OXC lowering injects runtime helper imports that Rolldown provides internally.
  # Explicit source imports still go through ordinary package resolution.
  defp without_generated_helpers(imports, source, path, content_type, ctx) do
    helpers =
      for {:static, specifier} <- imports.imports,
          String.starts_with?(specifier, "@oxc-project/runtime/helpers/"),
          into: MapSet.new(),
          do: specifier

    if MapSet.size(helpers) == 0 do
      imports
    else
      case extract_typed_imports(source, path, content_type, ctx.loaders, ctx.plugins, false) do
        {:ok, original} ->
          original_specifiers = MapSet.new(original.imports, &elem(&1, 1))
          generated = MapSet.difference(helpers, original_specifiers)

          %{
            imports
            | imports: Enum.reject(imports.imports, &MapSet.member?(generated, elem(&1, 1))),
              requires: Enum.reject(imports.requires, &MapSet.member?(generated, &1))
          }

        {:error, _} ->
          imports
      end
    end
  end

  defp collect_imports([], _importer, state) do
    {:ok, state}
  end

  defp collect_imports([specifier | rest], importer, state) do
    case resolve_specifier(specifier, importer, state.ctx) do
      :skip ->
        collect_imports(rest, importer, state)

      {:ok, resolved_path, original_specifier} ->
        {label, state} =
          if MapSet.member?(state.seen, resolved_path) do
            {state.path_labels[resolved_path], state}
          else
            unique_label(original_specifier, resolved_path, state)
          end

        importer_labels = Map.get(state.specifier_labels, importer, %{})

        state = %{
          state
          | specifier_labels:
              Map.put(
                state.specifier_labels,
                importer,
                Map.put_new(importer_labels, original_specifier, label)
              ),
            dep_map:
              resolve_dep_map_specifier(
                state.dep_map,
                importer,
                original_specifier,
                resolved_path
              )
        }

        case do_collect(resolved_path, label, state) do
          {:ok, state} ->
            collect_imports(rest, importer, state)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_dep_map_specifier(dep_map, importer, specifier, resolved_path) do
    case dep_map[importer] do
      nil ->
        dep_map

      deps ->
        deps = %{
          deps
          | static: replace_specifier(deps.static, specifier, resolved_path),
            dynamic: replace_specifier(deps.dynamic, specifier, resolved_path),
            requires: replace_specifier(deps.requires, specifier, resolved_path)
        }

        Map.put(dep_map, importer, deps)
    end
  end

  defp replace_specifier(specs, specifier, resolved_path) do
    Enum.map(specs, fn
      ^specifier -> resolved_path
      other -> other
    end)
  end

  defp compile_source(path, label, source, content_type, ctx) do
    DuskmoonBundler.Pipeline.compile_loaded(path, source, content_type,
      target: ctx.target,
      import_source: ctx.import_source,
      define: ctx.define,
      plugins: ctx.plugins,
      loaders: ctx.loaders,
      preserve_json: Path.extname(label) == ".json"
    )
  end

  defp extract_typed_imports(source, path, content_type, loaders, plugins, compiled?) do
    ext = Path.extname(path)
    filename = DuskmoonBundler.JS.Extensions.apply_loader(Path.basename(path), loaders)

    case if(compiled?,
           do: nil,
           else:
             DuskmoonBundler.PluginRunner.extract_imports(plugins, path, source, loaders: loaders)
         ) do
      nil ->
        cond do
          content_type in ~w(application/javascript text/javascript) ->
            extract_js_typed_imports(source, filename)

          ext == ".json" or ext in DuskmoonBundler.JS.Extensions.css() ->
            {:ok, %DuskmoonBundler.JS.ImportExtractor.Result{imports: [], workers: []}}

          true ->
            extract_js_typed_imports(source, filename)
        end

      result ->
        result
    end
  end

  defp extract_js_typed_imports(source, filename) do
    DuskmoonBundler.JS.ImportExtractor.extract_typed(source, filename, include_require: true)
  end

  defp resolve_workers(worker_specs, importer, state) do
    Enum.reduce(worker_specs, {state, []}, fn specifier, {acc_state, resolved_specs} ->
      case Resolver.resolve(specifier, importer, acc_state.ctx) do
        {:ok, resolved_path} ->
          importer_map = Map.get(acc_state.workers, importer, %{})

          acc_state = %{
            acc_state
            | workers:
                Map.put(
                  acc_state.workers,
                  importer,
                  Map.put(importer_map, specifier, resolved_path)
                )
          }

          {acc_state, [{specifier, resolved_path} | resolved_specs]}

        _ ->
          {acc_state, resolved_specs}
      end
    end)
    |> then(fn {resolved_state, resolved_specs} ->
      {resolved_state, Enum.reverse(resolved_specs)}
    end)
  end

  defp resolve_specifier(specifier, importer, ctx) when is_binary(specifier) do
    case Resolver.resolve(specifier, importer, ctx) do
      :skip -> :skip
      {:ok, resolved_path} -> {:ok, resolved_path, specifier}
      {:error, _} = error -> error
    end
  end

  defp resolve_specifier({:resolved, specifier, resolved_path}, _importer, _ctx) do
    {:ok, resolved_path, specifier}
  end

  defp unique_label(_specifier, resolved_path, state) do
    state = prepare_json(resolved_path, state)
    base_label = module_label(resolved_path, state.root, state.compiled)
    label = deduplicate_label(base_label, resolved_path, state.used_labels)

    state = %{
      state
      | used_labels: MapSet.put(state.used_labels, label),
        path_labels: Map.put(state.path_labels, resolved_path, label)
    }

    {label, state}
  end

  defp module_label(resolved_path, root, compiled) do
    {path, query} = DuskmoonBundler.URL.split_query(resolved_path)
    [relative_path | rest] = path |> String.split("/node_modules/") |> Enum.reverse()

    label =
      if rest != [] do
        relative_path
      else
        relative = Path.relative_to(path, root)

        if Path.type(relative) == :absolute do
          "_external/" <>
            Path.basename(Path.dirname(path)) <> "/" <> Path.basename(path)
        else
          relative
        end
      end
      |> with_query_suffix(query)

    cond do
      Path.extname(label) == ".json" -> json_label(label, Map.get(compiled, resolved_path))
      Path.extname(label) in DuskmoonBundler.JS.Extensions.css() -> label <> ".js"
      query != "" -> label <> ".js"
      true -> label
    end
  end

  defp prepare_json(module_id, state) do
    {path, query} = DuskmoonBundler.URL.split_query(module_id)

    if Path.extname(path) == ".json" and not Map.has_key?(state.compiled, module_id) do
      loaded = read_module(path, state.ctx.plugins)

      compiled =
        case loaded do
          {:ok, source, content_type} ->
            label = with_query_suffix(Path.basename(path), query)
            compile_source(path, label, source, content_type, state.ctx)

          {:error, reason} ->
            {:error, {:file_read_error, module_id, reason}}
        end

      %{
        state
        | loaded: Map.put(state.loaded, module_id, loaded),
          compiled: Map.put(state.compiled, module_id, compiled)
      }
    else
      state
    end
  end

  defp json_label(label, compiled) do
    # Plugins may replace JSON with JavaScript. Only the default data module
    # keeps its extension so Rolldown supplies CommonJS JSON interop.
    case compiled do
      {:ok, %{type: :json}} -> label
      _ -> label <> ".js"
    end
  end

  defp with_query_suffix(label, ""), do: label

  defp with_query_suffix(label, query) do
    suffix =
      query
      |> URI.decode_query()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join("-")

    label <> "." <> suffix
  end

  defp deduplicate_label(label, resolved_path, used) do
    if MapSet.member?(used, label) do
      parent = resolved_path |> Path.dirname() |> Path.basename()
      candidate = parent <> "/" <> label

      if MapSet.member?(used, candidate) do
        deduplicate_label(candidate <> "_2", resolved_path, used)
      else
        candidate
      end
    else
      label
    end
  end

  defp split_imports(typed_imports, requires) do
    {statics, dynamics} =
      Enum.reduce(typed_imports, {[], []}, fn
        {:static, spec}, {s, d} -> {[spec | s], d}
        {:dynamic, spec}, {s, d} -> {s, [spec | d]}
      end)

    %DuskmoonBundler.Builder.Dependencies{
      static: Enum.reverse(statics),
      dynamic: Enum.reverse(dynamics),
      requires: requires
    }
  end
end
