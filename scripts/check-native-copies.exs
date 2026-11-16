root = Path.expand("..", __DIR__)

for file <- ~w(native_policy.ex native_url.ex) do
  copies =
    for app <- ~w(oxc oxide vize quickbeam) do
      path = Path.join([root, "apps", "duskmoon_#{app}", "lib", app, file])

      source =
        File.read!(path) |> String.replace(~r/\Adefmodule [\w.]+ do/, "defmodule NativeCopy do")

      # ZiglerPrecompiled requires {url, headers}; RustlerPrecompiled requires
      # the URL string. Keep this intentional adapter difference explicit.
      source =
        if app == "quickbeam" and file == "native_url.ex" do
          String.replace(
            source,
            "  # ZiglerPrecompiled callbacks return the URL and request headers as a pair.\n" <>
              "  def url(filename), do: {resolve(@base_url <> \"/\" <> filename), []}",
            "  def url(filename), do: resolve(@base_url <> \"/\" <> filename)"
          )
        else
          source
        end

      {path, source}
    end

  [{_path, expected} | rest] = copies

  for {path, actual} <- rest do
    unless actual == expected, do: raise("Native support copies differ: #{path}")
  end
end

IO.puts("All four native policy and URL helper copies match")
