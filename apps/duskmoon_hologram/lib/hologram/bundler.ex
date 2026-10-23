defmodule Hologram.Bundler do
  @moduledoc false

  alias DuskmoonBundler.Builder
  alias DuskmoonBundler.Builder.Collector
  alias DuskmoonBundler.Builder.Context

  # Collect before bundling so incremental builds also track imports whose code
  # the optimizer removes. Sourcemaps alone cannot provide that information.
  def build!(entry, name, outdir, opts) do
    entry = Path.expand(entry)
    node_modules = opts[:node_modules_path]
    resolve_dirs = opts[:resolve_dirs] || []

    context = %Context{node_modules: node_modules, resolve_dirs: resolve_dirs}

    with {:ok, modules, _deps, _workers, _labels, _paths} <- Collector.collect(entry, context),
         {:ok, %{js: %{path: path}}} <-
           Builder.build(
             entry: entry,
             name: name,
             outdir: outdir,
             root: Path.dirname(entry),
             node_modules: node_modules,
             resolve_dirs: resolve_dirs,
             public_dir: false,
             target: :es2021,
             minify: true,
             sourcemap: true,
             code_splitting: false,
             tree_shaking: false,
             format: :iife
           ) do
      {path, Enum.map(modules, &elem(&1, 0))}
    else
      error ->
        raise RuntimeError,
              "DuskmoonBundler failed for entry file: #{entry}: #{inspect(error)}"
    end
  end
end
