defmodule Mix.Tasks.DuskmoonBundler.Js.Format do
  use Mix.Task

  @shortdoc "Format DuskmoonBundler TypeScript assets"

  @moduledoc """
  Format DuskmoonBundler's JavaScript and TypeScript assets with oxfmt via NIF.

      mix duskmoon_bundler.js.format
      mix duskmoon_bundler.js.format my_app_web

  Reads options from `config :duskmoon_bundler, :format`. Falls back to `.oxfmtrc.json`.
  File discovery uses `config :duskmoon_bundler, sources:` and `ignore:`.
  No Node.js required.
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    profile = DuskmoonBundler.Config.Profile.from_args(args)
    files = DuskmoonBundler.JS.Helpers.discover_format_files(profile: profile)

    if files == [] do
      Mix.shell().info("No formattable files found")
    else
      %{changed: changed, total: total} =
        DuskmoonBundler.JS.Format.format_files(
          files,
          DuskmoonBundler.JS.Format.load_config(profile)
        )

      if changed == 0 do
        Mix.shell().info("All #{total} files already formatted")
      else
        Mix.shell().info("Formatted #{changed}/#{total} files")
      end
    end
  end
end
