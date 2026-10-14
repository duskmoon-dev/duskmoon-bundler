Code.require_file("lib/package_stage.exs", __DIR__)

{opts, rest, invalid} =
  OptionParser.parse(System.argv(), strict: [output: :string, version: :string])

if rest != [] or invalid != [],
  do: raise("Usage: elixir scripts/stage-packages.exs --output ABSOLUTE_PATH [--version B]")

root = Path.expand("..", __DIR__)
version = opts[:version] || "10.0.0"
output = Keyword.fetch!(opts, :output)
manifest = DuskmoonToolchain.PackageStage.stage!(root, output, version)
IO.puts("Staged #{length(manifest.packages)} packages at #{Path.expand(output)} for B=#{version}")
