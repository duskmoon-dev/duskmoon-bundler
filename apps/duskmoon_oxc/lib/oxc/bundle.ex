defmodule OXC.Bundle do
  @moduledoc """
  Composable JavaScript bundling pipeline.

  Build immutable bundle configuration with pipeline-friendly functions, then
  execute the native Rolldown run once with `run/1`.
  """

  alias OXC.Bundle.{Entry, Result}

  defstruct entries: [],
            files: [],
            cwd: "",
            outdir: nil,
            format: :esm,
            exports: :auto,
            minify: false,
            treeshake: false,
            sourcemap: false,
            drop_console: false,
            banner: nil,
            footer: nil,
            preamble: nil,
            define: %{},
            external: [],
            conditions: [],
            main_fields: [],
            modules: [],
            module_types: %{},
            preserve_entry_signatures: nil,
            jsx: :automatic,
            jsx_factory: "",
            jsx_fragment: "",
            import_source: "",
            target: "",
            entry_file_names: nil,
            chunk_file_names: nil,
            asset_file_names: nil

  @type t :: %__MODULE__{}

  @type entry_input ::
          Entry.t()
          | map()
          | {String.t(), String.t()}
          | {String.t(), String.t(), iodata()}
          | String.t()

  @doc """
  Build a bundle configuration.

  Accepts `:entries`, any struct field (for example `:files`, `:cwd`,
  `:outdir`, `:format`, `:minify`, `:treeshake`, `:drop_console`), and the
  grouped `:resolve`, `:transform`, and `:output` keyword lists taken by the
  functions of the same name. Unknown options raise `ArgumentError`.

  ## Examples

      iex> bundle = OXC.Bundle.new(entries: ["src/main.ts"], format: :cjs, minify: true)
      iex> {bundle.format, bundle.minify, hd(bundle.entries).import}
      {:cjs, true, "src/main.ts"}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__)
    |> entries(Keyword.get(opts, :entries, []))
    |> apply_opts(Keyword.delete(opts, :entries))
  end

  @doc """
  Append an entry.

  An entry is an import path, a `{name, import}` tuple, a
  `{name, import, source}` tuple for a virtual entry, a map with `:import`, or
  an `OXC.Bundle.Entry`.
  """
  @spec entry(t(), entry_input()) :: t()
  def entry(%__MODULE__{} = bundle, entry), do: entries(bundle, bundle.entries ++ [entry])

  @doc "Append a virtual `{path, source}` file that entries can import."
  @spec file(t(), {String.t(), iodata()}) :: t()
  def file(%__MODULE__{} = bundle, {path, source}),
    do: files(bundle, bundle.files ++ [{path, source}])

  @doc "Replace the virtual `{path, source}` files that entries can import."
  @spec files(t(), [{String.t(), iodata()}]) :: t()
  def files(%__MODULE__{} = bundle, files) when is_list(files), do: %{bundle | files: files}

  @doc "Replace the entries. See `entry/2` for the accepted shapes."
  @spec entries(t(), [entry_input()]) :: t()
  def entries(%__MODULE__{} = bundle, entries) when is_list(entries) do
    %{bundle | entries: Enum.map(entries, &Entry.new/1)}
  end

  @doc "Set the project directory used to resolve filesystem entries and packages."
  @spec cwd(t(), String.t() | nil) :: t()
  def cwd(%__MODULE__{} = bundle, cwd), do: %{bundle | cwd: cwd || ""}

  @doc "Set the directory outputs are written to. With `nil`, nothing is written to disk."
  @spec outdir(t(), String.t() | nil) :: t()
  def outdir(%__MODULE__{} = bundle, outdir), do: %{bundle | outdir: outdir}

  @doc "Set the output format: `:esm` (default), `:cjs`, or `:iife`."
  @spec format(t(), :esm | :cjs | :iife) :: t()
  def format(%__MODULE__{} = bundle, format), do: %{bundle | format: format}

  @doc """
  Set resolver options: `:external`, `:conditions`, `:main_fields`, and
  `:modules`. Options that are not given keep their current value.
  """
  @spec resolve(t(), keyword()) :: t()
  def resolve(%__MODULE__{} = bundle, opts) do
    %{
      bundle
      | external: Keyword.get(opts, :external, bundle.external),
        conditions: Keyword.get(opts, :conditions, bundle.conditions),
        main_fields: Keyword.get(opts, :main_fields, bundle.main_fields),
        modules: Keyword.get(opts, :modules, bundle.modules)
    }
  end

  @doc """
  Set transform options: `:jsx`, `:jsx_factory`, `:jsx_fragment`,
  `:import_source`, `:target`, `:define`, and `:module_types`. Options that are
  not given keep their current value. See `OXC.bundle/2` for their meaning.
  """
  @spec transform(t(), keyword()) :: t()
  def transform(%__MODULE__{} = bundle, opts) do
    %{
      bundle
      | jsx: Keyword.get(opts, :jsx, bundle.jsx),
        jsx_factory: Keyword.get(opts, :jsx_factory, bundle.jsx_factory),
        jsx_fragment: Keyword.get(opts, :jsx_fragment, bundle.jsx_fragment),
        import_source: Keyword.get(opts, :import_source, bundle.import_source),
        target: Keyword.get(opts, :target, bundle.target),
        define: Keyword.get(opts, :define, bundle.define),
        module_types: Keyword.get(opts, :module_types, bundle.module_types)
    }
  end

  @doc """
  Set output options: `:entry_file_names`, `:chunk_file_names`,
  `:asset_file_names`, `:banner`, `:footer`, `:preamble`, `:sourcemap`,
  `:exports`, and `:preserve_entry_signatures`. Options that are not given keep
  their current value. See `OXC.bundle/2` for their meaning.
  """
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = bundle, opts) do
    %{
      bundle
      | entry_file_names: Keyword.get(opts, :entry_file_names, bundle.entry_file_names),
        chunk_file_names: Keyword.get(opts, :chunk_file_names, bundle.chunk_file_names),
        asset_file_names: Keyword.get(opts, :asset_file_names, bundle.asset_file_names),
        banner: Keyword.get(opts, :banner, bundle.banner),
        footer: Keyword.get(opts, :footer, bundle.footer),
        preamble: Keyword.get(opts, :preamble, bundle.preamble),
        sourcemap: Keyword.get(opts, :sourcemap, bundle.sourcemap),
        exports: Keyword.get(opts, :exports, bundle.exports),
        preserve_entry_signatures:
          Keyword.get(opts, :preserve_entry_signatures, bundle.preserve_entry_signatures)
    }
  end

  @doc "Enable or disable minification."
  @spec minify(t(), boolean()) :: t()
  def minify(%__MODULE__{} = bundle, value \\ true), do: %{bundle | minify: value}

  @doc "Enable or disable tree-shaking."
  @spec treeshake(t(), boolean()) :: t()
  def treeshake(%__MODULE__{} = bundle, value \\ true), do: %{bundle | treeshake: value}

  @doc """
  Run the bundle and return every generated chunk and asset.

  Returns `{:ok, %OXC.Bundle.Result{}}` with the outputs and any Rolldown
  warnings, or `{:error, errors}` with a list of `%{message: String.t()}` maps.
  Raises `ArgumentError` for an unknown `:format` or `:jsx` runtime, a `:define`
  that is not a map of expression strings, or a `:target` that is not a string
  or atom.
  """
  @spec run(t()) :: {:ok, Result.t()} | {:error, [OXC.error()]}
  def run(%__MODULE__{} = bundle) do
    case OXC.Native.bundle_run(to_native(bundle)) do
      {:ok, result} -> {:ok, Result.new(result)}
      {:error, errors} -> {:error, Enum.map(errors, &atomize_error/1)}
    end
  end

  defp atomize_error(%{"message" => message}), do: %{message: message}
  defp atomize_error(error), do: error

  defp apply_opts(bundle, opts) do
    Enum.reduce(opts, bundle, fn
      {:cwd, value}, acc -> cwd(acc, value)
      {:outdir, value}, acc -> outdir(acc, value)
      {:format, value}, acc -> format(acc, value)
      {:resolve, value}, acc -> resolve(acc, value)
      {:transform, value}, acc -> transform(acc, value)
      {:output, value}, acc -> output(acc, value)
      {:minify, value}, acc -> minify(acc, value)
      {:treeshake, value}, acc -> treeshake(acc, value)
      {key, value}, acc when is_map_key(acc, key) -> Map.put(acc, key, value)
      {key, _value}, _acc -> raise ArgumentError, "unknown OXC.Bundle option #{inspect(key)}"
    end)
  end

  defp to_native(%__MODULE__{} = bundle) do
    %{
      entries: Enum.map(bundle.entries, &Entry.to_native/1),
      files: Enum.map(bundle.files, fn {path, source} -> %{path: path, source: source} end),
      cwd: bundle.cwd || "",
      outdir: bundle.outdir,
      format: OXC.Options.format!(bundle.format),
      exports: bundle.exports,
      minify: bundle.minify,
      treeshake: bundle.treeshake,
      sourcemap: bundle.sourcemap,
      drop_console: bundle.drop_console,
      banner: bundle.banner,
      footer: bundle.footer,
      preamble: bundle.preamble,
      define: OXC.Options.define!(bundle.define),
      external: bundle.external,
      conditions: bundle.conditions,
      main_fields: bundle.main_fields,
      modules: bundle.modules,
      module_types: bundle.module_types,
      preserve_entry_signatures: bundle.preserve_entry_signatures,
      jsx: OXC.Options.jsx!(bundle.jsx),
      jsx_factory: bundle.jsx_factory,
      jsx_fragment: bundle.jsx_fragment,
      import_source: bundle.import_source,
      target: OXC.Options.target!(bundle.target),
      entry_file_names: bundle.entry_file_names,
      chunk_file_names: bundle.chunk_file_names,
      asset_file_names: bundle.asset_file_names
    }
  end
end
