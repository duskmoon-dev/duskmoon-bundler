defmodule DuskmoonBundler.Builder.Rewriter do
  @moduledoc "Rewrites production bundle imports, workers, externals, and chunk references."

  alias DuskmoonBundler.Builder.Externals
  alias DuskmoonBundler.JS.{Asset, AST, Patch}
  alias DuskmoonBundler.JS.Transforms.Workers

  @dynamic_import_keyword "import"
  @dynamic_import_placeholder_prefix "__duskmoon_bundler_dynamic_import__"
  @worker_specifier_prefix "__duskmoon_worker__/"

  def rewrite_external_imports(js_files, ctx) do
    if MapSet.size(ctx.external_set) == 0 do
      js_files
    else
      Externals.rewrite_imports(js_files, ctx.external_set, ctx.external_globals)
    end
  end

  def external_chunk_imports(js_files, chunk_import_map) do
    js_files
    |> Enum.flat_map(fn {_label, code} ->
      collect_external_chunk_imports(code, chunk_import_map)
    end)
    |> Enum.uniq()
  end

  def protect_dynamic_imports(js_files) do
    placeholder = dynamic_import_placeholder(js_files)

    protected =
      Enum.map(js_files, fn {label, code} ->
        {label, protect_dynamic_imports_in_code(code, placeholder)}
      end)

    {protected, placeholder}
  end

  def restore_dynamic_imports(code, placeholder) do
    String.replace(code, placeholder <> "(", @dynamic_import_keyword <> "(")
  end

  def rewrite_chunk_imports(code, chunk_import_map, chunk_url_map) do
    case OXC.parse(code, "chunk.js") do
      {:ok, ast} ->
        patches = collect_import_patches(ast, chunk_import_map, chunk_url_map)
        worker_patches = collect_worker_patches(code, chunk_import_map, chunk_url_map)
        all_patches = patches ++ worker_patches
        if all_patches == [], do: code, else: Patch.apply(code, all_patches)

      {:error, _} ->
        code
    end
  end

  @doc "Preserve source-module bindings when a chunk exposes them under unique named exports."
  def rewrite_chunk_default_imports(code, aliases) when map_size(aliases) == 0, do: code

  def rewrite_chunk_default_imports(code, aliases) do
    case OXC.parse(code, "chunk.js") do
      {:ok, ast} ->
        patches =
          Enum.flat_map(ast.body, fn
            %{source: %{value: source}} = node when is_map_key(aliases, source) ->
              chunk_binding_patches(node, code, export_aliases(aliases[source]))

            _node ->
              []
          end)

        if patches == [], do: code, else: Patch.apply(code, patches)

      {:error, _} ->
        code
    end
  end

  # Keep support for the original source => default alias mapping.
  defp export_aliases(name) when is_binary(name), do: %{"default" => name}
  defp export_aliases(names), do: names

  defp chunk_binding_patches(%{type: :import_declaration} = node, code, names) do
    aliased? =
      Enum.any?(node.specifiers, fn
        %{type: :import_default_specifier} ->
          Map.has_key?(names, "default")

        %{type: :import_specifier, imported: imported} ->
          Map.has_key?(names, binding_name(imported))

        _specifier ->
          false
      end)

    namespace? = Enum.any?(node.specifiers, &(&1.type == :import_namespace_specifier))

    if aliased? and not namespace? do
      bindings =
        Enum.map_join(node.specifiers, ", ", fn
          %{type: :import_default_specifier, local: local} ->
            Map.get(names, "default", "default") <> " as " <> source_span(code, local)

          %{type: :import_specifier, imported: imported, local: local} = specifier ->
            case Map.fetch(names, binding_name(imported)) do
              {:ok, name} -> name <> " as " <> source_span(code, local)
              :error -> source_span(code, specifier)
            end
        end)

      [
        Patch.new(
          node.start,
          node.source.start,
          "import { #{bindings} } from "
        )
      ]
    else
      []
    end
  end

  defp chunk_binding_patches(%{type: :export_named_declaration} = node, code, names) do
    Enum.flat_map(node.specifiers, fn specifier ->
      case Map.fetch(names, binding_name(specifier.local)) do
        {:ok, name} ->
          replacement = name <> " as " <> source_span(code, specifier.exported)
          [Patch.replace_selector(specifier, replacement)]

        :error ->
          []
      end
    end)
  end

  defp chunk_binding_patches(_node, _code, _names), do: []

  defp binding_name(%{name: name}), do: name
  defp binding_name(%{value: value}), do: value

  defp source_span(code, %{start: start, end: finish}),
    do: binary_part(code, start, finish - start)

  @doc """
  Give every worker reference a specifier unique to its resolved file.

  Modules in different directories can share a relative worker specifier, which
  would be indistinguishable once they are bundled into the same file.
  """
  def disambiguate_workers(js_files, workers, _path_labels) when workers == %{},
    do: {js_files, workers}

  def disambiguate_workers(js_files, workers, path_labels) do
    workers =
      Map.new(workers, fn {importer, specifiers} ->
        {importer,
         Map.new(specifiers, fn {specifier, resolved_path} ->
           {specifier,
            {@worker_specifier_prefix <> Map.fetch!(path_labels, resolved_path), resolved_path}}
         end)}
      end)

    label_to_path = Map.new(path_labels, fn {path, label} -> {label, path} end)

    js_files =
      Enum.map(js_files, fn {label, code} ->
        specifiers = Map.get(workers, label_to_path[label], %{})

        rewritten =
          Workers.rewrite(code, label, fn specifier ->
            case Map.fetch(specifiers, specifier) do
              {:ok, {unique_specifier, _resolved_path}} -> {:rewrite, unique_specifier}
              :error -> :keep
            end
          end)

        case rewritten do
          {:ok, code} -> {label, code}
          {:error, _} -> {label, code}
        end
      end)

    {js_files,
     Map.new(workers, fn {importer, specifiers} ->
       {importer, specifiers |> Map.values() |> Map.new()}
     end)}
  end

  def worker_map_for_modules(module_paths, ctx) do
    module_paths
    |> Enum.flat_map(fn importer -> ctx.workers |> Map.get(importer, %{}) |> Map.to_list() end)
    |> worker_filename_map(ctx)
  end

  def all_worker_map(ctx) do
    ctx.workers
    |> Map.values()
    |> Enum.flat_map(&Map.to_list/1)
    |> worker_filename_map(ctx)
  end

  def rewrite_dynamic_preloads(code, preload_map) when preload_map == %{}, do: code

  def rewrite_dynamic_preloads(code, preload_map) do
    case OXC.parse(code, "chunk.js") do
      {:ok, ast} ->
        patches = collect_dynamic_preload_patches(ast, code, preload_map)

        if patches == [] do
          code
        else
          preload_helper() <> Patch.apply(code, patches)
        end

      {:error, _} ->
        code
    end
  end

  def rewrite_worker_urls(code, worker_map, _filename) when worker_map == %{}, do: code

  def rewrite_worker_urls(code, worker_map, filename) do
    case Workers.rewrite(code, to_string(filename), fn specifier ->
           case Map.fetch(worker_map, specifier) do
             {:ok, worker_filename} -> {:rewrite, "./#{worker_filename}"}
             :error -> :keep
           end
         end) do
      {:ok, rewritten} -> rewritten
      {:error, _} -> code
    end
  end

  defp collect_dynamic_preload_patches(ast, code, preload_map) do
    {_ast, patches} =
      OXC.postwalk(ast, [], fn
        %{type: :import_expression, source: source, start: start, end: finish} = node, patches
        when is_integer(start) and is_integer(finish) ->
          case AST.string_literal_span(source) do
            {:ok, specifier, _s, _e} ->
              case Map.get(preload_map, specifier) do
                deps when is_list(deps) and deps != [] ->
                  import_expression = binary_part(code, start, finish - start)

                  replacement = [
                    "__duskmoon_bundlerPreload(() => ",
                    import_expression,
                    ", ",
                    Jason.encode!(deps),
                    ")"
                  ]

                  {node, [Patch.new(start, finish, replacement) | patches]}

                _ ->
                  {node, patches}
              end

            nil ->
              {node, patches}
          end

        node, patches ->
          {node, patches}
      end)

    patches
  end

  defp preload_helper do
    Asset.compiled!("runtime/preload.ts") <> "\n"
  end

  defp worker_filename_map(worker_specs, ctx) do
    worker_specs
    |> Map.new(fn {specifier, resolved_path} ->
      {specifier, Map.get(ctx.worker_results, resolved_path)}
    end)
    |> Enum.reject(fn {_specifier, filename} -> is_nil(filename) end)
    |> Map.new()
  end

  defp collect_external_chunk_imports(code, chunk_import_map) do
    case OXC.parse(code, "chunk.js") do
      {:ok, ast} ->
        {_ast, specifiers} =
          OXC.postwalk(ast, [], fn
            %{source: %{type: :literal, value: spec}} = node, specifiers
            when node.type in [
                   :import_declaration,
                   :export_named_declaration,
                   :export_all_declaration
                 ] and
                   is_binary(spec) ->
              maybe_external_chunk_specifier(node, specifiers, spec, chunk_import_map)

            %{type: :import_expression, source: %{type: :literal, value: spec}} = node, specifiers
            when is_binary(spec) ->
              maybe_external_chunk_specifier(node, specifiers, spec, chunk_import_map)

            node, specifiers ->
              {node, specifiers}
          end)

        specifiers

      {:error, _} ->
        []
    end
  end

  defp maybe_external_chunk_specifier(node, specifiers, spec, chunk_import_map) do
    if Map.has_key?(chunk_import_map, spec) do
      {node, [spec | specifiers]}
    else
      {node, specifiers}
    end
  end

  defp dynamic_import_placeholder(js_files) do
    code = Enum.map_join(js_files, "\n", fn {_label, code} -> code end)

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn suffix ->
      candidate = @dynamic_import_placeholder_prefix <> Integer.to_string(suffix) <> "__"
      if String.contains?(code, candidate), do: nil, else: candidate
    end)
  end

  defp protect_dynamic_imports_in_code(code, placeholder) do
    case OXC.parse(code, "chunk.js") do
      {:ok, ast} ->
        patches = collect_dynamic_import_protection_patches(ast, placeholder)
        if patches == [], do: code, else: Patch.apply(code, patches)

      {:error, _} ->
        code
    end
  end

  defp collect_dynamic_import_protection_patches(ast, placeholder) do
    {_ast, patches} =
      OXC.postwalk(ast, [], fn
        %{type: :import_expression, start: start} = node, patches when is_integer(start) ->
          {node, [dynamic_import_protection_patch(start, placeholder) | patches]}

        node, patches ->
          {node, patches}
      end)

    patches
  end

  defp dynamic_import_protection_patch(start, placeholder) do
    Patch.new(start, start + byte_size(@dynamic_import_keyword), placeholder)
  end

  defp collect_import_patches(ast, chunk_import_map, chunk_url_map) do
    {_ast, patches} =
      OXC.postwalk(ast, [], fn
        %{type: type, source: source} = node, patches
        when type in [:import_declaration, :export_named_declaration, :export_all_declaration] ->
          maybe_patch_source(node, patches, source, chunk_import_map, chunk_url_map)

        %{
          type: :import_expression,
          source: %{
            type: :template_literal,
            expressions: [],
            quasis: [%{value: %{cooked: spec}}],
            start: s,
            end: e
          }
        } = node,
        patches
        when is_binary(spec) ->
          maybe_patch_specifier(node, patches, spec, s, e, chunk_import_map, chunk_url_map)

        %{type: :import_expression, source: source} = node, patches ->
          maybe_patch_source(node, patches, source, chunk_import_map, chunk_url_map)

        node, patches ->
          {node, patches}
      end)

    patches
  end

  defp collect_worker_patches(code, chunk_import_map, chunk_url_map) do
    case OXC.select(code, "chunk.js", :workers) do
      {:ok, workers} ->
        Enum.reduce(workers, [], fn worker, patches ->
          spec = Patch.selector_specifier(worker)
          maybe_patch_selector(worker, patches, spec, chunk_import_map, chunk_url_map)
        end)

      {:error, _} ->
        []
    end
  end

  defp maybe_patch_selector(selector, patches, spec, chunk_import_map, chunk_url_map) do
    with {:ok, chunk_id} <- Map.fetch(chunk_import_map, spec),
         url when is_binary(url) <- chunk_url_map[chunk_id] do
      [Patch.replace_selector(selector, "'./#{url}'") | patches]
    else
      _ -> patches
    end
  end

  defp maybe_patch_source(node, patches, source, chunk_import_map, chunk_url_map) do
    case AST.string_literal_span(source) do
      {:ok, spec, s, e} ->
        maybe_patch_specifier(node, patches, spec, s, e, chunk_import_map, chunk_url_map)

      nil ->
        {node, patches}
    end
  end

  defp maybe_patch_specifier(node, patches, spec, s, e, chunk_import_map, chunk_url_map) do
    {node, maybe_patch_specifier(patches, spec, s, e, chunk_import_map, chunk_url_map)}
  end

  defp maybe_patch_specifier(patches, spec, s, e, chunk_import_map, chunk_url_map) do
    with {:ok, chunk_id} <- Map.fetch(chunk_import_map, spec),
         url when is_binary(url) <- chunk_url_map[chunk_id] do
      [Patch.new(s, e, "'./#{url}'") | patches]
    else
      _ -> patches
    end
  end
end
