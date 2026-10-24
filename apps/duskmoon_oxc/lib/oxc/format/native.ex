defmodule OXC.Format.Native do
  @moduledoc false

  native_version = Mix.Project.config()[:version]

  build_from_source =
    OXC.NativePolicy.force_build!(
      :duskmoon_oxc,
      "OXC_EX_BUILD",
      native_version,
      :rustler_precompiled
    )

  use RustlerPrecompiled,
    otp_app: :duskmoon_oxc,
    crate: "oxc_fmt_nif",
    base_url: {OXC.NativeURL, :url},
    force_build: build_from_source,
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-apple-darwin
      x86_64-pc-windows-gnu
      x86_64-unknown-freebsd
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    ),
    version: native_version

  @spec format(iodata(), String.t(), map()) :: {:ok, String.t()} | {:error, [String.t()]}
  def format(_source, _filename, _opts), do: :erlang.nif_error(:nif_not_loaded)
end
