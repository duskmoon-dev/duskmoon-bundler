{opts, _, _} = OptionParser.parse(System.argv(), strict: [source: :string])
root = Path.expand("..", __DIR__)

inventory =
  root |> Path.join("docs/archive/migration-inventory.json") |> File.read!() |> JSON.decode!()

source = opts[:source]

for row <- inventory["files"], row["action"] in ["move", "duplicate", "split"] do
  destination =
    case row["destination_path"] do
      "biome.json" ->
        "docs/archive/biome.json"

      # Zigler rebuilds this historical generated wrapper from the retained source.
      "apps/duskmoon_quickbeam/lib/quickbeam/.Elixir.QuickBEAM.Native.zig" ->
        "apps/duskmoon_quickbeam/lib/quickbeam/quickbeam.zig"

      path ->
        path
    end

  path = Path.join(root, destination)
  unless File.exists?(path), do: raise("Missing imported path #{row["destination_path"]}")

  if source do
    {bytes, 0} =
      System.cmd("git", ["show", "#{row["source_sha"]}:#{row["source_path"]}"], cd: source)

    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if hash != row["sha256"], do: raise("Snapshot hash mismatch #{row["source_path"]}")
  end
end

IO.puts("Inventory paths verified; #{length(inventory["files"])} source files accounted for")
