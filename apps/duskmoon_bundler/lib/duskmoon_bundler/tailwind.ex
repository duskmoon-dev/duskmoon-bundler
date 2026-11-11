defmodule DuskmoonBundler.Tailwind do
  @moduledoc """
  Tailwind CSS integration — scan source files for candidates and compile CSS.

  Uses Oxide for fast parallel content scanning and QuickBEAM to run
  the Tailwind CSS compiler. No Node.js or CLI required.

  ## Usage

      # In your config:
      config :duskmoon_bundler, :tailwind,
        sources: [
          %{base: "lib/", pattern: "**/*.{ex,heex}"},
          %{base: "assets/", pattern: "**/*.{vue,ts,tsx}"}
        ]

      # Generate CSS:
      {:ok, css} = DuskmoonBundler.Tailwind.build()

  ## Tailwind directives

  DuskmoonBundler supports Tailwind's CSS-first directives like `@theme`, `@source`,
  `@utility`, `@variant`, and `@apply` through the Tailwind compiler. CSS source
  declarations are scanned alongside configured sources, relative to their
  declaring stylesheet, including explicitly selected ignored directories.

  DuskmoonBundler also resolves local `@import`, `@reference`, `@plugin`, and `@config`
  files inside QuickBEAM, plus installed package plugins like
  `@tailwindcss/typography`.
  """

  use GenServer

  def start_link(opts \\ []) do
    server_opts = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Compile Tailwind CSS from scanned candidates.

  Scans all configured source directories for Tailwind class candidates,
  then runs the Tailwind compiler to generate CSS.

  ## Options

    * `:css` — custom input CSS (default: Tailwind's base with theme + preflight + utilities)
    * `:css_base` — base directory for resolving local `@import`, `@reference`, `@plugin`, `@config`, and `@source` paths
    * `:resolve_dirs` — additional package directories for resolving bare stylesheet imports
    * `:sources` — override source patterns (default: from config)
    * `:minify` — minify the output CSS (default: `false`)
    * `:server` — Tailwind server to use (default: `DuskmoonBundler.Tailwind`)
  """
  @spec build(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:build, opts}, :infinity)
  end

  @doc """
  Incremental build — only process changed files and return CSS if new candidates found.

  Returns `{:ok, css}` if new candidates were found, `:unchanged` otherwise.
  Pass `force: true` to recompile changed CSS input even without new candidates.
  Use `:server` to select the same private server used for the initial build.
  """
  @spec rebuild(list(), keyword()) :: {:ok, String.t()} | :unchanged | {:error, term()}
  def rebuild(changed_files, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:rebuild, changed_files, opts},
      :infinity
    )
  end

  @impl true
  def init(opts) do
    sources = opts[:sources] || DuskmoonBundler.Config.tailwind()[:sources] || []
    resolve_dirs = normalize_resolve_dirs(opts[:resolve_dirs])

    {:ok,
     %{
       runtime: nil,
       scanner: nil,
       scanner_sources: nil,
       sources: sources,
       css_input: nil,
       css_base: File.cwd!(),
       default_resolve_dirs: resolve_dirs,
       resolve_dirs: resolve_dirs,
       last_css: nil
     }}
  end

  defp ensure_runtime(%{runtime: nil} = state) do
    local_tailwind_path = local_package_path("tailwindcss")

    runtime_packages = DuskmoonBundler.Tailwind.Loader.runtime_packages()

    runtime =
      DuskmoonBundler.JS.Runtime.ensure!(
        packages: runtime_packages,
        apis: [:browser, :node],
        handlers: fn runtime -> DuskmoonBundler.Tailwind.Loader.handlers(runtime.node_modules) end,
        define: fn runtime ->
          %{
            "TAILWIND_ROOT" =>
              local_tailwind_path ||
                DuskmoonBundler.JS.Runtime.package_path!(runtime, "tailwindcss"),
            "TAILWIND_DEFAULT_BASE" => File.cwd!()
          }
        end,
        entry: {:duskmoon_bundler_asset, "dev/tailwind.ts"}
      )

    scanner_sources = Enum.map(state.sources, &to_oxide_source/1)

    %{
      state
      | runtime: runtime,
        scanner: build_scanner(scanner_sources),
        scanner_sources: scanner_sources
    }
  end

  defp ensure_runtime(state), do: state

  defp local_package_path(package) do
    with node_modules when is_binary(node_modules) <-
           NPM.Resolution.PackageResolver.find_node_modules(File.cwd!()),
         path = Path.join(node_modules, package),
         true <- File.dir?(path) do
      path
    else
      _ -> nil
    end
  end

  @impl true
  def handle_call({:build, opts}, _from, state) do
    state = ensure_runtime(state)
    css_input = opts[:css]
    minify = Keyword.get(opts, :minify, false)
    css_base = opts[:css_base] || File.cwd!()
    sources = opts[:sources] || state.sources

    resolve_dirs =
      opts |> Keyword.get(:resolve_dirs, state.default_resolve_dirs) |> normalize_resolve_dirs()

    case compile_css(state, css_input, sources, css_base, resolve_dirs) do
      {:ok, css, scanner, scanner_sources} ->
        css = maybe_minify(css, minify)

        {:reply, {:ok, css},
         %{
           state
           | scanner: scanner,
             scanner_sources: scanner_sources,
             sources: sources,
             css_input: css_input,
             css_base: css_base,
             resolve_dirs: resolve_dirs,
             last_css: css
         }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:rebuild, changed_files, opts}, _from, state) do
    state = ensure_runtime(state)
    minify = Keyword.get(opts, :minify, false)
    css_input = Keyword.get(opts, :css, state.css_input)
    css_base = opts[:css_base] || state.css_base

    resolve_dirs =
      opts |> Keyword.get(:resolve_dirs, state.resolve_dirs) |> normalize_resolve_dirs()

    changed =
      Enum.map(changed_files, fn
        path when is_binary(path) ->
          %Oxide.Changed{file: path, extension: Path.extname(path) |> String.trim_leading(".")}

        map ->
          struct!(Oxide.Changed, map)
      end)

    if Oxide.scan_files(state.scanner, changed) == [] and not Keyword.get(opts, :force, false) do
      {:reply, :unchanged, state}
    else
      case compile_css(state, css_input, state.sources, css_base, resolve_dirs) do
        {:ok, css, scanner, scanner_sources} ->
          css = maybe_minify(css, minify)

          {:reply, {:ok, css},
           %{
             state
             | scanner: scanner,
               scanner_sources: scanner_sources,
               css_input: css_input,
               css_base: css_base,
               resolve_dirs: resolve_dirs,
               last_css: css
           }}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def terminate(_reason, %{runtime: nil}), do: :ok

  def terminate(_reason, %{runtime: runtime}) do
    DuskmoonBundler.JS.Runtime.stop(runtime)
    :ok
  end

  defp build_scanner(sources) do
    oxide_sources = Enum.map(sources, &to_oxide_source/1)
    Oxide.new(sources: oxide_sources)
  end

  defp compile_css(state, css_input, sources, css_base, resolve_dirs) do
    with {:ok, css_sources} when is_list(css_sources) <-
           DuskmoonBundler.JS.Runtime.call(state.runtime, "prepareTailwindCss", [
             css_input,
             Path.expand(css_base),
             resolve_dirs
           ]) do
      scanner_sources = Enum.map(sources ++ css_sources, &to_oxide_source/1)

      scanner =
        if scanner_sources == state.scanner_sources,
          do: state.scanner,
          else: build_scanner(scanner_sources)

      case DuskmoonBundler.JS.Runtime.call(state.runtime, "buildTailwindCss", [
             Oxide.scan(scanner)
           ]) do
        {:ok, css} when is_binary(css) -> {:ok, css, scanner, scanner_sources}
        {:ok, _} -> {:error, :unexpected_result}
        {:error, _} = error -> error
      end
    else
      {:ok, _} -> {:error, :unexpected_result}
      {:error, _} = error -> error
    end
  end

  defp maybe_minify(css, false), do: css

  defp maybe_minify(css, true) do
    {:ok, %{code: minified}} = Vize.CSS.compile(css, minify: true)
    minified
  end

  defp normalize_resolve_dirs(resolve_dirs) do
    resolve_dirs
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp to_oxide_source(%{base: base, pattern: pattern} = source) do
    %Oxide.Source{
      base: Path.expand(base),
      pattern: pattern,
      negated: Map.get(source, :negated, false)
    }
  end

  defp to_oxide_source(%{"base" => base, "pattern" => pattern} = source) do
    to_oxide_source(%{base: base, pattern: pattern, negated: Map.get(source, "negated", false)})
  end
end
