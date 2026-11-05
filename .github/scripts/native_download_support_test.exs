Code.require_file("native_download_support.exs", __DIR__)
ExUnit.start()

defmodule NativeDownloadSupportTest do
  use ExUnit.Case, async: true

  for backend <- [RustlerPrecompiled, ZiglerPrecompiled] do
    @backend backend

    test "#{inspect(backend)} probe retains the published native ABI and build configuration" do
      published = """
      defmodule Example.Native do
        @version "10.0.3"
        use #{inspect(@backend)},
          otp_app: :example,
          base_url: "https://example.test/releases",
          version: @version,
          targets: ["aarch64-linux-gnu"],
          nif_versions: ["2.15"],
          nifs: [load_addon: 3]
      end
      """

      candidate = """
      defmodule Example.Native do
        @platform Example.Native.Platform.current()
        use #{inspect(@backend)},
          otp_app: :example,
          base_url: {Example.NativeURL, :url},
          version: "10.0.10",
          targets: ["x86_64-linux-gnu"],
          nifs: [load_addon: 4]
      end
      """

      expected =
        String.replace(
          published,
          ~s("https://example.test/releases"),
          "{Example.NativeURL, :url}"
        )

      result = NativeDownloadSupport.overlay_url!(published, candidate)
      assert ast(result) == ast(expected)
    end
  end

  defp ast(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      node -> node
    end)
  end
end
