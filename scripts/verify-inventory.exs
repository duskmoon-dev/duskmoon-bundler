{opts, _, _} = OptionParser.parse(System.argv(), strict: [source: :string])
root = Path.expand("..", __DIR__)
inventory = root |> Path.join("docs/migration-inventory.json") |> File.read!() |> JSON.decode!()
source = opts[:source]

for row <- inventory["files"], row["action"] in ["move", "duplicate", "split"] do
  path = Path.join(root, row["destination_path"])
  unless File.exists?(path), do: raise("Missing imported path #{row["destination_path"]}")

  if source do
    {bytes, 0} =
      System.cmd("git", ["show", "#{row["source_sha"]}:#{row["source_path"]}"], cd: source)

    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if hash != row["sha256"], do: raise("Snapshot hash mismatch #{row["source_path"]}")
  end
end

IO.puts("Inventory paths verified; #{length(inventory["files"])} source files accounted for")
