defmodule NPM.MixBootstrap do
  @moduledoc false

  @otp_apps [:crypto, :asn1, :public_key, :ssl]

  def ensure_started! do
    # Dependency compilation can prune OTP paths even when SSL is already started.
    # Starting an application again does not restore paths for its lazy modules.
    Enum.each(@otp_apps, &restore_otp_path!/1)
    Enum.each([:ssl, :http_fetch], &start!/1)
    :ok
  end

  defp restore_otp_path!(app) do
    path =
      case :code.lib_dir(app) do
        {:error, :bad_name} ->
          case Path.wildcard(Path.join(to_string(:code.lib_dir()), "#{app}-*/ebin")) do
            [path] ->
              String.to_charlist(path)

            paths ->
              Mix.raise(
                "npm bootstrap failed: cannot locate #{app} OTP code path: #{inspect(paths)}"
              )
          end

        path ->
          :filename.join(path, ~c"ebin")
      end

    case :code.add_patha(path) do
      true ->
        :ok

      {:error, reason} ->
        Mix.raise("npm bootstrap failed: cannot restore #{app} OTP code path: #{inspect(reason)}")
    end
  end

  defp start!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        Mix.raise("npm bootstrap failed: cannot start #{app}: #{inspect(reason)}")
    end
  end
end
