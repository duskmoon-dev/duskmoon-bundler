# credo:disable-for-this-file Credo.Check.Readability.Specs
defmodule DuskmoonHologram.MixProject do
  use Mix.Project

  @version "10.0.5"

  def aliases do
    [
      "lint.js": "duskmoon_bundler.js.check duskmoon_hologram",
      f: [
        "format",
        "format.js",
        "cmd cd test/ecosystem && mix format",
        "cmd cd test/features && mix format && mix format.js",
        "cmd cd test/umbrella && mix format"
      ],
      "format.js": "duskmoon_bundler.js.format duskmoon_hologram",
      "format.js.check": "duskmoon_bundler.js.check duskmoon_hologram",
      setup: [
        "deps.get",
        &install_js_deps/1,
        "cmd --cd test/ecosystem mix deps.get",
        "cmd --cd test/features mix deps.get",
        "cmd --cd test/features/assets mix npm.install",
        "cmd --cd test/umbrella mix deps.get",
        "cmd --cd test/umbrella/assets mix npm.install"
      ],
      t: ["test", "test.js"],
      "test.js": [&test_js/1]
    ]
  end

  def application do
    [
      mod: {Hologram.Application, []},
      extra_applications: [:crypto, :logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        t: :test,
        "test.js": :test
      ]
    ]
  end

  def deps do
    [
      {:duskmoon_npm, in_umbrella: true},
      {:duskmoon_bundler, in_umbrella: true, runtime: false},
      {:beam_file, "0.6.4"},
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:benchee_markdown, "~> 0.3", only: :dev, runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:decimal, "~> 3.0", only: [:dev, :test], runtime: false, override: true},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ecto, "~> 3.0", only: :test, runtime: false},
      {:ex_check, "~> 0.15", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", runtime: false, override: true},
      {:file_system, "~> 1.0"},
      {:gaoxy_http, "~> 0.12.2", only: :test},
      {:gproc, "~> 1.0"},
      {:html_entities, "~> 0.5"},
      {:interceptor, "~> 0.5"},
      {:jason, "~> 1.0"},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.0"},
      {:plug_crypto, "~> 2.0"},
      {:recode, "~> 0.7", only: :dev, runtime: false},
      {:sobelow, "~> 0.12", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 1.0"},
      {:wallaby, "~> 0.30", only: [:dev, :test], runtime: false},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  def elixirc_paths(:dev), do: ["benchmarks/elixir/support", "lib"]
  def elixirc_paths(:test), do: ["lib", "test/elixir/fixtures", "test/elixir/support"]
  def elixirc_paths(_env), do: ["lib"]

  def package do
    [
      files: [
        "assets/js",
        "assets/package.json",
        "config",
        "docs",
        "lib",
        ".formatter.exs",
        "LICENSE",
        "llms.txt",
        "llms-full.txt",
        "mix.exs",
        "README.md",
        "usage-rules.md",
        "UPSTREAM.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => "https://hologram.page",
        "Forum" => "https://elixirforum.com/hologram",
        "Discord" => "https://discord.gg/huJWNuqt8J",
        "Slack" => "https://elixir-lang.slack.com/channels/hologram",
        "Newsletter" => "https://hologram.page/newsletter",
        "Courses" => "https://hologram.page/courses",
        "UI" => "https://hologram.page/ui",
        "GitHub" => "https://github.com/duskmoon-dev/duskmoon-bundler"
      },
      maintainers: ["Bart Blast"]
    ]
  end

  def project do
    if String.to_integer(System.otp_release()) < 28 do
      Mix.raise("duskmoon_hologram requires Erlang/OTP >= 28")
    end

    [
      aliases: aliases(),
      app: :duskmoon_hologram,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps(),
      description:
        "Full stack isomorphic Elixir web framework that can be used on top of Phoenix.",
      dialyzer: [
        plt_add_apps: [:ex_unit, :iex, :mix, :wallaby],
        plt_core_path: Path.join(["priv", "plts", "core.plt"]),
        plt_local_path: Path.join(["priv", "plts", "project.plt"])
      ],
      docs: [
        authors: ["Bart Blast"],
        groups_for_modules: [
          Main: [
            Hologram,
            Hologram.Component,
            Hologram.Component.Action,
            Hologram.Component.Command,
            Hologram.Page,
            Hologram.Server
          ],
          Plug: [Hologram.Router, Hologram.Router.Helpers],
          UI: [Hologram.UI.Link, Hologram.UI.Runtime],
          Errors: [
            Hologram.AssetNotFoundError,
            Hologram.CompileError,
            Hologram.ParamError,
            Hologram.TemplateSyntaxError
          ]
        ],
        source_ref: "v#{@version}",
        source_url_pattern:
          "https://github.com/duskmoon-dev/duskmoon-bundler/blob/%{ref}/apps/duskmoon_hologram/%{path}#L%{line}"
      ],
      elixir: ">= 1.18.0",
      elixirc_options: [
        # These modules are used only in tests to test whether Hex.Solver's implementations
        # for Inspect and String.Chars protocols are excluded when building runtime and pages JavaScript files.
        no_warn_undefined: [
          Inspect.Hex.Solver.PackageRange,
          String.Chars.Hex.Solver.PackageRange
        ],
        warnings_as_errors: true
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      homepage_url: "https://hologram.page/",
      package: package(),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/duskmoon-dev/duskmoon-bundler",
      test_paths: ["test/elixir"],
      version: @version
    ]
  end

  defp install_js_deps(_args) do
    Mix.Task.run("compile")
    Hologram.Compiler.install_js_deps(Path.expand("assets", __DIR__), Mix.Project.app_path())
  end

  defp test_js(args) do
    install_js_deps([])

    File.cd!(Path.expand("assets", __DIR__), fn ->
      case args do
        [] -> Mix.Tasks.Npm.Run.run(["test"])
        [path | rest] -> Mix.Tasks.Npm.Run.run(["test-file", "../#{path}" | rest])
      end
    end)
  end
end
