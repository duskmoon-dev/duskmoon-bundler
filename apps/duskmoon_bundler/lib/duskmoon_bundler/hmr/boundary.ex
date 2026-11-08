defmodule DuskmoonBundler.HMR.Boundary do
  @moduledoc """
  Detects HMR boundaries from the dev module graph and source ASTs.

  When a file changes, DuskmoonBundler first checks `DuskmoonBundler.HMR.ModuleGraph` for served
  importers and self-accepting modules. If the file has not entered the dev
  module graph yet, boundary lookup falls back to `DuskmoonBundler.HMR.ImportGraph` raw
  specifiers. If no self-accepting boundary is found, the client performs a full
  reload.
  """

  @doc """
  Check if a module's source code contains `import.meta.hot.accept()`.
  """
  @spec self_accepting?(String.t()) :: boolean()
  def self_accepting?(source) do
    case OXC.parse(source, "hmr-boundary.js") do
      {:ok, ast} -> ast_self_accepting?(ast)
      {:error, _} -> false
    end
  end

  @doc """
  Find the HMR boundary for a changed file.

  Returns `{:ok, boundary_path}` when the update is accepted by exactly one
  boundary. When propagation needs several boundaries, or any importer path
  reaches a root without a boundary, returns `:full_reload`. Use
  `find_boundaries/2` to receive every boundary.

  The `read_source` function is called with an absolute path and should
  return the module's source code for boundary detection.
  """
  @spec find_boundary(String.t(), (String.t() -> String.t() | nil)) ::
          {:ok, String.t()} | :full_reload
  def find_boundary(changed_path, read_source) do
    case find_boundaries(changed_path, read_source) do
      {:ok, [boundary]} -> {:ok, boundary}
      _ -> :full_reload
    end
  end

  @doc """
  Find every HMR boundary for a changed file.

  Walks upward through the module graph from `changed_path` (falling back to
  the raw import graph). Every importer path must reach a module that accepts
  the update; all such boundaries are collected. If any path reaches a module
  without importers (an entry) before a boundary, returns `:full_reload`.
  """
  @spec find_boundaries(String.t(), (String.t() -> String.t() | nil)) ::
          {:ok, [String.t()]} | :full_reload
  def find_boundaries(changed_path, read_source) do
    source = read_source.(changed_path)

    cond do
      source && self_accepting?(source) ->
        {:ok, [changed_path]}

      graph_result = find_graph_boundaries(changed_path, read_source) ->
        graph_result

      true ->
        walker = %{
          key: & &1,
          parents: &find_importers/1,
          accepts?: &source_accepts_update?(read_source.(&1), &1, changed_path),
          boundary: & &1
        }

        propagate_all([changed_path], walker, MapSet.new([changed_path]))
    end
  end

  defp ast_self_accepting?(ast) do
    {_ast, found?} =
      OXC.postwalk(ast, false, fn
        node, false -> {node, accept_call?(node)}
        node, true -> {node, true}
      end)

    found?
  end

  defp accept_call?(node) when is_map(node) do
    result =
      DuskmoonBundler.JS.AST.call_member_arguments(
        node,
        {:meta_property, "import", "meta", "hot"},
        "accept"
      )

    case result do
      {:ok, []} ->
        true

      {:ok, [%{type: type} | _]}
      when type in [:arrow_function_expression, :function_expression] ->
        true

      _ ->
        false
    end
  end

  defp accept_call?(_node), do: false

  defp dependency_accepting?(source, importer_path, changed_path) do
    source
    |> dependency_accept_specifiers()
    |> Enum.any?(&specifier_matches_changed?(&1, importer_path, changed_path))
  end

  defp dependency_accept_specifiers(source) do
    case OXC.parse(source, "hmr-boundary.js") do
      {:ok, ast} -> ast_dependency_accept_specifiers(ast)
      {:error, _} -> []
    end
  end

  defp ast_dependency_accept_specifiers(ast) do
    {_ast, specifiers} =
      OXC.postwalk(ast, [], fn
        node, specifiers -> {node, specifiers ++ dependency_accept_specifiers_from_node(node)}
      end)

    specifiers
  end

  defp dependency_accept_specifiers_from_node(node) when is_map(node) do
    case DuskmoonBundler.JS.AST.call_member_arguments(
           node,
           {:meta_property, "import", "meta", "hot"},
           "accept"
         ) do
      {:ok, [first | _]} -> accept_dependency_specifiers(first)
      _ -> []
    end
  end

  defp dependency_accept_specifiers_from_node(_node), do: []

  defp accept_dependency_specifiers(%{type: :literal, value: specifier})
       when is_binary(specifier),
       do: [specifier]

  defp accept_dependency_specifiers(%{type: :array_expression, elements: elements}) do
    Enum.flat_map(elements, &accept_dependency_specifiers/1)
  end

  defp accept_dependency_specifiers(_node), do: []

  defp specifier_matches_changed?(specifier, importer_path, changed_path) do
    resolved = Path.expand(Path.join(Path.dirname(importer_path), specifier))
    resolved == changed_path or Path.rootname(resolved) == Path.rootname(changed_path)
  end

  defp find_graph_boundaries(changed_path, read_source) do
    case DuskmoonBundler.HMR.ModuleGraph.get_by_file(changed_path) do
      [] ->
        nil

      nodes ->
        walker = %{
          key: & &1.id,
          parents: &graph_importers/1,
          accepts?: &graph_accepts_update?(&1, changed_path, read_source),
          boundary: & &1.file
        }

        propagate_all(nodes, walker, MapSet.new(nodes, & &1.id))
    end
  end

  defp graph_importers(node) do
    Enum.flat_map(node.importers, &List.wrap(DuskmoonBundler.HMR.ModuleGraph.get_by_id(&1)))
  end

  defp graph_accepts_update?(node, changed_path, read_source) do
    case read_source.(node.file) do
      source when is_binary(source) -> source_accepts_update?(source, node.file, changed_path)
      _ -> node.self_accepting
    end
  end

  defp source_accepts_update?(nil, _path, _changed_path), do: false

  defp source_accepts_update?(source, path, changed_path) do
    self_accepting?(source) or dependency_accepting?(source, path, changed_path)
  end

  # Propagates from each start module; every importer path must hit a boundary.
  defp propagate_all(modules, walker, visited) do
    modules
    |> Enum.reduce_while({[], visited}, fn module, acc ->
      case propagate(module, walker, acc) do
        :full_reload -> {:halt, :full_reload}
        acc -> {:cont, acc}
      end
    end)
    |> case do
      :full_reload -> :full_reload
      {boundaries, _visited} -> {:ok, boundaries |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp propagate(module, walker, acc) do
    case walker.parents.(module) do
      [] -> :full_reload
      parents -> Enum.reduce_while(parents, acc, &visit_parent(&1, walker, &2))
    end
  end

  defp visit_parent(parent, walker, {boundaries, visited} = acc) do
    key = walker.key.(parent)

    cond do
      MapSet.member?(visited, key) ->
        {:cont, acc}

      walker.accepts?.(parent) ->
        {:cont, {[walker.boundary.(parent) | boundaries], MapSet.put(visited, key)}}

      true ->
        case propagate(parent, walker, {boundaries, MapSet.put(visited, key)}) do
          :full_reload -> {:halt, :full_reload}
          acc -> {:cont, acc}
        end
    end
  end

  defp find_importers(path) do
    DuskmoonBundler.HMR.ImportGraph.dependents_matching(fn importer, specifier ->
      relative_specifier_resolves_to?(specifier, importer, path)
    end)
  end

  # Only relative specifiers are resolvable here; bare and alias specifiers never match.
  defp relative_specifier_resolves_to?(specifier, importer, path) do
    if String.starts_with?(specifier, ["./", "../"]) do
      resolved = Path.expand(specifier, Path.dirname(importer))

      resolved == path or resolved == Path.rootname(path) or
        Path.rootname(resolved) == Path.rootname(path) or
        (Path.basename(path) |> Path.rootname() == "index" and resolved == Path.dirname(path))
    else
      false
    end
  end
end
