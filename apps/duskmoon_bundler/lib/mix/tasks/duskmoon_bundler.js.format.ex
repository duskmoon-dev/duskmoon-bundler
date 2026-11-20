defmodule Mix.Tasks.DuskmoonBundler.Js.Format do
  use Mix.Task

  alias DuskmoonBundler.Config.Profile
  alias DuskmoonBundler.JS.Format, as: JSFormat
  alias DuskmoonBundler.JS.Helpers

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

    profile = Profile.from_args(args)
    files = Helpers.discover_format_files(profile: profile)

    if files == [] do
      Mix.shell().info("No formattable files found")
    else
      %{changed: changed, total: total} =
        JSFormat.format_files(
          files,
          JSFormat.load_config(profile)
        )

      if changed == 0 do
        Mix.shell().info("All #{total} files already formatted")
      else
        Mix.shell().info("Formatted #{changed}/#{total} files")
      end
    end
  end
end
