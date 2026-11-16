defmodule Mix.Tasks.Npm.Pack do
  @shortdoc "Create a tarball"

  @moduledoc """
  Create an npm tarball using the same file selection as `mix npm.publish`.

      mix npm.pack

  Honors `files`, `.npmignore` and `.gitignore`; omits symlinks and registry
  credentials. Lifecycle scripts and bundled dependencies are not supported.
  """

  use Mix.Task

  @impl true
  def run([]) do
    NPM.MixBootstrap.ensure_started!()

    with {:ok, %{filename: filename, tarball: tarball}} <- NPM.Pack.tarball("."),
         :ok <- File.write(filename, tarball) do
      Mix.shell().info("Created #{filename} (#{byte_size(tarball)} B)")
    else
      {:error, reason} -> Mix.raise("Failed to create tarball: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix npm.pack")
end
