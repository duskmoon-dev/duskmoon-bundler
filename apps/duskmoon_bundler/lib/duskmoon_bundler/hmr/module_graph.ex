defmodule DuskmoonBundler.HMR.ModuleGraph do
  @moduledoc """
  ETS-backed dev-server module graph.

  The graph is keyed by served URL, resolved module id, and source file. It is
  the primary source for HMR boundary lookup: served modules record their
  resolved imports, importers, query variants, and whether the module accepts
  itself with `import.meta.hot.accept()`.

  Importer links and file-to-id mappings live as individual rows in a separate
  `:bag` table, so concurrent request processes add links with a single atomic
  insert instead of a read-modify-write of a shared node.
  """

  @table :duskmoon_bundler_hmr_module_graph
  @links :duskmoon_bundler_hmr_module_graph_links

  defmodule Node do
    @moduledoc "A dev-server module graph node."

    defstruct url: nil,
              id: nil,
              file: nil,
              type: :js,
              imports: MapSet.new(),
              importers: MapSet.new(),
              self_accepting: false,
              last_invalidated_at: nil
  end

  @doc "Create the module graph ETS tables."
  def create_table do
    DuskmoonBundler.ETS.create_named_set(@table)
    create_links_table()
  end

  @doc "Upsert a module and update importer links for its resolved imports."
  def update_module(url, id, file, imports, opts \\ []) do
    remove_old_importer_links(get_by_id(id), id)

    node = %Node{
      url: url,
      id: id,
      file: file,
      type: Keyword.get(opts, :type, module_type(url)),
      imports: MapSet.new(imports),
      self_accepting: Keyword.get(opts, :self_accepting, false)
    }

    put_node(node)
    :ets.insert(@links, Enum.map(node.imports, &{{:importers, &1}, id}))
    :ok
  end

  def get_by_url(url), do: lookup({:url, url})
  def get_by_id(id), do: lookup({:id, id})

  def get_by_file(file) do
    @links
    |> :ets.lookup({:file, file})
    |> Enum.flat_map(fn {_, id} -> List.wrap(get_by_id(id)) end)
  end

  @doc "Mark every graph node for a file as invalidated and return affected nodes."
  def invalidate_file(file, timestamp \\ System.system_time(:millisecond)) do
    nodes = get_by_file(file)

    Enum.each(nodes, fn node ->
      put_node(%{node | last_invalidated_at: timestamp})
    end)

    nodes
  end

  @doc "Remove all nodes for a file and unlink them from importers/imports."
  def remove_file(file) do
    file
    |> get_by_file()
    |> Enum.each(&remove_node/1)

    :ets.delete(@links, {:file, file})
    :ok
  end

  def clear do
    DuskmoonBundler.ETS.clear(@table)

    if :ets.whereis(@links) == :undefined,
      do: create_links_table(),
      else: :ets.delete_all_objects(@links)

    :ok
  end

  defp create_links_table do
    if :ets.whereis(@links) == :undefined do
      :ets.new(@links, [:named_table, :bag, :public, read_concurrency: true])
    end

    :ok
  end

  # Importers are stored as link rows, never on the persisted node.
  defp put_node(node) do
    :ets.insert(@table, [
      {{:url, node.url}, node.id},
      {{:id, node.id}, %{node | importers: MapSet.new()}}
    ])

    :ets.insert(@links, {{:file, node.file}, node.id})
  end

  defp importers_of(id) do
    @links
    |> :ets.lookup({:importers, id})
    |> MapSet.new(fn {_, importer_id} -> importer_id end)
  end

  defp remove_old_importer_links(nil, _id), do: :ok

  defp remove_old_importer_links(node, id) do
    Enum.each(node.imports, &:ets.delete_object(@links, {{:importers, &1}, id}))
  end

  defp remove_node(node) do
    remove_old_importer_links(node, node.id)

    Enum.each(node.importers, fn importer_id ->
      case get_by_id(importer_id) do
        nil -> :ok
        importer -> put_node(%{importer | imports: MapSet.delete(importer.imports, node.id)})
      end
    end)

    :ets.delete(@links, {:importers, node.id})
    :ets.delete(@table, {:url, node.url})
    :ets.delete(@table, {:id, node.id})
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{_, %Node{} = node}] -> %{node | importers: importers_of(node.id)}
      [{_, id}] when elem(key, 0) == :url -> get_by_id(id)
      [] -> nil
    end
  end

  defp module_type(url) do
    cond do
      String.contains?(url, ".css") -> :css
      DuskmoonBundler.Assets.asset?(url) -> :asset
      true -> :js
    end
  end
end
