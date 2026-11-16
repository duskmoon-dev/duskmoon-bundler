defmodule Mix.Tasks.Npm.Run do
  alias NPM.Package.JSON

  @shortdoc "Run an npm script"

  @moduledoc """
  Run a script defined in `package.json`.

      mix npm.run build
      mix npm.run test
      mix npm.run              # List available scripts

  Scripts are executed with `node_modules/.bin` prepended to `PATH`.
  """

  use Mix.Task

  @impl true
  def run([]) do
    NPM.MixBootstrap.ensure_started!()
    list_scripts()
  end

  def run([script_name | extra_args]) do
    NPM.MixBootstrap.ensure_started!()
    run_script(script_name, extra_args)
  end

  defp list_scripts do
    case JSON.read_scripts() do
      {:ok, scripts} when scripts == %{} ->
        Mix.shell().info("No scripts found in package.json.")

      {:ok, scripts} ->
        Mix.shell().info("Available scripts:")

        Enum.each(Enum.sort(scripts), fn {name, command} ->
          Mix.shell().info("  #{name}: #{command}")
        end)

      {:error, reason} ->
        Mix.shell().error("Failed to read package.json: #{inspect(reason)}")
    end
  end

  defp run_script(name, extra_args) do
    case JSON.read_scripts() do
      {:ok, scripts} ->
        case Map.fetch(scripts, name) do
          {:ok, command} ->
            execute(command, extra_args)

          :error ->
            Mix.shell().error("Script \"#{name}\" not found in package.json.")
            Mix.shell().info("Available: #{scripts |> Map.keys() |> Enum.join(", ")}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to read package.json: #{inspect(reason)}")
    end
  end

  defp execute(command, extra_args) do
    bin_path = Path.join(File.cwd!(), "node_modules/.bin")
    current_path = System.get_env("PATH", "")
    env = [{"PATH", "#{bin_path}:#{current_path}"}]

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      env: Enum.map(env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
    ]

    command |> open_port(extra_args, port_opts) |> stream_port()
  end

  # `{:spawn, command}` runs `sh -c "exec <command>"` on Unix, which replaces
  # the shell with the first command of `a && b` and cannot handle `VAR=x cmd`.
  # Scripts are shell command lines, so run them through an explicit shell.
  defp open_port(command, extra_args, port_opts) do
    case {:os.type(), System.find_executable("sh")} do
      {{:unix, _}, sh} when is_binary(sh) ->
        full_command = Enum.join([command | Enum.map(extra_args, &shell_quote/1)], " ")
        Port.open({:spawn_executable, sh}, [{:args, ["-c", full_command]} | port_opts])

      _ ->
        Port.open({:spawn, Enum.join([command | extra_args], " ")}, port_opts)
    end
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp stream_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_port(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        Mix.shell().error("Script exited with code #{code}")
        exit({:shutdown, code})
    end
  end
end
