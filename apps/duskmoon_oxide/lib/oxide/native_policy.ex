defmodule Oxide.NativePolicy do
  @moduledoc false

  # Duplicated in native packages so each published package remains self-contained.
  def force_build!(app, legacy_flag, version, backend) do
    env_flags = [
      "DUSKMOON_BUILD_NATIVE_FROM_SOURCE",
      legacy_flag,
      "RUSTLER_PRECOMPILED_FORCE_BUILD_ALL",
      "ZIGLER_PRECOMPILED_FORCE_BUILD_ALL"
    ]

    forced = Enum.filter(env_flags, &(System.get_env(&1) in ["1", "true"]))

    configured =
      Application.get_env(backend, :force_build_all, false) or
        Keyword.get(Application.get_env(backend, :force_build, []), app, false)

    mode = System.get_env("DUSKMOON_NATIVE_MODE")

    case mode do
      "source" ->
        true

      nil ->
        forced != [] or configured

      "precompiled" ->
        if forced != [] or configured do
          raise "DUSKMOON_NATIVE_MODE=precompiled conflicts with native source flags: #{inspect(forced)} / #{backend} force_build configuration for #{app}"
        end

        if "dev" in Version.parse!(version).pre do
          raise "DUSKMOON_NATIVE_MODE=precompiled rejects -dev artifact versions that force source compilation"
        end

        false

      other ->
        raise "Invalid DUSKMOON_NATIVE_MODE=#{inspect(other)}; expected source or precompiled"
    end
  end
end
